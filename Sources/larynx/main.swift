import FluidAudio
import Foundation
import LarynxCore
import LarynxSpeech

let usage = """
    larynx: private dictation for this Mac.

      larynx transcribe <audio-file> [--app <bundle id>] [--raw] [--json]
                                                speech to text, clean, then save and copy
      larynx clean "<text>" [--app <bundle id>] [--json]
                                                run the rules cleanup on text (nothing is saved)
      larynx words [--json]                     the words in words.toml
      larynx words add <Word> --sounds-like "<a>" ["<b>"...] [--json]
                                                add a word to words.toml (the next dictation uses it)
      larynx last [--json]                      the last dictation
      larynx history [--json]                   the last 30 days, newest first
      larynx stats [--json]                     median and p95 of transcribe_ms and clean_ms, today and 7 days
      larynx status [--json]                    model, files, counts
      larynx models fetch [--json]              download the speech model (the only network use)
      larynx debug feed <wav> [--raw] [--stream] [--no-paste] [--app <bundle id>] [--json]
                                                run a WAV through the running app's pipeline (app launched with LARYNX_DEBUG=1)
      larynx debug state [--json]               the running app's state (same condition)
    """

let asJSON = CommandLine.arguments.contains("--json")
let args = CommandLine.arguments.dropFirst().filter { $0 != "--json" }

func emit<T: Encodable>(_ value: T, text: () -> String) throws {
    print(asJSON ? try JSON.render(value) : text())
}

func describe(_ d: Dictation) -> String {
    "\(JSON.iso(d.createdAt))  \(String(format: "%.1f", d.durationS))s  \(d.model)  \(d.landed.rawValue)\n\(d.textFinal)"
}

struct Timing: Encodable {
    let load_s: Double
    let transcribe_s: Double
    let clean_ms: Double?
    let total_s: Double
}

struct CleanOut: Encodable {
    let raw: String
    let final: String
    let style: String
    let app: String?
    let clean_ms: Double
}

/// The value after a flag, e.g. `--app com.apple.mail`.
func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Arguments with `--flag value` pairs and bare `--flags` taken out.
func positional(_ args: [String], valued: Set<String> = ["--app"]) -> [String] {
    var out: [String] = []
    var skip = false
    for a in args {
        if skip { skip = false; continue }
        if valued.contains(a) { skip = true; continue }
        if a.hasPrefix("--") { continue }
        out.append(a)
    }
    return out
}

func ms(since t: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e6
}

struct TranscribeOut: Encodable {
    let dictation: Dictation
    let timing: Timing
}

struct Status: Encodable {
    let model: String
    let model_present: Bool
    let model_dir: String
    let model_bytes: Int64
    let history: String
    let dictations: Int
    let oldest: Date?
    let config: String
    let paste: String
}

struct Fetched: Encodable {
    let model: String
    let dir: String
    let bytes: Int64
    let seconds: Double
}

func seconds(since t: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1e9
}

