import AppKit
import AVFoundation
import Foundation
import LarynxCore
import SQLite3

// Tests without XCTest (CLT-only machine): `swift run LarynxSelfTest`.

var failures = 0
Paths.trustsEnvironment = true
func check(_ ok: Bool, _ name: String) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("larynx-selftest-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: tmp) }
func freshDB(_ name: String) -> URL { tmp.appendingPathComponent(name).appendingPathComponent("history.db") }

let now = Date()
func dictation(_ text: String, daysAgo: Double = 0) -> Dictation {
    Dictation(createdAt: now.addingTimeInterval(-daysAgo * 86_400), textRaw: text, model: "parakeet-v3", durationS: 1.5)
}

/// Records every step so the test can see the order.
final class FakeClipboard: Clipboard {
    var events: [String] = []
    var seenInHistory = false
    let history: History
    let fails: Bool
    init(history: History, fails: Bool = false) { self.history = history; self.fails = fails }
    func write(_ text: String) throws {
        // At the moment of the clipboard write, the row must already be in history.
        seenInHistory = (try? history.last()?.textFinal) == text
        events.append("clipboard")
        if fails { throw HandOverError.clipboard }
    }
}

// History: save and read back
do {
    let h = try History(path: freshDB("save"))
    try h.save(dictation("first", daysAgo: 0.01))
    try h.save(dictation("second"))
    check(try h.count() == 2, "history: two saves, two rows")
    check(try h.last()?.textRaw == "second", "history: last() is the newest")
    check(try h.all().map(\.textRaw) == ["second", "first"], "history: all() is newest first")
    let back = try h.last()!
    check(back.cleanup == "none" && back.landed == .clipboard && back.model == "parakeet-v3" && back.durationS == 1.5,
          "history: every field round-trips")
    let reopened = try History(path: freshDB("save"))
    check(try reopened.count() == 2, "history: rows survive closing and reopening the file")
} catch { check(false, "history save/read threw \(error)") }

// nothing older than 30 days
do {
    let path = freshDB("prune")
    let h = try History(path: path)
    try h.save(dictation("ancient", daysAgo: 90))
    try h.save(dictation("old", daysAgo: 30.5))
    try h.save(dictation("recent", daysAgo: 29.5))
    try h.save(dictation("today"))
    let dropped = try h.prune(now: now)
    check(dropped == 2, "prune drops the 2 rows older than 30 days")
    check(try h.all().map(\.textRaw) == ["today", "recent"], "rows inside 30 days stay")
    try h.save(dictation("stale", daysAgo: 45))
    let opened = try History(path: path, now: now)
    check(try opened.all().allSatisfy { now.timeIntervalSince($0.createdAt) <= 30 * 86_400 },
          "opening the store prunes too, so no reader sees a row older than 30 days")
} catch { check(false, "prune threw \(error)") }

// save first, then clipboard
do {
    let h = try History(path: freshDB("handover"))
    let clip = FakeClipboard(history: h)
    let d = try handOver(dictation("ask Claude to fix the demo"), history: h, clipboard: clip)
    check(clip.seenInHistory, "the dictation is in history before the clipboard is touched")
    check(clip.events == ["clipboard"], "the clipboard gets the text exactly once")
    check(d.landed == .clipboard, "hand over reports clipboard (no paste yet)")
    check(try h.last()?.landed == .clipboard, "history records landed = clipboard")

    // If the clipboard fails, the words are still saved: nothing is lost.
    let h2 = try History(path: freshDB("clipfail"))
    let bad = FakeClipboard(history: h2, fails: true)
    var threw = false
    do { try handOver(dictation("keep me"), history: h2, clipboard: bad) } catch { threw = true }
    let kept = try h2.last()?.textRaw
    check(threw && kept == "keep me", "a clipboard failure still leaves the dictation in history")
} catch { check(false, "hand over threw \(error)") }

// JSON (library side): every output shape is valid JSON with the agreed keys
do {
    func parses(_ s: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed]) }
    let one = try JSON.render(dictation("json me"))
    let obj = parses(one) as? [String: Any]
    let keys: Set<String> = ["id", "created_at", "text_raw", "text_final", "style", "model", "cleanup", "duration_s", "landed",
                             "transcribe_ms", "clean_ms", "app"]
    check(obj.map { Set($0.keys) == keys } ?? false, "JSON: a dictation has exactly the record's snake_case keys")
    check(obj?["clean_ms"] is NSNull && obj?["transcribe_ms"] is NSNull, "JSON: missing timings are null, not absent")
    check(parses(try JSON.render([dictation("a"), dictation("b")])) is [Any], "JSON: history is an array")
    check(parses(try JSON.render(Optional<Dictation>.none)) is NSNull, "JSON: no last dictation is null")
    check((parses(JSON.error("bad \"quote\"")) as? [String: Any])?["error"] as? String == "bad \"quote\"", "JSON: errors are JSON too")
} catch { check(false, "JSON threw \(error)") }

// Config: larynx.toml reader
do {
    let c = Config.parse("""
        # comment
        key = "fn"          # trailing comment
        model = "parakeet-ultra"
        clean_deadline_s = 2
        [section]
        """)
    check(c["model"] == "parakeet-ultra" && c["key"] == "fn" && c["clean_deadline_s"] == "2", "config: reads strings, numbers, comments")
    let repo = Config.load(from: Paths.defaults.appendingPathComponent("larynx.toml"))
    check(repo.model == "parakeet-v3", "config: the repo's larynx.toml picks parakeet-v3")
}

