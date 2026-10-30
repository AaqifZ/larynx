import Foundation

/// One encoder for every `--json` output, so all commands print the same shapes.
public enum JSON {
    public static func render<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso(date))
        }
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    /// Local time with offset, e.g. 2026-10-11T14:03:22+01:00.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// For errors under `--json`: still valid JSON.
    public static func error(_ message: String) -> String {
        (try? render(["error": message])) ?? "{\"error\": \"unknown\"}"
    }
}