@MainActor func run(_ args: [String]) async throws {
    let config = Config.load()
    switch args.first {
    case "transcribe":
        let pos = positional(args)
        guard pos.count >= 2 else { throw CLIError("usage: larynx transcribe <audio-file> [--app <bundle id>] [--raw] [--json]") }
        let file = URL(fileURLWithPath: pos[1])
        guard FileManager.default.fileExists(atPath: file.path) else { throw CLIError("no such file: \(file.path)") }
        let model = try SpeechModel.named(config.model)
        let history = try History()  // open before transcribing so a bad store fails early
        let t0 = DispatchTime.now()
        let models = try model.load()
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        let loadS = seconds(since: t0)
        let t1 = DispatchTime.now()
        var state = try TdtDecoderState(decoderLayers: model.version.decoderLayers)
        let result = try await manager.transcribe(file, decoderState: &state)
        let transcribeS = seconds(since: t1)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var d = Dictation(textRaw: text, model: model.name, durationS: result.duration, transcribeMs: transcribeS * 1000)
        if !args.contains("--raw") {
            let t2 = DispatchTime.now()
            let cleaned = RulesStore().cleaner().clean(text, app: option("--app", in: args))
            d.cleanMs = ms(since: t2)
            d.cleanup = "rules"
            d.style = cleaned.style
            d.textFinal = cleaned.text.isEmpty ? text : cleaned.text
        } else { d.style = "none" }
        d = try handOver(d, history: history)
        let out = TranscribeOut(dictation: d, timing: Timing(load_s: loadS, transcribe_s: transcribeS, clean_ms: d.cleanMs,
                                                             total_s: seconds(since: t0)))
        try emit(out) { "\(d.textFinal)\n(on your clipboard; \(String(format: "%.2f", transcribeS))s to transcribe)" }

    case "clean":
        let pos = positional(args)
        guard pos.count >= 2 else { throw CLIError("usage: larynx clean \"<text>\" [--app <bundle id>] [--json]") }
        let raw = pos[1...].joined(separator: " ")
        let app = option("--app", in: args)
        let cleaner = RulesStore().cleaner()
        let t = DispatchTime.now()
        let cleaned = cleaner.clean(raw, app: app)
        let out = CleanOut(raw: raw, final: cleaned.text, style: cleaned.style, app: app, clean_ms: ms(since: t))
        try emit(out) { cleaned.text }

    case "words":
        let store = RulesStore()
        if args.count >= 2, args[1] == "add" {
            guard args.count >= 3, !args[2].hasPrefix("--") else {
                throw CLIError("usage: larynx words add <Word> --sounds-like \"<a>\" [\"<b>\"...]")
            }
            var sounds: [String] = []
            if let i = args.firstIndex(of: "--sounds-like") {
                sounds = Array(args[(i + 1)...].prefix { !$0.hasPrefix("--") })
            }
            let added = try addWord(args[2], soundsLike: sounds, to: store.wordsFile)
            try emit(added) { "added \(added.spell) to \(store.wordsFile.path); the next dictation uses it" }
        } else if args.count == 1 {
            let words = store.rules.words
            try emit(words) {
                words.map { "\($0.spell)\($0.soundsLike.isEmpty ? "" : "  <- " + $0.soundsLike.joined(separator: ", "))" }
                    .joined(separator: "\n")
            }
        } else { throw CLIError("usage: larynx words [add <Word> --sounds-like \"<a>\"]") }

    case "stats":
        let s = Stats(try History().all())
        func line(_ name: String, _ p: PeriodStats) -> String {
            func f(_ t: TimingStats) -> String {
                guard let m = t.median, let p = t.p95 else { return "-" }
                return String(format: "median %.1f ms, p95 %.1f ms (n=%d)", m, p, t.n)
            }
            return "\(name): \(p.dictations) dictations\n  transcribe  \(f(p.transcribe_ms))\n  clean       \(f(p.clean_ms))"
        }
        try emit(s) { line("today", s.today) + "\n" + line("last 7 days", s.last_7_days) }

    case "days":
        let days = try History().days()
        try emit(days) {
            days.isEmpty ? "no dictations yet" : days.map {
                "\($0.day)  \($0.dictations) dictations  \($0.words) words  \(Int($0.talkS)) s talking  \($0.fixes) fixes  \($0.keptSafe) kept safe"
            }.joined(separator: "\n")
        }

    case "last":
        let d = try History().last()
        if asJSON { print(try JSON.render(d)) } else { print(d.map(describe) ?? "no dictations yet") }

    case "history":
        let rows = try History().all()
        try emit(rows) { rows.isEmpty ? "no dictations in the last 30 days" : rows.map(describe).joined(separator: "\n\n") }

    case "status":
        let model = try SpeechModel.named(config.model)
        let history = try History()
        let rows = try history.all()
        let s = Status(model: model.name, model_present: model.isPresent, model_dir: model.directory.path,
                       model_bytes: model.bytesOnDisk, history: history.path.path, dictations: rows.count,
                       oldest: rows.last?.createdAt, config: Config.file.path, paste: "app: one Cmd+V into a focused text box; CLI: clipboard only")
        try emit(s) {
            """
            model      \(s.model) (\(s.model_present ? "on disk, \(s.model_bytes / 1_000_000) MB" : "missing: run larynx models fetch"))
            history    \(s.history) (\(s.dictations) dictations)
            config     \(s.config)
            paste      \(s.paste)
            """
        }

    case "models":
        guard args.count >= 2, args[1] == "fetch" else { throw CLIError("usage: larynx models fetch [--json]") }
        let model = try SpeechModel.named(config.model)
        let t0 = DispatchTime.now()
        try await model.fetch()
        let f = Fetched(model: model.name, dir: model.directory.path, bytes: model.bytesOnDisk, seconds: seconds(since: t0))
        try emit(f) { "\(f.model): \(f.bytes / 1_000_000) MB in \(f.dir)" }

    case "debug":
        guard args.count >= 2 else { throw CLIError("usage: larynx debug feed <wav> [--raw] | larynx debug state") }
        var req: [String: String] = ["cmd": args[1]]
        if args[1] == "feed" {
            guard args.count >= 3 else { throw CLIError("usage: larynx debug feed <wav> [--raw]") }
            let wav = URL(fileURLWithPath: args[2]).standardizedFileURL
            guard FileManager.default.fileExists(atPath: wav.path) else { throw CLIError("no such file: \(wav.path)") }
            req["wav"] = wav.path
            req["raw"] = args.contains("--raw") ? "true" : "false"
            req["stream"] = args.contains("--stream") ? "true" : "false"   // real-time pace, for the crash test
            req["paste"] = args.contains("--no-paste") ? "false" : "true"  // decide, but never post Cmd+V
            if let app = option("--app", in: args) { req["app"] = app }     // pretend this app is in front (style probes)
        }
        let reply = try DebugChannel.request(try JSONSerialization.data(withJSONObject: req))
        let text = String(decoding: reply, as: UTF8.self)
        if let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], let err = obj["error"] as? String {
            throw CLIError(err)
        }
        print(text)

    case nil, "help", "-h", "--help":
        if asJSON { print(try JSON.render(["usage": usage])) } else { print(usage) }

    default:
        throw CLIError("unknown command \(args[0]); run larynx help")
    }
}

do {
    try await run(Array(args))
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    if asJSON { print(JSON.error(message)) } else { FileHandle.standardError.write(Data("larynx: \(message)\n".utf8)) }
    exit(1)
}