// the fn state machine, with made-up timestamps
do {
    var k = KeyMachine()
    check(k.down(at: 0, shift: false) == .start, "fn down starts recording")
    check(k.up(at: 5) == .stop(raw: false), "fn up after a 5 s hold stops it")
    check(k.state == .idle, "back to idle after the hold")

    k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    check(k.up(at: 0.1) == .none, "a short first tap keeps recording, waiting for a second")
    check(k.down(at: 0.3, shift: false) == .none, "second tap inside 350 ms arms hands-free")
    check(k.up(at: 0.4) == .none && k.state == .handsFree, "releasing the second tap is hands-free")
    check(k.tick(at: 30) == .none && k.isRecording, "hands-free keeps recording with fn up")
    check(k.down(at: 60, shift: false) == .stop(raw: false), "the next tap stops hands-free")
    check(k.up(at: 60.1) == .none && k.state == .idle, "the stopping tap's release does nothing")

    k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    _ = k.up(at: 0.1)
    check(k.tick(at: 0.3) == .none, "a lone tap waits out the double-tap window")
    check(k.tick(at: 0.5) == .stop(raw: false) && k.state == .idle, "a lone tap ends when the window closes (empty text is dropped later)")

    k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    _ = k.up(at: 0.1)
    check(k.down(at: 0.9, shift: false) == .stop(raw: false), "a second press after the window ends the first recording")

    k = KeyMachine()
    check(k.flags(fn: true, shift: false, control: true, at: 0, wasFn: false) == .start, "fn+control starts recording")
    check(k.flags(fn: false, shift: false, at: 0.2, wasFn: true) == .none && k.state == .handsFree, "releasing fn+control is hands-free")
    check(k.tick(at: 45) == .none && k.isRecording, "hands-free keeps recording with nothing held")
    check(k.flags(fn: true, shift: false, at: 50, wasFn: false) == .stop(raw: false), "the next fn press stops it")
    check(k.flags(fn: false, shift: false, at: 50.1, wasFn: true) == .none && k.state == .idle, "back to idle")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: false, at: 0, wasFn: false)
    check(k.flags(fn: true, shift: false, control: true, at: 0.2, wasFn: true) == .none && k.state == .handsFreeArming, "control added while holding fn arms hands-free")
    check(k.flags(fn: false, shift: false, at: 0.4, wasFn: true) == .none && k.state == .handsFree, "then fn up keeps recording")

    k = KeyMachine()
    check(k.flags(fn: true, shift: true, at: 0, wasFn: false) == .start, "fn+shift down starts")
    check(k.flags(fn: false, shift: false, at: 2, wasFn: true) == .stop(raw: true), "fn+shift gives the raw path")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: false, at: 0, wasFn: false)
    _ = k.flags(fn: true, shift: true, at: 0.5, wasFn: true)
    check(k.flags(fn: false, shift: true, at: 2, wasFn: true) == .stop(raw: true), "shift added while holding fn gives raw")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: false, at: 0, wasFn: false)
    check(k.flags(fn: true, shift: false, at: 0.2, wasFn: true) == .none, "a repeated fn-down flag does nothing")
    check(k.otherKey(at: 0.3) == .cancel && k.state == .idle, "fn+another key (a shortcut) cancels, not a dictation")

    k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    check(k.otherKey(at: 3) == .none && k.isRecording, "a key pressed long into a hold does not cancel the dictation")
}

// ⌃⇧ tapped alone is the same hands-free toggle as fn+⌃, for a keyboard with no fn key
do {
    var k = KeyMachine()
    check(k.flags(fn: false, shift: false, control: true, at: 0, wasFn: false) == .none, "control alone does nothing")
    check(k.flags(fn: false, shift: true, control: true, at: 0.05, wasFn: false) == .none && k.state == .idle, "⌃⇧ down waits for its release")
    check(k.flags(fn: false, shift: true, control: false, at: 0.2, wasFn: false) == .start && k.state == .handsFree, "releasing ⌃⇧ starts hands-free")
    check(k.flags(fn: false, shift: false, control: false, at: 0.25, wasFn: false) == .none && k.state == .handsFree, "letting go of the last key changes nothing")
    check(k.otherKey(at: 10) == .none && k.isRecording, "typing during hands-free keeps recording")
    _ = k.flags(fn: false, shift: true, control: false, at: 40, wasFn: false)
    _ = k.flags(fn: false, shift: true, control: true, at: 40.1, wasFn: false)
    check(k.flags(fn: false, shift: false, control: false, at: 40.2, wasFn: false) == .stop(raw: false) && k.state == .idle, "the next ⌃⇧ tap stops it")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, at: 0, wasFn: false)
    check(k.otherKey(at: 0.1) == .none, "⌃⇧+key is a shortcut")
    check(k.flags(fn: false, shift: false, control: false, at: 0.3, wasFn: false) == .none && k.state == .idle, "⌃⇧+key never starts a recording")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, at: 0, wasFn: false)
    k.click()
    check(k.flags(fn: false, shift: false, control: false, at: 0.3, wasFn: false) == .none && k.state == .idle, "⌃⇧-click never starts a recording")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, at: 0, wasFn: false)
    _ = k.flags(fn: false, shift: true, control: true, other: true, at: 0.1, wasFn: false)
    check(k.flags(fn: false, shift: false, control: false, at: 0.3, wasFn: false) == .none && k.state == .idle, "⌃⇧ with ⌘ or ⌥ added does nothing")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, other: true, at: 0, wasFn: false)
    _ = k.flags(fn: false, shift: true, control: true, at: 0.1, wasFn: false)
    check(k.flags(fn: false, shift: false, control: false, at: 0.2, wasFn: false) == .none && k.state == .idle, "letting go of ⌘ down to ⌃⇧ does not arm it")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, at: 0, wasFn: false)
    check(k.flags(fn: false, shift: false, control: false, at: 1.5, wasFn: false) == .none && k.state == .idle, "⌃⇧ held over a second is not a tap")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: true, control: true, at: 0, wasFn: false)
    check(k.state == .handsFreeArming, "fn+⌃⇧ stays the fn path")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, at: 0, wasFn: false)
    _ = k.flags(fn: false, shift: false, control: false, at: 0.1, wasFn: false)
    check(k.flags(fn: true, shift: false, at: 30, wasFn: false) == .stop(raw: false), "fn also stops a ⌃⇧ hands-free")
    _ = k.flags(fn: false, shift: false, at: 30.1, wasFn: true)
    check(k.state == .idle, "back to idle after the fn stop")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: false, control: true, at: 0, wasFn: false)
    _ = k.flags(fn: false, shift: false, control: false, at: 0.2, wasFn: true)
    _ = k.flags(fn: false, shift: true, control: true, at: 20, wasFn: false)
    check(k.flags(fn: false, shift: false, control: false, at: 20.1, wasFn: false) == .stop(raw: false) && k.state == .idle, "⌃⇧ also stops a fn+⌃ hands-free")

    k = KeyMachine()
    _ = k.flags(fn: false, shift: true, control: true, at: 0, wasFn: false)
    _ = k.flags(fn: false, shift: false, control: false, at: 0.1, wasFn: false)
    check(k.escape() == .cancel && k.state == .idle, "Esc cancels a ⌃⇧ hands-free")
}

