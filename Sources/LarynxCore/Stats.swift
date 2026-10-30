import Foundation

/// `larynx stats`: how long transcription and cleanup take, from history.
public struct TimingStats: Encodable, Equatable, Sendable {
    public let n: Int
    public let median: Double?
    public let p95: Double?

    /// Median (mean of the middle two for an even count) and nearest-rank p95.
    public init(_ values: [Double]) {
        let v = values.sorted()
        n = v.count
        guard !v.isEmpty else { median = nil; p95 = nil; return }
        let mid = v.count / 2
        median = v.count % 2 == 1 ? v[mid] : (v[mid - 1] + v[mid]) / 2
        p95 = v[max(0, Int((0.95 * Double(v.count)).rounded(.up)) - 1)]
    }
}

public struct PeriodStats: Encodable, Equatable, Sendable {
    public let dictations: Int
    public let transcribe_ms: TimingStats
    public let clean_ms: TimingStats

    public init(_ rows: [Dictation]) {
        dictations = rows.count
        transcribe_ms = TimingStats(rows.compactMap(\.transcribeMs))
        clean_ms = TimingStats(rows.compactMap(\.cleanMs))
    }
}

public struct Stats: Encodable, Equatable, Sendable {
    public let today: PeriodStats
    public let last_7_days: PeriodStats

    public init(_ rows: [Dictation], now: Date = Date(), calendar: Calendar = .current) {
        let startToday = calendar.startOfDay(for: now)
        let start7 = calendar.date(byAdding: .day, value: -6, to: startToday) ?? startToday
        today = PeriodStats(rows.filter { $0.createdAt >= startToday })
        last_7_days = PeriodStats(rows.filter { $0.createdAt >= start7 })
    }
}
