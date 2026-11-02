import Foundation

/// Reads larynx.log and answers one question: after each thing that went wrong, did the next
/// recording land? A cleared error or a live process is not recovery. Only a landed recording is.
/// The log holds device names and timings, never dictation text. Pure, so the self-test feeds it lines.
public struct RecoveryReport: Encodable, Equatable, Sendable {
    public struct Row: Encodable, Equatable, Sendable {
        public let kind: String
        public var total = 0
        public var recovered = 0
        public var failed = 0
        public var waiting = 0
        public var last_failed: String?
    }

    public var rows: [Row]
    public var ok: Bool { rows.allSatisfy { $0.failed == 0 } }

    enum CodingKeys: String, CodingKey { case rows, ok }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rows, forKey: .rows)
        try c.encode(ok, forKey: .ok)
    }

    static let kinds = ["restart", "hang", "mic-error", "error", "silent", "sleep", "screen-lock", "mic-change"]
    static let marks = ["main thread stuck": "hang", "mic closed (sleep)": "sleep",
                        "mic closed (screen locked)": "screen-lock", "mic closed (mic changed)": "mic-change"]

    /// `since` drops older lines ("2026-11-01"). `cancelled` and `empty` recordings say nothing
    /// about recovery: the user stopped, or no words were spoken, so the event stays open.
    public static func parse(_ log: String, since: String = "") -> RecoveryReport {
        var rows = Dictionary(uniqueKeysWithValues: kinds.map { ($0, Row(kind: $0)) })
        var open: [String] = []
        var pid: Substring?
        func raise(_ kind: String) { rows[kind]?.total += 1; open.append(kind) }

        for line in log.split(separator: "\n") {
            guard let name = line.range(of: " Larynx["), line.prefix(10) >= since else { continue }
            let this = line[name.upperBound...].prefix { $0.isNumber }
            if let pid, pid != this { raise("restart") }
            pid = this
            for (mark, kind) in marks where line.contains(mark) { raise(kind) }
            guard line.contains("larynx: outcome "), let r = line.range(of: "result=") else { continue }
            let result = String(line[r.upperBound...].prefix { $0.isLetter || $0 == "-" })
            if result == "cancelled" || result == "empty" { continue }
            let landed = result == "pasted" || result == "clipboard"
            for kind in open {
                if landed { rows[kind]?.recovered += 1 } else {
                    rows[kind]?.failed += 1
                    rows[kind]?.last_failed = String(line.prefix(19))
                }
            }
            open = []
            if !landed { raise(result) }
        }
        for kind in open { rows[kind]?.waiting += 1 }
        return RecoveryReport(rows: kinds.compactMap { rows[$0] })
    }

    /// The old log first, then the current one.
    public static func read(since: String = "") -> RecoveryReport {
        let old = URL(fileURLWithPath: LogFile.url.path + ".1")
        let text = [old, LogFile.url].map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined(separator: "\n")
        return parse(text, since: since)
    }
}