// a missed fn release never leaves Larynx stuck
do {
    var k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    check(k.watch(fnDown: true, at: 0.1) == .none && k.isRecording, "watch leaves a real hold alone")
    check(k.watch(fnDown: false, at: 3) == .stop(raw: false) && k.state == .idle, "watch ends a hold whose release the tap missed")
    check(k.up(at: 3.1) == .none, "a late release after watch stopped it does nothing")

    k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    check(k.watch(fnDown: false, at: 0.1) == .none && k.isRecording, "watch ignores fn up until it has seen fn down (system that never reports fn)")
    check(k.watch(fnDown: false, at: 119) == .none && k.isRecording, "a hold under max_hold_s keeps going")
    check(k.watch(fnDown: false, at: 121) == .stop(raw: false) && k.state == .idle, "a hold past max_hold_s ends and keeps its text")

    k = KeyMachine()
    _ = k.down(at: 0, shift: true)
    _ = k.watch(fnDown: true, at: 0.1)
    check(k.watch(fnDown: false, at: 0.2) == .none && k.state != .idle, "a short missed release still becomes a tap, as with the tap")
    check(k.tick(at: 1) == .stop(raw: true), "that tap ends when the window closes, raw kept")

    k = KeyMachine(maxHandsFree: 600)
    _ = k.flags(fn: true, shift: false, control: true, at: 0, wasFn: false)
    _ = k.watch(fnDown: true, at: 0.1)
    check(k.watch(fnDown: false, at: 0.5) == .none && k.state == .handsFree, "a missed release of fn+control still starts hands-free")
    check(k.watch(fnDown: false, at: 300) == .none && k.isRecording, "hands-free under max_handsfree_s keeps going")
    check(k.watch(fnDown: false, at: 601) == .stop(raw: false) && k.state == .idle, "hands-free past max_handsfree_s ends")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: false, control: true, at: 0, wasFn: false)
    _ = k.up(at: 0.3)
    check(k.down(at: 30, shift: false) == .stop(raw: false) && k.state == .stopping, "hands-free stop press")
    _ = k.watch(fnDown: true, at: 30.1)
    check(k.watch(fnDown: false, at: 30.3) == .none && k.state == .idle, "a missed release of the stopping press returns to idle")

    let c = Config(values: Config.parse("max_hold_s = 90\nmax_handsfree_s = 300"))
    check(c.maxHold == 90 && c.maxHandsFree == 300 && Config().maxHold == 120, "larynx.toml sets the time limits")
}

// after each failure the next recording decides: recovery is a landed recording, not a live process
do {
    func line(_ pid: Int, _ text: String, day: Int = 1) -> String { "2026-11-0\(day) 10:00:00.000 Larynx[\(pid):9] larynx: \(text)" }
    func outcome(_ result: String) -> String { "outcome ABCD mic=x audio=1.0s result=\(result) words=1" }
    func row(_ r: RecoveryReport, _ k: String) -> RecoveryReport.Row { r.rows.first { $0.kind == k }! }

    var r = RecoveryReport.parse([line(1, outcome("mic-error(x)")), line(1, outcome("mic-error(x)")), line(2, outcome("pasted"))].joined(separator: "\n"))
    check(row(r, "mic-error").total == 2 && row(r, "mic-error").failed == 1 && row(r, "mic-error").recovered == 1, "a repeated mic error counts as a failed recovery, then a landed one")
    check(row(r, "restart").recovered == 1 && !r.ok, "a new pid is a restart, and any failed recovery means not ok")

    r = RecoveryReport.parse([line(1, "main thread stuck 12 s"), line(2, outcome("clipboard"))].joined(separator: "\n"))
    check(row(r, "hang").recovered == 1 && r.ok, "a hang recovers when the next recording lands on the clipboard")

    r = RecoveryReport.parse([line(1, "mic closed (sleep)"), line(1, outcome("cancelled")), line(1, outcome("empty")), line(1, outcome("silent"))].joined(separator: "\n"))
    check(row(r, "sleep").failed == 1 && row(r, "silent").waiting == 1, "cancelled and empty say nothing; a silent one fails the sleep and waits itself")

    r = RecoveryReport.parse([line(1, outcome("error(x)")), line(1, outcome("silent"), day: 2), line(1, outcome("pasted"), day: 2)].joined(separator: "\n"), since: "2026-11-02")
    check(row(r, "error").total == 0 && row(r, "silent").recovered == 1, "--since drops older lines")
    check(RecoveryReport.parse("noise\nLarynxApp[1:2] larynx: outcome x result=error(y)").rows.allSatisfy { $0.total == 0 }, "other processes' lines are ignored")
}

// after any early end the keys are idle, so the next press records
do {
    func nextPressRecords(_ k: inout KeyMachine, at t: Double) -> Bool { k.state == .idle && k.down(at: t, shift: false) == .start }
    var k = KeyMachine()
    _ = k.down(at: 0, shift: false); _ = k.watch(fnDown: true, at: 0.1); _ = k.watch(fnDown: false, at: 3)
    check(nextPressRecords(&k, at: 4), "the next press records after a missed release")
    k = KeyMachine()
    _ = k.down(at: 0, shift: false); _ = k.watch(fnDown: false, at: 121)
    check(nextPressRecords(&k, at: 122), "the next press records after the time limit")
    k = KeyMachine()
    _ = k.down(at: 0, shift: false); _ = k.escape(); _ = k.up(at: 1)
    check(nextPressRecords(&k, at: 2), "the next press records after Esc")
}

// Esc cancels any recording
do {
    var k = KeyMachine()
    _ = k.down(at: 0, shift: false)
    check(k.escape() == .cancel && k.state == .idle, "Esc cancels a hold")
    check(k.up(at: 2) == .none, "the fn release after Esc does nothing")
    check(k.escape() == .none, "Esc when idle does nothing")

    k = KeyMachine()
    _ = k.flags(fn: true, shift: false, control: true, at: 0, wasFn: false)
    _ = k.up(at: 0.3)
    check(k.escape() == .cancel && k.state == .idle, "Esc cancels hands-free")

    k = KeyMachine()
    _ = k.down(at: 0, shift: false); _ = k.up(at: 0.1)
    check(k.escape() == .cancel && k.state == .idle, "Esc cancels a lone tap waiting for its second")
}

