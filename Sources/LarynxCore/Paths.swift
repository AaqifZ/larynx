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
    /// `LARYNX_CONFIG_DIR` overrides. Else the repo's `local/` folder, if it holds a larynx.toml:
    /// your own settings, which git ignores. Else the defaults that ship in the repo.
    public static var config: URL {
        if let dir = ProcessInfo.processInfo.environment["LARYNX_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let local = defaults.appendingPathComponent("local", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("larynx.toml").path) { return local }
        return defaults
    }

    /// The repo, found from the source path at build time. Its .toml files are the shipped defaults.
    public static var defaults: URL {
        // <repo>/Sources/LarynxCore/Paths.swift -> <repo>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Makes a private folder (0700): dictation text is personal.
    public static func ensurePrivateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
