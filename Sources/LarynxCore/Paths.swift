import Foundation

/// Where Larynx keeps its files. `LARYNX_HOME` moves everything (tests use a temp dir).
public enum Paths {
    public static var home: URL {
        if let dir = ProcessInfo.processInfo.environment["LARYNX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".larynx", isDirectory: true)
    }

    public static var historyDB: URL { home.appendingPathComponent("history.db") }
    public static var models: URL { home.appendingPathComponent("models", isDirectory: true) }

    /// The folder that holds larynx.toml, words.toml and styles.toml.
    /// `LARYNX_CONFIG_DIR` overrides; otherwise it is this repo, found from the source path at build time.
    public static var config: URL {
        if let dir = ProcessInfo.processInfo.environment["LARYNX_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        // <repo>/Sources/LarynxCore/Paths.swift -> <repo>
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Makes a private folder (0700): dictation text is personal.
    public static func ensurePrivateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