// Dashboard totals: words, fixes, daily rows that outlast the 30-day prune
do {
    check(History.words("Ask Claude to fix it, please.") == 6, "dashboard: words counts word runs")
    check(History.fixes(raw: "um so ask clawed to fix it", final: "So ask Claude to fix it.") == 2, "dashboard: fixes counts fillers out and names changed")
    check(History.fixes(raw: "Hello there.", final: "hello there") == 0, "dashboard: case and punctuation are not fixes")
    let path = freshDB("days")
    var h = try History(path: path)
    var a = dictation("um ask clawed now", daysAgo: 40); a.textFinal = "Ask Claude now."; a.cleanup = "rules"; a.app = "com.anthropic.claudefordesktop"
    try h.save(a)
    var b = dictation("hello there"); b.app = "com.tinyspeck.slackmacgap"
    try h.save(b)
    var c = dictation("second one today"); c.app = "com.tinyspeck.slackmacgap"
    try h.save(c)
    try h.setLanded(id: c.id, .pasted)
    var days = try h.days()
    check(days.count == 2, "dashboard: one daily row per day")
    check(days.last?.dictations == 2 && days.last?.words == 5, "dashboard: today's row sums its dictations")
    check(days.last?.keptSafe == 1, "dashboard: kept_safe counts clipboard landings and follows setLanded")
    check(days.first?.fixes == 2, "dashboard: fixes are summed per day")
    h = try History(path: path) // reopening prunes the 40-day-old row
    days = try h.days()
    check(try h.all().count == 2 && days.count == 2, "dashboard: daily totals outlast the 30-day prune")
    check(try h.last()?.app == "com.tinyspeck.slackmacgap", "dashboard: the app name is stored and read back")
}

// is a text box focused? The decision table
do {
    let table: [(FocusInfo?, Bool, String)] = [
        (FocusInfo(role: "AXTextField"), true, "text field"),
        (FocusInfo(role: "AXTextArea"), true, "text area (Notes, Terminal, Mail body)"),
        (FocusInfo(role: "AXComboBox"), true, "combo box"),
        (FocusInfo(role: "AXTextField", subrole: "AXSearchField"), true, "search field"),
        (FocusInfo(role: "AXGroup", editable: true), true, "web contenteditable (AXEditable)"),
        (FocusInfo(role: "AXWebArea", valueSettable: true), true, "unknown role with a settable value"),
        (FocusInfo(role: "AXSlider", valueSettable: true), false, "slider: settable value but not text"),
        (FocusInfo(role: "AXCheckBox", valueSettable: true), false, "checkbox"),
        (FocusInfo(role: "AXButton"), false, "button"),
        (FocusInfo(role: "AXList"), false, "Finder file list"),
        (FocusInfo(role: "AXScrollArea"), false, "desktop"),
        (FocusInfo(role: nil, app: "com.anthropic.claudefordesktop"), true, "Claude app, focus not answered yet: paste"),
        (FocusInfo(role: "AXGroup", app: "com.tinyspeck.slackmacgap"), true, "Electron, vague role: paste"),
        (FocusInfo(role: "AXWebArea"), true, "web area, not sure: paste"),
        (FocusInfo(role: nil, app: "com.apple.finder"), false, "Finder with no focus: clipboard"),
        (FocusInfo(role: "AXGroup", app: "com.apple.finder"), false, "Finder desktop group: clipboard"),
        (nil, true, "probe got nothing: paste (text is saved anyway)"),
    ]
    for (info, want, name) in table { check(FocusInfo.shouldPaste(info) == want, "focus: \(name) -> \(want ? "paste" : "clipboard")") }
}

// deliver saves, then clipboard, then at most one paste
final class Log { var steps: [String] = [] }
struct LogClipboard: Clipboard {
    let log: Log; let history: History
    func write(_ text: String) throws {
        log.steps.append((try? history.last()?.textFinal) == text ? "clipboard(after save)" : "clipboard(BEFORE save)")
    }
}
struct FixedFocus: FocusProbe {
    let info: FocusInfo?
    func focused() -> FocusInfo? { info }
}
struct LogPaster: Paster {
    let log: Log
    func pasteOnce() throws { log.steps.append("cmd+v") }
}
do {
    let h = try History(path: freshDB("deliver"))
    let log = Log()
    let d = try deliver(dictation("into the box"), history: h, clipboard: LogClipboard(log: log, history: h),
                        focus: FixedFocus(info: FocusInfo(role: "AXTextArea")), paster: LogPaster(log: log),
                        onSaved: { log.steps.append("drop audio") })
    check(log.steps == ["drop audio", "clipboard(after save)", "cmd+v"], "save, drop audio, clipboard, then exactly one Cmd+V")
    let row = try h.last()?.landed; check(d.landed == .pasted && row == .pasted, "landed = pasted in history")

    let log2 = Log()
    let d2 = try deliver(dictation("no box"), history: h, clipboard: LogClipboard(log: log2, history: h),
                         focus: FixedFocus(info: FocusInfo(role: "AXScrollArea")), paster: LogPaster(log: log2))
    check(log2.steps == ["clipboard(after save)"], "no text box, no key event at all")
    let row2 = try h.last()?.landed; check(d2.landed == .clipboard && row2 == .clipboard, "landed = clipboard in history")
    check(PillText.result(.clipboard) == "No text box. On your clipboard, ⌘V to paste.", "the pill text")
} catch { check(false, "deliver threw \(error)") }

