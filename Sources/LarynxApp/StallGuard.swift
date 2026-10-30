import Foundation
import LarynxCore

/// Ends Larynx when its main thread stops answering for 10 s. launchd starts it again
/// (KeepAlive: a failed exit), and the launch recovers the inflight recording. On 25 Oct a mic
/// drop froze the main thread while it opened the mic: no crash, so nothing restarted it.
@MainActor
enum StallGuard {
    private static var check: DispatchSourceTimer?

    static func start(_ dog: Watchdog = Watchdog()) {
        guard check == nil else { return }
        // .common, so beats go on while a menu is open.
        let beat = Timer(timeInterval: 1, repeats: true) { _ in dog.beat() }
        RunLoop.main.add(beat, forMode: .common)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            guard let gap = dog.stuck() else { return }
            NSLog("larynx: main thread stuck %.0f s; sampling, then exiting so launchd starts Larynx again", gap)
            // What the main thread was doing, for the next fix. Takes about 2 s.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let file = Paths.home.appendingPathComponent("hang-\(stamp).txt").path
            let sample = Process()
            sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            sample.arguments = ["\(getpid())", "2", "-file", file]
            sample.standardOutput = FileHandle.nullDevice
            sample.standardError = FileHandle.nullDevice
            try? sample.run()
            sample.waitUntilExit()
            _exit(1)
        }
        timer.resume()
        check = timer
    }
}
