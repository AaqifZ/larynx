import Foundation

/// Notices a stuck main thread. The main thread calls `beat` every second; a background
/// check asks `stuck`. Times are system uptime, which stops while the Mac sleeps, so a long
/// sleep never reads as a freeze. Pure, so the self-test drives it with made-up times.
public final class Watchdog: @unchecked Sendable {
    public let limit: TimeInterval
    private let lock = NSLock()
    private var last: TimeInterval

    public init(limit: TimeInterval = 10, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.limit = limit
        last = now
    }

    public func beat(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); last = now; lock.unlock()
    }

    /// Seconds since the last beat, when that is over the limit. Nil while the main thread answers.
    public func stuck(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let gap = now - last
        return gap > limit ? gap : nil
    }
}