// inflight audio survives a crash and is recovered into history, then deleted
do {
    let home = tmp.appendingPathComponent("home")
    setenv("LARYNX_HOME", home.path, 1)
    defer { unsetenv("LARYNX_HOME") }
    check(Inflight.dir.path.hasPrefix(home.path), "inflight: LARYNX_HOME moves the inflight folder")

    // A writer that is never closed, like a process killed mid-sentence.
    let tone = (0..<24_000).map { Float(sin(Double($0) * 0.05) * 0.3) }
    let crashed = try CafWriter(url: Inflight.url(for: "crashed"))
    crashed.append(Array(tone[..<8_000]))
    crashed.append(Array(tone[8_000...]))
    let back = try Inflight.read(Inflight.url(for: "crashed"))
    check(back.count == 24_000 && back[100] == tone[100], "an unclosed CAF reads back every sample")
    let raw = try Data(contentsOf: Inflight.url(for: "crashed"))
    let torn = tmp.appendingPathComponent("torn.caf")
    try raw.prefix(raw.count - 2).write(to: torn)  // killed mid-sample
    check(try Inflight.read(torn).count == 23_999, "a file torn mid-sample gives every whole sample")
    let avRead = try AVAudioFile(forReading: Inflight.url(for: "crashed"))
    check(avRead.fileFormat.sampleRate == 16_000 && avRead.fileFormat.channelCount == 1, "inflight CAF is a valid 16 kHz mono CAF for Core Audio")

    let empty = try CafWriter(url: Inflight.url(for: "silent"))
    empty.append([Float](repeating: 0, count: 1_600))
    empty.close()

    let h = try History(path: home.appendingPathComponent("history.db"))
    let log = Log()
    let files = Inflight.leftovers()
    check(files.count == 2, "launch finds both leftover files")
    let found = await Inflight.recover(files, model: "parakeet-v3", history: h, clipboard: LogClipboard(log: log, history: h)) { s in
        s.allSatisfy { $0 == 0 } ? "" : "words from before the crash"
    }
    check(try h.all().map(\.textRaw) == ["words from before the crash"], "recovered text is in history")
    check(try h.last()?.landed == .clipboard && h.last()?.id == "crashed", "recovered row is landed = clipboard, same id")
    check(log.steps == ["clipboard(after save)"], "recovery also puts it on the clipboard, after saving")
    check(found.count == 2 && Inflight.leftovers().isEmpty, "recovered and empty files are deleted")

    let failing = try CafWriter(url: Inflight.url(for: "retry"))
    failing.append(tone)
    _ = await Inflight.recover(Inflight.leftovers(), model: "m", history: h, clipboard: LogClipboard(log: log, history: h)) { _ in
        throw HandOverError.clipboard
    }
    check(Inflight.leftovers().count == 1, "a file that fails to transcribe stays for the next launch")
} catch { check(false, "inflight threw \(error)") }


// words.toml: an entry with a control character never reaches the cleaner
do {
    var skipped: [String] = []
    let words = Rules.parseWords("""
        [[word]]
        spell = "rm -rf\\n"
        [[word]]
        spell = "Larynx"
        sounds_like = ["lar\\tinks"]
        [[word]]
        spell = "Claude"
        sounds_like = ["clawed"]
        """) { skipped.append($0) }
    check(words.map(\.spell) == ["Claude"], "words.toml: entries with \\n or \\t in spell or sounds_like are skipped")
    check(skipped == ["rm -rf\n", "Larynx"], "words.toml: skipped entries are reported")
}

