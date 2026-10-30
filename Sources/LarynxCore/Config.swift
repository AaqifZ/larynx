import Foundation

/// larynx.toml, read with a tiny reader: `key = "value"` or `key = number` lines, `#` comments.
/// Enough for flat settings; words.toml and styles.toml get a real reader when they are wired up.
public struct Config: Sendable {
    public var values: [String: String]

    public static let defaults: [String: String] = [
        "key": "fn", "raw_key": "fn+shift", "model": "parakeet-v3", "clean_deadline_s": "2",
        "max_hold_s": "120", "max_handsfree_s": "600",
    ]

    public init(values: [String: String] = Config.defaults) { self.values = values }

    public static var file: URL { Paths.config.appendingPathComponent("larynx.toml") }

    /// Reads larynx.toml over the defaults. A missing file means defaults.
    public static func load(from url: URL = Config.file) -> Config {
        var c = Config()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return c }
        for (k, v) in parse(text) { c.values[k] = v }
        return c
    }

    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if let hash = line.firstIndex(of: "#"), !line[..<hash].contains("\"") { line = String(line[..<hash]) }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[0].hasPrefix("[") else { continue }
            var v = parts[1]
            if v.hasPrefix("\""), let end = v.dropFirst().firstIndex(of: "\"") { v = String(v[v.index(after: v.startIndex)..<end]) }
            out[parts[0]] = v
        }
        return out
    }

    public var model: String { values["model"] ?? "parakeet-v3" }
    /// Microphones to try, in order, by part of their name. The first one plugged in wins;
    /// none plugged in means the macOS default input.
    public var mics: [String] {
        (values["mic"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    public var maxHold: Double { values["max_hold_s"].flatMap(Double.init) ?? 120 }
    public var maxHandsFree: Double { values["max_handsfree_s"].flatMap(Double.init) ?? 600 }
    /// A recording whose loud parts stay under this (dBFS) is a silent mic: no paste.
    /// Minutes the mic stays open after a dictation, so the next one keeps its first word. 0 = close at once.
    public var warmMicMinutes: Double { values["warm_mic_minutes"].flatMap(Double.init) ?? 5 }
    public var silentBelowDB: Double { values["silent_below_db"].flatMap(Double.init) ?? -40 }
}
