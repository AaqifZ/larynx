import Foundation

/// ~/.larynx/larynx.log: the app's stderr, which the LaunchAgent points at this file.
/// It holds device names and timings, never dictation text.
public enum LogFile {
    public static var url: URL { Paths.home.appendingPathComponent("larynx.log") }

    /// At launch: sets the log to 0600 and, past `maxBytes`, moves it to larynx.log.1 (one old copy)
    /// and points `fd` at a fresh file. Only when `fd` is that file, so a run from a terminal
    /// never moves a log another process writes. Returns true if it rotated.
    @discardableResult
    public static func rotate(maxBytes: Int64 = 5_000_000, fd: Int32 = STDERR_FILENO, at url: URL = LogFile.url) -> Bool {
        var log = stat(), err = stat()
        guard stat(url.path, &log) == 0, fstat(fd, &err) == 0,
              log.st_dev == err.st_dev, log.st_ino == err.st_ino else { return false }
        fchmod(fd, 0o600)
        guard Int64(log.st_size) > maxBytes else { return false }
        let old = url.path + ".1"
        guard rename(url.path, old) == 0 else { return false }
        chmod(old, 0o600)
        let fresh = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fresh >= 0 else { return false }
        dup2(fresh, fd)
        close(fresh)
        return true
    }
}