// the rules cleanup
do {
    let repoRules = Rules.parse(words: (try? String(contentsOf: Paths.defaults.appendingPathComponent("words.toml"), encoding: .utf8)) ?? "",
                                styles: (try? String(contentsOf: Paths.defaults.appendingPathComponent("styles.toml"), encoding: .utf8)) ?? "")
    let cleaner = Cleaner(rules: repoRules)
    let plain = Style.plain
    func c(_ raw: String, _ style: Style = Style.plain) -> String { cleaner.clean(raw, style: style) }
    func style(_ app: String?) -> String { repoRules.style(forApp: app).name }

    // TOML reader
    let doc = TOMLDoc.parse("""
        default = "x" # c
        [style.a]
        apps = [
          "one",   # first
          "t#wo",
        ]
        flag = true
        [[word]]
        spell = "Q\\"uote"
        sounds_like = ["a b", "c"]
        [[word]]
        spell = "Second"
        """)
    check(doc.root["default"]?.string == "x", "toml: root string with a trailing comment")
    check(doc.tables["style.a"]?["apps"]?.list == ["one", "t#wo"], "toml: multi-line array with comments and # inside a string")
    check(doc.tables["style.a"]?["flag"]?.bool == true, "toml: booleans")
    check(doc.arrays["word"]?.count == 2 && doc.arrays["word"]?[0]["spell"]?.string == "Q\"uote", "toml: [[word]] entries and escapes")

    // the repo files
    check(repoRules.words.contains { $0.spell == "Claude" && $0.soundsLike.contains("clawed") && $0.unlessAfter.contains("cat") },
          "words.toml: Claude with sounds_like and guards")
    check(["Claude", "Larynx", "Parakeet", "Handy", "Wispr"].allSatisfy { w in repoRules.words.contains { $0.spell == w } },
          "words.toml: ships the starting words")
    check(style("com.tinyspeck.slackmacgap") == "chat" && style("com.apple.MobileSMS") == "chat" && style("com.anthropic.claudefordesktop") == "chat",
          "Slack, Messages and Claude get chat")
    check(style("com.apple.mail") == "mail", "Mail gets mail")
    check(style("dev.zed.Zed") == "plain" && style("com.apple.Terminal") == "plain", "Zed and Terminal get plain")
    check(style("com.example.unknown") == "default" && style(nil) == "default", "styles: an unknown app gets the default style")
    check(repoRules.style(forApp: "com.example.unknown").firstLetter == .upper, "styles: the default is mail-like (sentence case)")

    // fillers
    check(c("Um, so the demo") == "So the demo", "fillers: \"Um, so the demo\" -> \"So the demo\"")
    check(c("so um the uh demo erm works hmm") == "so the demo works", "fillers: um, uh, erm, hmm go, mid-sentence")
    check(c("UM UHM ER Mm the plan") == "The plan", "fillers: any case, uhm, er, mm")
    check(c("it works um.") == "it works.", "fillers: the sentence end a filler carried stays")
    check(c("Uh. Okay. Um.") == "Okay.", "fillers: filler-only sentences go")
    check(c("I think, um, we should") == "I think we should", "fillers: the comma pair around a filler goes")
    check(c("Yes, um, I agree") == "Yes, I agree", "fillers: an interjection keeps its comma")
    check(c("it is like you know fine") == "it is like you know fine", "fillers: \"like\" and \"you know\" stay")
    check(c("cut it to 5 mm please") == "cut it to 5 mm please", "fillers: mm after a number is millimetres")
    check(c("Uh-huh, umbrella, hummus, error, mummy") == "Uh-huh, umbrella, hummus, error, mummy", "fillers: real words that start like fillers stay")
    check(c("The the demo is is on") == "The demo is is on", "stutter: \"the the\" -> \"the\", but \"is is\" stays")
    check(c("I, I think so so and that that had had") == "I think so so and that that had had", "stutter: only stumble words")
    check(c("um") == "", "fillers: only a filler leaves nothing (the app then keeps the raw text)")

    // words.toml
    check(c("ask clawed to fix it") == "ask Claude to fix it", "\"ask clawed to fix it\" -> \"ask Claude to fix it\"")
    check(c("the cat clawed the sofa") == "the cat clawed the sofa", "\"the cat clawed the sofa\" stays")
    check(c("it clawed at the door and the bear clawed back") == "it clawed at the door and the bear clawed back", "guards before and after")
    check(c("the company clawed back bonuses") == "the company clawed back bonuses", "\"clawed back\" stays")
    check(c("ask CLAUD and clawed's answer") == "ask Claude and Claude's answer", "words: any case, and possessives")
    check(c("ask chat gpt about git hub") == "ask ChatGPT about GitHub", "words: multi-word sound-alike")
    check(c("whisper flow costs money, whisper quietly") == "Wispr Flow costs money, whisper quietly", "words: longest match first; bare whisper stays")
    check(c("that's handy, open handy") == "that's handy, open Handy", "handy the adjective stays")
    check(c("clawedia and declawed") == "clawedia and declawed", "words: whole words only")
    check(c("see https://clawed.ai/demo/um or ~/demo/um.txt and claude.md") == "see https://clawed.ai/demo/um or ~/demo/um.txt and claude.md",
          "words: URLs and file paths are never touched")
    check(c("clawed, the plan") == "Claude, the plan", "words: punctuation after a word is kept")

    // styles
    let chat = repoRules.style(forApp: "com.tinyspeck.slackmacgap")
    let mail = repoRules.style(forApp: "com.apple.mail")
    check(c("sounds good to me", chat) == "Sounds good to me.", "chat: proper sentence case, full stop added")
    check(c("okay, shall we check. i asked clawed and it works", chat) == "Okay, shall we check. I asked Claude and it works.", "chat: every sentence capitalised, i is I")
    check(c("clawed is ready.", chat) == "Claude is ready.", "chat: a fixed name keeps its capital")
    check(c("is it ready?", chat) == "Is it ready?", "chat: a question mark is not doubled")
    check(c("is it ready", chat) == "Is it ready?", "chat: a question with no mark gets ?")
    check(c("okay so what do you think", chat) == "Okay so what do you think.", "chat: only the first word decides; no guessing mid-sentence")
    check(c("I am in. Are you?", chat) == "I am in. Are you?", "chat: I stays, ? stays")
    check(c("API keys are off...", chat) == "API keys are off...", "chat: acronyms and ellipses stay")
    check(c("sounds good to me.", mail) == "Sounds good to me.", "mail: sentence case, final period kept")
    check(c("Um, sounds good.", plain) == "Sounds good.", "plain: fillers out, nothing else")
    check(c("sounds good", plain) == "sounds good", "plain: no capital added")

    // every number and every words.toml word in the raw text survives
    let samples = [
        "Um, so Claude said the Larynx demo is on Friday at 3, uh, with 12 people and 4.5 hours",
        "ask clawed about the 2026 budget, um, 15 percent of 300 is 45",
        "Larynx, Parakeet, Handy and Wispr cost 0 dollars um",
    ]
    let numberRegex = try NSRegularExpression(pattern: "[0-9]+(\\.[0-9]+)?")
    func numbers(_ s: String) -> [String] {
        numberRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
    }
    for st in [plain, chat, mail] {
        let ok = samples.allSatisfy { raw in
            let out = cleaner.clean(raw, style: st)
            let wordsOK = repoRules.words.allSatisfy { w in !raw.contains(w.spell) || out.contains(w.spell) }
            return numbers(raw) == numbers(out) && wordsOK
        }
        check(ok, "numbers and words.toml words survive (\(st.name) style)")
    }
    check(c("Um, so the demo") == c("Um, so the demo"), "deterministic: the same input gives the same output")

    // speed. A 200-word paragraph, 1000 runs, median under 2 ms.
    let base = "Um, so I told clawed that the larynx demo, uh, needs 3 more slides and the the numbers from Friday. "
    var para = ""
    while para.split(separator: " ").count < 200 { para += base }
    let words200 = para.split(separator: " ").prefix(200).joined(separator: " ")
    var times: [Double] = []
    for _ in 0..<1000 {
        let t = DispatchTime.now()
        _ = cleaner.clean(words200, style: chat)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6)
    }
    let perf = TimingStats(times)
    print(String(format: "      cleaner, 200 words x 1000: median %.3f ms, p95 %.3f ms", perf.median ?? -1, perf.p95 ?? -1))
    // A shared CI machine is too loaded for a time limit; the number above still prints.
    if ProcessInfo.processInfo.environment["CI"] == nil {
        check((perf.median ?? 99) < 2, "cleaner median under 2 ms on 200 words (1000 runs)")
    }
} catch { check(false, "cleaner threw \(error)") }

