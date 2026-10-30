import AppKit
import LarynxCore
import LarynxSpeech

/// Larynx live: hold fn, talk, and the raw text lands at the cursor, or on the clipboard.
/// Save first, paste second. No network code here, no settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let todayItem = NSMenuItem(title: "Today: 0 dictations", action: nil, keyEquivalent: "")
    private let needsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")

    private var history: History!
    /// words.toml and styles.toml; re-read only when a file's mtime changes.
    private let rules = RulesStore()
    private var model: SpeechModel!
    private var transcriber: Transcriber!
    private var keys = KeyMachine()
    private var limits = (hold: 120.0, handsFree: 600.0)
    private var keyWatch: Timer?
    private var tap: KeyTap!
    private let recorder = Recorder()
    private let pill = Pill()
    private var current: (id: String, file: URL)?
    private var liveTimer: Timer?
    private var tapRetry: Timer?
    private var startupError: String?

    func applicationDidFinishLaunching(_ note: Notification) {
        if LogFile.rotate() { NSLog("larynx: larynx.log passed 5 MB; the old log is larynx.log.1") }
        Silent.prune()
        setUpMenu()
        let config = Config.load()
        limits = (config.maxHold, config.maxHandsFree)
        keys = freshKeys()
        if config.values["key"] != "fn" { NSLog("larynx: only key = \"fn\" is supported in this version") }
        do {
            history = try History()
            model = try SpeechModel.named(config.model)
            transcriber = Transcriber(model: model)
        } catch {
            startupError = "\(error)"
            NSLog("larynx: \(error)")
            return
        }
        pill.levelSource = { [recorder] in recorder.level }
        // A warm mic closes when the Mac sleeps or the screen locks; the next press starts cold.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [recorder] _ in recorder.coolNow("sleep") }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [recorder] _ in recorder.coolNow("screen locked")
        }

        // Leftovers from a run that died. Taken now, before any new recording can start.
        let leftovers = Inflight.leftovers()

        if !DebugChannel.enabled { Permissions.ask() }
        tap = KeyTap { [weak self] e in self?.onKey(e) }
        if !tap.start() {
            // Input Monitoring is off. Try again every few seconds so allowing it takes effect.
            tapRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
                MainActor.assumeIsolated { if self?.tap.start() == true { t.invalidate() } }
            }
        }

        Task {
            do { try await transcriber.load() } catch { startupError = "\(error)"; NSLog("larynx: \(error)") }
            StallGuard.start() // after the model load, so a slow first load is never taken for a freeze
            let model = self.model.name
            let found = await Inflight.recover(leftovers, model: model, history: history, clipboard: SystemClipboard()) {
                [transcriber] samples in try await transcriber!.transcribe(samples)
            }
            for r in found { NSLog("larynx: recovered \(r.file.lastPathComponent): \(r.dictation != nil ? "saved to history" : (r.error ?? "empty, deleted"))") }
            if found.contains(where: { $0.dictation != nil }) {
                pill.show("Recovered \(found.filter { $0.dictation != nil }.count) dictation(s). On your clipboard.", for: 4)
            }
        }

        if DebugChannel.enabled {
            do {
                try DebugChannel.serve { req, reply in
                    Task { @MainActor in reply(await self.debug(req)) }
                }
            } catch { NSLog("larynx: debug socket: \(error)") }
        }
    }

    /// Opening Larynx again (Spotlight, Finder, `open`) shows its menu at the pointer,
    /// so it opens even when the menu bar item is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func applicationWillTerminate(_ note: Notification) {
        if DebugChannel.enabled { unlink(DebugChannel.path.path) }
    }

    // MARK: menu

    private func setUpMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◉ larynx"
        let menu = NSMenu()
        menu.delegate = self
        todayItem.isEnabled = false
        needsItem.isEnabled = false
        menu.addItem(todayItem)
        menu.addItem(needsItem)
        menu.addItem(.separator())
        recentItem.submenu = NSMenu()
        menu.addItem(recentItem)
        menu.addItem(withTitle: "Paste last again", action: #selector(pasteLastAgain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy last raw", action: #selector(copyLastRaw), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Larynx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private var todayCount: Int {
        ((try? history?.all()) ?? []).filter { Calendar.current.isDateInToday($0.createdAt) }.count
    }

    private var missing: [String] {
        var m: [String] = []
        if !KeyTap.hasAccess { m.append("Input Monitoring") }
        if !Permissions.accessibility { m.append("Accessibility") }
        if AVCaptureDeviceStatus.microphone != "authorized" { m.append("Microphone") }
        return m
    }

    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            let n = todayCount
            todayItem.title = "Today: \(n) dictation\(n == 1 ? "" : "s")"
            let m = missing
            needsItem.title = startupError.map { "Problem: \($0)" } ?? "Needs: \(m.joined(separator: ", "))"
            needsItem.isHidden = startupError == nil && m.isEmpty
            fillRecent()
        }
    }

    /// The last 10 dictations. Click one to copy it (nothing is ever lost).
    private func fillRecent() {
        let sub = recentItem.submenu ?? NSMenu()
        sub.removeAllItems()
        let rows = (try? history.recent(10)) ?? []
        if rows.isEmpty { sub.addItem(withTitle: "No dictations yet", action: nil, keyEquivalent: "").isEnabled = false }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        for d in rows {
            var t = d.textFinal.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > 60 { t = String(t.prefix(57)) + "…" }
            let item = NSMenuItem(title: "\(t)   \(fmt.localizedString(for: d.createdAt, relativeTo: Date()))",
                                  action: #selector(copyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.textFinal
            item.toolTip = d.textFinal
            sub.addItem(item)
        }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        try? SystemClipboard().write(text)
        pill.show("Copied. ⌘V to paste.", for: 1.2)
    }

    @objc private func pasteLastAgain() {
        // Let the menu close and focus return to the user's app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            guard let d = try? history.last() else { pill.show("No dictations yet", for: 1.5); return }
            do {
                try SystemClipboard().write(d.textFinal)
                if FocusInfo.shouldPaste(AXFocusProbe().focused()) { try CGPaster().pasteOnce() }
                else { pill.show(PillText.clipboard, for: PillText.clipboardSeconds) }
            } catch { pill.show("\(error)", for: 3) }
        }
    }

    @objc private func copyLastRaw() {
        guard let d = try? history.last() else { return }
        try? SystemClipboard().write(d.textRaw)
    }

    // MARK: keys

    private func onKey(_ e: KeyTap.Event) {
        let t = ProcessInfo.processInfo.systemUptime
        let action: KeyMachine.Action
        switch e {
        case let .flags(fn, shift, control, other, wasFn):
            action = keys.flags(fn: fn, shift: shift, control: control, other: other, at: t, wasFn: wasFn)
        case .otherKey: action = keys.otherKey(at: t)
        case .escape: action = keys.escape()
        case .click: keys.click(); action = .none
        }
        perform(action)
        if case let .tapPending(deadline) = keys.state {
            DispatchQueue.main.asyncAfter(deadline: .now() + (deadline - t) + 0.02) { [self] in
                perform(keys.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func freshKeys() -> KeyMachine { KeyMachine(maxHold: limits.hold, maxHandsFree: limits.handsFree) }

    /// While a dictation runs, read the real fn key every 0.1 s, so a release the tap missed
    /// still ends it, and apply the time limits. Stops itself once the keys are idle.
    private func watchKeys() {
        guard keyWatch == nil else { return }
        keyWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                let fn = CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn)
                let action = self.keys.watch(fnDown: fn, at: ProcessInfo.processInfo.systemUptime)
                if action != .none { NSLog("larynx: key watch ended a recording (\(action)); fn down: \(fn)") }
                self.perform(action)
                if self.keys.state == .idle {
                    t.invalidate(); self.keyWatch = nil
                    NSLog("larynx: key watch done; saw fn down: \(self.keys.watchSawFn)")
                }
            }
        }
    }

    private func perform(_ action: KeyMachine.Action) {
        switch action {
        case .none: break
        case .start: startRecording(); watchKeys()
        case let .stop(raw): stopRecording(raw: raw)
        case .cancel:
            liveTimer?.invalidate()
            let s = recorder.stop()
            if let c = current {
                NSLog("larynx: outcome %@ mic=%@ audio=%.1fs result=cancelled", String(c.id.prefix(8)), recorder.micName, Double(s.count) / 16_000)
            }
            if let c = current { try? FileManager.default.removeItem(at: c.file) }
            current = nil
            pill.hide()
        }
    }

    private func startRecording() {
        guard transcriber != nil else { pill.show(startupError ?? "Larynx did not start", for: 3); keys = freshKeys(); return }
        pill.listening(PillText.listening) // first, so the pill is up within 100 ms of key down
        guard AVCaptureDeviceStatus.microphone == "authorized" else {
            keys = freshKeys()
            Recorder.requestAccess { [weak self] ok in
                self?.pill.show(ok ? "Microphone allowed. Hold fn again." : "Allow the microphone for Larynx in System Settings.", for: 3)
            }
            return
        }
        let id = UUID().uuidString
        let file = Inflight.url(for: id)
        do {
            try recorder.start(writingTo: file)
            current = (id, file)
        } catch {
            keys = freshKeys()
            NSLog("larynx: outcome %@ mic=%@ result=mic-error(%@)", String(id.prefix(8)), recorder.micName, "\(error)")
            try? FileManager.default.removeItem(at: file)
            // A CoreAudio error here repeats on every press: this process's view of the audio devices
            // is stale. Exit with a failure so launchd starts a fresh Larynx (KeepAlive), as StallGuard does.
            if (error as NSError).domain.hasPrefix("com.apple.coreaudio") {
                pill.show("Mic did not start. Larynx restarts; hold fn again in 3 s.", for: 2)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSLog("larynx: exiting so launchd restarts Larynx"); _exit(1) }
            } else {
                pill.show("Mic did not start: \(error)", for: 3)
            }
            return
        }
        // No live words: the pill shows only the meter, so nothing runs while you talk.
    }

    private func stopRecording(raw: Bool) {
        liveTimer?.invalidate()
        let samples = recorder.stop()
        guard let c = current else { return }
        current = nil
        let mic = recorder.micName
        Task { _ = await finish(samples: samples, id: c.id, file: c.file, raw: raw, mic: mic) }
    }

    // MARK: the pipeline after recording (shared with the debug feed)

    struct Outcome: Encodable {
        var dictation: Dictation?
        var landed: String
        var pill: String
        var raw: Bool
        var focus_role: String?
        var text_input: Bool
        var accessibility: Bool
        var inflight_left: Bool
        var transcribe_ms: Double
        var clean_ms: Double?
        var style: String?
        var app: String?
        var total_ms: Double
        var error: String?
        var mic: String
        var loud_db: Double
        var peak_db: Double
        var silent: Bool
    }

    /// transcribe -> clean (rules, timed) -> save -> clipboard -> paste. fn+shift skips the cleanup.
    /// `app` overrides the front app (debug feed only); otherwise it is the front app's bundle id.
    func finish(samples: [Float], id: String, file: URL, raw: Bool, paste: Bool = true, app: String? = nil,
                mic: String = "feed") async -> Outcome {
        let t0 = DispatchTime.now()
        func ms(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6 }
        let frontApp = app ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var out = Outcome(landed: "none", pill: "", raw: raw, text_input: false, accessibility: Permissions.accessibility,
                          inflight_left: false, transcribe_ms: 0, total_ms: 0, mic: mic, loud_db: 0, peak_db: 0, silent: false)
        let seconds = Double(samples.count) / 16_000
        var loud = Loudness()
        loud.add(samples)
        out.loud_db = loud.loudDB
        out.peak_db = loud.peakDB
        // One line per recording, so a failure shows its cause in ~/.larynx/larynx.log.
        defer {
            let result = out.silent ? "silent" : out.error.map { "error(\($0))" } ?? (out.dictation == nil ? "empty" : out.landed)
            NSLog("larynx: outcome %@ mic=%@ audio=%.1fs loud=%.0fdB peak=%.0fdB result=%@ words=%d transcribe=%.0fms",
                  String(id.prefix(8)), mic, seconds, out.loud_db, out.peak_db, result,
                  out.dictation?.textFinal.split(separator: " ").count ?? 0, out.transcribe_ms)
        }
        // A dead mic gives near silence, and the model turns silence into "Yeah." Say so instead
        // of pasting. The audio is kept in ~/.larynx/silent/ in case the threshold was wrong.
        if loud.isSilent(below: Config.load().silentBelowDB) {
            out.silent = true
            Silent.keep(file)
            out.pill = PillText.silent(mic)
            pill.show(out.pill, for: 4)
            out.inflight_left = FileManager.default.fileExists(atPath: file.path)
            out.total_ms = ms(t0)
            return out
        }
        do {
            let text = try await transcriber.transcribe(samples)
            out.transcribe_ms = ms(t0)
            if text.isEmpty {
                try? FileManager.default.removeItem(at: file)
                out.pill = seconds < 1 ? "" : PillText.nothing
                if out.pill.isEmpty { pill.hide() } else { pill.show(out.pill, for: 1.2) }
            } else {
                var d = Dictation(id: id, textRaw: text, style: "none", model: model.name, cleanup: "none", durationS: seconds,
                                  transcribeMs: out.transcribe_ms)
                if !raw {
                    // Rules only, no model. Measured with the monotonic clock.
                    let t1 = DispatchTime.now()
                    let cleaned = rules.cleaner().clean(text, app: frontApp)
                    d.cleanMs = ms(t1)
                    d.cleanup = "rules"
                    d.style = cleaned.style
                    // Only fillers ("um")? Keep the raw words: nothing is ever lost.
                    d.textFinal = cleaned.text.isEmpty ? text : cleaned.text
                }
                // One trailing space, so back-to-back dictations don't glue ("threehello").
                // Not in plain style (Terminal, editors), where a stray space can matter.
                if d.style != "plain", !d.textFinal.hasSuffix(" ") { d.textFinal += " " }
                out.clean_ms = d.cleanMs
                out.style = d.style
                out.app = frontApp
                d.app = frontApp
                let probe = RecordingProbe()
                let saved = try deliver(d, history: history, clipboard: SystemClipboard(), focus: probe,
                                        paster: paste ? CGPaster() : nil) {
                    try? FileManager.default.removeItem(at: file) // the text is safe: drop the audio
                }
                out.dictation = saved
                out.landed = saved.landed.rawValue
                out.focus_role = probe.seen?.role
                out.text_input = probe.seen?.isTextInput ?? false
                out.pill = PillText.result(saved.landed)
                if saved.landed == .pasted { pill.done() } else { pill.show(out.pill, for: PillText.clipboardSeconds) }
            }
        } catch {
            out.error = "\(error)"
            out.pill = PillText.failed("\(error)")
            pill.show(out.pill, for: 4)
        }
        out.inflight_left = FileManager.default.fileExists(atPath: file.path)
        out.total_ms = ms(t0)
        return out
    }

    // MARK: debug feed (debug build with LARYNX_DEBUG=1 only)

    private func debug(_ req: Data) async -> Data {
        func json<T: Encodable>(_ v: T) -> Data { Data(((try? JSON.render(v)) ?? JSON.error("encode")).utf8).compactJSON }
        guard let obj = try? JSONSerialization.jsonObject(with: req) as? [String: String] else { return json(["error": "bad request"]) }
        switch obj["cmd"] {
        case "state":
            struct State: Encodable {
                let model: String; let model_loaded: Bool; let input_monitoring: Bool; let tap_running: Bool
                let accessibility: Bool; let microphone: String; let recording: Bool; let today: Int; let pill_visible: Bool
                let pill_text: String
            }
            return json(State(model: model?.name ?? "", model_loaded: await transcriber?.isLoaded ?? false,
                              input_monitoring: KeyTap.hasAccess, tap_running: tapRetry?.isValid != true,
                              accessibility: Permissions.accessibility, microphone: AVCaptureDeviceStatus.microphone,
                              recording: current != nil, today: todayCount, pill_visible: pill.isVisible, pill_text: pill.text))
        case "feed":
            guard current == nil else { return json(["error": "busy: recording"]) }
            guard let path = obj["wav"] else { return json(["error": "missing wav"]) }
            do {
                let samples = try Transcriber.samples(of: URL(fileURLWithPath: path))
                let id = UUID().uuidString
                let file = Inflight.url(for: id)
                let writer = try CafWriter(url: file)
                if obj["stream"] == "true" {
                    // Real-time pace, like the mic: 100 ms chunks. Kill the app mid-way to test crash recovery.
                    pill.listening(PillText.listening)
                    for start in stride(from: 0, to: samples.count, by: 1_600) {
                        writer.append(Array(samples[start..<min(start + 1_600, samples.count)]))
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } else {
                    writer.append(samples)
                }
                writer.close()
                return json(await finish(samples: samples, id: id, file: file, raw: obj["raw"] == "true",
                                         paste: obj["paste"] == "true", app: obj["app"]))
            } catch { return json(["error": "\(error)"]) }
        default:
            return json(["error": "unknown cmd"])
        }
    }
}

/// Wraps the real Accessibility probe and remembers what it saw, for the debug reply.
final class RecordingProbe: FocusProbe {
    var seen: FocusInfo?
    func focused() -> FocusInfo? { seen = AXFocusProbe().focused(); return seen }
}

import AVFoundation
enum AVCaptureDeviceStatus {
    static var microphone: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }
}

extension Data {
    /// One line, for the socket protocol.
    var compactJSON: Data {
        guard let o = try? JSONSerialization.jsonObject(with: self, options: [.fragmentsAllowed]),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return self }
        return d
    }
}
