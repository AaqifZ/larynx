import Foundation

/// How loud a recording was, from its 16 kHz samples in 100 ms windows.
/// `loudDB` is the third-loudest window: the loud syllables of speech, but not one click.
/// A dead mic (transmitter off, muted, wrong format) stays near its noise floor the whole time.
public struct Loudness: Sendable {
    public static let window = 1_600 // 100 ms at 16 kHz
    private var windows: [Float] = [] // RMS of each full window
    private var sum: Float = 0
    private var count = 0
    public private(set) var peak: Float = 0

    public init() {}

    public mutating func add(_ chunk: [Float]) {
        for s in chunk {
            let a = abs(s)
            if a > peak { peak = a }
            sum += s * s
            count += 1
            if count == Loudness.window {
                windows.append((sum / Float(count)).squareRoot())
                sum = 0
                count = 0
            }
        }
    }

    public static func db(_ x: Float) -> Double { x > 0 ? 20 * log10(Double(x)) : -120 }

    public var peakDB: Double { Loudness.db(peak) }

    /// The third-loudest window, in dBFS: any speech gives far more than 300 ms of loud windows,
    /// while one or two clicks do not count, however long the recording. -120 with no full window yet.
    public var loudDB: Double {
        guard !windows.isEmpty else { return -120 }
        let sorted = windows.sorted(by: >)
        return Loudness.db(sorted[min(2, sorted.count - 1)])
    }

    /// True when no part of the recording rose above `threshold` dBFS.
    /// Recordings under 0.5 s are never called silent (too little to judge).
    public func isSilent(below threshold: Double) -> Bool {
        windows.count >= 5 && loudDB < threshold
    }
}

/// Recordings judged silent, kept in ~/.larynx/silent/ (newest 20, none older than the
/// history's 30 days) so a wrong threshold loses nothing:
/// `larynx transcribe ~/.larynx/silent/<id>.caf` gets the words back.
public enum Silent {
    public static var dir: URL { Paths.home.appendingPathComponent("silent", isDirectory: true) }

    public static func keep(_ file: URL, limit: Int = 20, now: Date = Date()) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return }
        try? Paths.ensurePrivateDir(dir)
        let dest = dir.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: dest)
        if (try? fm.moveItem(at: file, to: dest)) == nil { try? fm.removeItem(at: file) }
        prune(limit: limit, now: now)
    }

    /// Deletes all but the newest `limit` recordings, and any older than `days`. Also run at launch,
    /// so audio never outlives its text when no new silent recording comes along.
    public static func prune(limit: Int = 20, now: Date = Date(), days: Int = History.retentionDays) {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let created: (URL) -> Date = { (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        let kept = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .sorted { created($0) > created($1) }
        for (i, f) in kept.enumerated() where i >= limit || created(f) < cutoff { try? fm.removeItem(at: f) }
    }
}