// rules reload when a file changes, and `words add` appends safely
do {
    let dir = tmp.appendingPathComponent("config")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wordsFile = dir.appendingPathComponent("words.toml")
    let stylesFile = dir.appendingPathComponent("styles.toml")
    try "# my words\n\n[[word]]\nspell = \"Claude\"\nsounds_like = [\"clawed\"]\n".write(to: wordsFile, atomically: true, encoding: .utf8)
    try "default = \"plain\"\n[style.plain]\n".write(to: stylesFile, atomically: true, encoding: .utf8)
    let store = RulesStore(dir: dir)
    check(store.cleaner().clean("ask zorblacks", style: .plain) == "ask zorblacks", "an unknown word is left alone")
    let reloadsBefore = store.reloads
    _ = store.cleaner()
    check(store.reloads == reloadsBefore, "no change, no re-read (one stat per file)")
    let added = try addWord("Zorblax", soundsLike: ["zorblacks", "sore blacks"], to: wordsFile)
    check(added.spell == "Zorblax" && added.soundsLike == ["zorblacks", "sore blacks"], "words add returns the new entry")
    check(store.cleaner().clean("ask zorblacks and sore blacks", style: .plain) == "ask Zorblax and Zorblax", "the next clean uses the new word, no restart")
    let text = try String(contentsOf: wordsFile, encoding: .utf8)
    check(text.hasPrefix("# my words") && text.contains("spell = \"Claude\""), "words add keeps the existing file and comments")
    var dup = false
    do { _ = try addWord("zorblax", soundsLike: [], to: wordsFile) } catch { dup = true }
    check(dup, "words add refuses a duplicate")
    var badInput = false
    do { _ = try addWord("Bad\nWord", soundsLike: [], to: wordsFile) } catch { badInput = true }
    let after = try String(contentsOf: wordsFile, encoding: .utf8)
    check(badInput && after == text, "bad input leaves the file unchanged")
    _ = try addWord("Quo\"te", soundsLike: ["quo te"], to: wordsFile)
    check(store.cleaner().clean("quo te", style: .plain) == "Quo\"te", "words add escapes quotes")
    try "default = \"chat\"\n[style.chat]\nfirst_letter = \"lower\"\nfinal_period = \"drop\"\n".write(to: stylesFile, atomically: true, encoding: .utf8)
    check(store.cleaner().clean("Fine.", app: nil).text == "fine", "a styles.toml edit applies to the next clean")
} catch { check(false, "rules store threw \(error)") }

// History: timings, and migrating a slice-2 file
do {
    let path = freshDB("migrate")
    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(path.path, &db)
    sqlite3_exec(db, """
        CREATE TABLE dictations(id TEXT PRIMARY KEY, created_at REAL NOT NULL, text_raw TEXT NOT NULL, text_final TEXT NOT NULL,
          style TEXT NOT NULL, model TEXT NOT NULL, cleanup TEXT NOT NULL, duration_s REAL NOT NULL, landed TEXT NOT NULL);
        INSERT INTO dictations VALUES('old', \(now.timeIntervalSince1970 - 60), 'old words', 'old words', 'plain', 'parakeet-v3', 'none', 1.0, 'clipboard');
        """, nil, nil, nil)
    sqlite3_close(db)
    let h = try History(path: path, now: now)
    let old = try h.last()
    check(old?.textRaw == "old words" && old?.transcribeMs == nil && old?.cleanMs == nil, "migrate: a slice-2 file opens; old rows have null timings")
    var d = dictation("new words")
    d.transcribeMs = 61.5
    d.cleanMs = 0.25
    d.cleanup = "rules"
    try h.save(d)
    let back = try h.last()
    check(back?.transcribeMs == 61.5 && back?.cleanMs == 0.25 && back?.cleanup == "rules", "history: transcribe_ms and clean_ms round-trip")
    check(try History(path: path, now: now).count() == 2, "migrate: reopening a migrated file is fine")
} catch { check(false, "history migrate threw \(error)") }

// Stats
do {
    check(TimingStats([5, 1, 3]).median == 3 && TimingStats([4, 1, 3, 2]).median == 2.5, "stats: median, odd and even")
    check(TimingStats((1...100).map(Double.init)).p95 == 95 && TimingStats([7]).p95 == 7, "stats: nearest-rank p95")
    check(TimingStats([]).median == nil && TimingStats([]).n == 0, "stats: no data is null")
    var rows: [Dictation] = []
    for (days, t) in [(0.0, 50.0), (0.0, 70.0), (3.0, 90.0), (10.0, 500.0)] {
        var r = dictation("x", daysAgo: days)
        r.transcribeMs = t
        r.cleanMs = 0.2
        rows.append(r)
    }
    rows.append(dictation("old row, no timings"))
    let s = Stats(rows, now: now)
    check(s.today.dictations == 3 && s.today.transcribe_ms.n == 2 && s.today.transcribe_ms.median == 60, "stats: today skips null timings")
    check(s.last_7_days.transcribe_ms.n == 3 && s.last_7_days.transcribe_ms.median == 70, "stats: 7 days leaves out day 10")
} 

// a stuck main thread is noticed after 10 s; a sleeping Mac is not (uptime stops in sleep)
do {
    let dog = Watchdog(limit: 10, now: 100)
    check(dog.stuck(now: 109) == nil, "9 s without a beat is not stuck")
    check(dog.stuck(now: 111) == 11, "11 s without a beat is stuck")
    dog.beat(now: 111)
    check(dog.stuck(now: 115) == nil, "a beat clears it")
    check(Watchdog().stuck() == nil, "a fresh watchdog on real uptime is not stuck")
}

// a silent mic is caught; speech, a click and short audio are not called silent
do {
    func tone(_ amp: Float, seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amp * sin(Float($0) * 0.2) }
    }
    var dead = Loudness()
    dead.add(tone(0.004, seconds: 50)) // a dead wireless mic: about -48 dBFS
    check(dead.isSilent(below: -40), "a mic at its noise floor (-48 dBFS) is silent")
    var click = Loudness()
    click.add([0.76] + tone(0.004, seconds: 30)) // one loud click at the start
    check(click.isSilent(below: -40) && click.peakDB > -3, "one click does not hide a silent mic")
    var speech = Loudness()
    speech.add(tone(0.004, seconds: 8) + tone(0.1, seconds: 1) + tone(0.004, seconds: 8))
    check(!speech.isSilent(below: -40), "1 s of speech in 16 s of pauses is not silent")
    var word = Loudness()
    word.add(tone(0.004, seconds: 300) + tone(0.1, seconds: 0.4) + tone(0.004, seconds: 300))
    check(!word.isSilent(below: -40), "one word in 10 minutes of hands-free is not silent")
    var short = Loudness()
    short.add(tone(0, seconds: 0.3))
    check(!short.isSilent(below: -40) && short.loudDB == -120, "under 0.5 s is never called silent")
    check(Config().silentBelowDB == -40 && Config(values: ["silent_below_db": "-50"]).silentBelowDB == -50,
          "larynx.toml sets the silent threshold")
    setenv("LARYNX_HOME", tmp.appendingPathComponent("silent-home").path, 1)
    try? Paths.ensurePrivateDir(Inflight.dir)
    for i in 0..<3 {
        let f = Inflight.url(for: "silent-\(i)")
        FileManager.default.createFile(atPath: f.path, contents: Data([1]))
        Silent.keep(f, limit: 2)
        check(!FileManager.default.fileExists(atPath: f.path), "a silent recording leaves inflight (\(i))")
    }
    let kept = (try? FileManager.default.contentsOfDirectory(atPath: Silent.dir.path)) ?? []
    check(kept.count == 2, "only the newest silent recordings are kept")
    let aged = Silent.dir.appendingPathComponent("aged.caf")
    FileManager.default.createFile(atPath: aged.path, contents: Data([1]))
    try? FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: aged.path)
    Silent.prune(limit: 20)
    let left = (try? FileManager.default.contentsOfDirectory(atPath: Silent.dir.path)) ?? []
    check(!left.contains("aged.caf") && left.count == 2, "a silent recording older than 30 days is deleted, the rest stay")

    // Folders are 0700 even when something else made them first.
    let loose = tmp.appendingPathComponent("loose-dir")
    try? FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    try? Paths.ensurePrivateDir(loose)
    let mode = (try? FileManager.default.attributesOfItem(atPath: loose.path)[.posixPermissions] as? Int) ?? nil
    check(mode == 0o700, "ensurePrivateDir sets an existing 0755 folder to 0700")

    // Config: with no local/ folder, Larynx reads ~/.larynx, seeded once from the shipped defaults.
    let seeded = tmp.appendingPathComponent("seed-home")
    Paths.seedConfig(into: seeded)
    let seededNames = (try? FileManager.default.contentsOfDirectory(atPath: seeded.path)) ?? []
    check(Paths.configFiles.allSatisfy(seededNames.contains), "config: the shipped defaults are copied in on first run")
    let mine = seeded.appendingPathComponent("words.toml")
    try? "# mine\n".write(to: mine, atomically: true, encoding: .utf8)
    Paths.seedConfig(into: seeded)
    check((try? String(contentsOf: mine, encoding: .utf8)) == "# mine\n", "config: a file already there is never replaced")

    // larynx.log: past the limit it moves to larynx.log.1 and the fd writes a fresh 0600 file.
    let log = tmp.appendingPathComponent("silent-home/larynx.log")
    FileManager.default.createFile(atPath: log.path, contents: Data(count: 2_000), attributes: [.posixPermissions: 0o644])
    let fd = open(log.path, O_WRONLY | O_APPEND)
    check(!LogFile.rotate(maxBytes: 5_000, fd: fd, at: log), "a log under the limit stays")
    let logMode = (try? FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int) ?? nil
    check(logMode == 0o600, "the log is set to 0600")
    check(LogFile.rotate(maxBytes: 1_000, fd: fd, at: log), "a log over the limit rotates")
    _ = "after".withCString { write(fd, $0, 5) }
    close(fd)
    check((try? Data(contentsOf: log)) == Data("after".utf8)
          && (try? Data(contentsOf: URL(fileURLWithPath: log.path + ".1")))?.count == 2_000,
          "the old log is larynx.log.1 and new lines go to a fresh larynx.log")
    check(!LogFile.rotate(maxBytes: 1, fd: STDERR_FILENO, at: log), "a log that is not our stderr is left alone")
    unsetenv("LARYNX_HOME")
}

// Clipboard: the text stays on this Mac and out of clipboard managers.
// A private named pasteboard, so the test never touches the user's clipboard.
do {
    let pb = NSPasteboard(name: NSPasteboard.Name("larynx-selftest-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    pb.clearContents()
    pb.setString("old", forType: NSPasteboard.PasteboardType("public.html"))
    try SystemClipboard(pb).write("the demo on Friday")
    let types = pb.types ?? []
    check(pb.string(forType: .string) == "the demo on Friday", "clipboard: the text is on the clipboard as .string for Cmd+V")
    check(types.contains(SystemClipboard.transient), "clipboard: the write carries the Transient marker")
    check(types.contains(SystemClipboard.concealed), "clipboard: the write carries the Concealed marker")
    check(!types.contains(NSPasteboard.PasteboardType("public.html")), "clipboard: the old contents are cleared")
} catch { check(false, "clipboard write threw \(error)") }

// Debug variables: the release app ignores its environment; the debug socket refuses idle and huge clients.
do {
    let short = URL(fileURLWithPath: "/tmp/lx-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: short) }
    Paths.trustsEnvironment = false
    setenv("LARYNX_HOME", short.path, 1)
    setenv("LARYNX_CONFIG_DIR", short.path, 1)
    setenv("LARYNX_DEBUG", "1", 1)
    // Untrusted `config` would fall back to (and seed) the real ~/.larynx, so only `home` is read here;
    // both go through the same `override`.
    check(!Paths.home.path.hasPrefix(short.path), "debug env: untrusted, LARYNX_HOME is ignored")
    check(!DebugChannel.enabled, "debug env: untrusted, LARYNX_DEBUG does not open the debug socket")
    Paths.trustsEnvironment = true
    check(Paths.home.path == short.path && Paths.config.path == short.path && DebugChannel.enabled,
          "debug env: trusted (CLI, debug build), the variables count")
    unsetenv("LARYNX_CONFIG_DIR")
    unsetenv("LARYNX_DEBUG")

    func connectRaw() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in Array(DebugChannel.path.path.utf8).enumerated() { raw[i] = b }
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return fd
    }
    do {
        try DebugChannel.serve { req, reply in reply(req) }
        let idle = connectRaw() // connects and sends nothing
        defer { close(idle) }
        let t0 = Date()
        let echo = try? DebugChannel.request(Data("{\"cmd\":\"state\"}".utf8), timeout: 3)
        check(echo == Data("{\"cmd\":\"state\"}".utf8) && Date().timeIntervalSince(t0) < 2,
              "debug socket: an idle client does not block the next one")
        let big = connectRaw()
        defer { close(big) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(big, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(big, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let chunk = [UInt8](repeating: 0x61, count: 80 * 1024)
        _ = chunk.withUnsafeBytes { write(big, $0.baseAddress!, $0.count) }
        var byte: UInt8 = 0
        check(read(big, &byte, 1) <= 0, "debug socket: a request over 64 KB is dropped without a reply")
    } catch { check(false, "debug socket: \(error)") }
    unsetenv("LARYNX_HOME")
}

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
