import Foundation

/// Where Larynx keeps its files. `LARYNX_HOME` moves everything (tests use a temp dir).
public enum Paths {
    /// Whether `LARYNX_HOME` and `LARYNX_CONFIG_DIR` count. Off by default: the release app holds
    /// TCC grants, and any process of this user can set its environment (`launchctl setenv`).
    /// The CLI, the self-test and the debug build of the app turn it on at startup.
    nonisolated(unsafe) public static var trustsEnvironment = false

    static func override(_ name: String) -> URL? {
        guard trustsEnvironment, let dir = ProcessInfo.processInfo.environment[name], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    public static var home: URL {
        if let dir = override("LARYNX_HOME") { return dir }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".larynx", isDirectory: true)
    }

    public static var historyDB: URL { home.appendingPathComponent("history.db") }
    public static var models: URL { home.appendingPathComponent("models", isDirectory: true) }

    /// The folder that holds larynx.toml, words.toml and styles.toml.
    /// `LARYNX_CONFIG_DIR` overrides when trusted. Else the repo's `local/` folder, if it holds a larynx.toml:
    /// your own settings, which git ignores. Else ~/.larynx (`home`), never the clone itself,
    /// so a `git pull` cannot change what Larynx pastes. See `seedConfig`.
    public static var config: URL {
        if let dir = override("LARYNX_CONFIG_DIR") { return dir }
        let local = repo.appendingPathComponent("local", isDirectory: true)
        if FileManager.default.fileExists(atPath: local.appendingPathComponent("larynx.toml").path) { return local }
        seedConfig(into: home)
        return home
    }

    public static let configFiles = ["larynx.toml", "words.toml", "styles.toml"]

    /// Copies each shipped default the folder is missing, once. A file already there is yours
    /// and is never replaced, so later changes to the repo's defaults do not reach it.
    public static func seedConfig(into dir: URL, from source: URL = defaults) {
        let fm = FileManager.default
        try? ensurePrivateDir(dir)
        for name in configFiles {
            let to = dir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: to.path) else { continue }
            let from = source.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) { try? fm.copyItem(at: from, to: to) }
        }
    }

    /// The shipped defaults: Larynx.app's Resources when this runs from the app bundle
    /// (the app, or the larynx tool inside it), else the repo's .toml files.
    public static var defaults: URL {
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            // Larynx.app/Contents/{MacOS,Helpers}/<exe> -> Larynx.app/Contents/Resources
            let res = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
            if FileManager.default.fileExists(atPath: res.appendingPathComponent("larynx.toml").path) { return res }
        }
        return repo
    }

    /// The repo, found from the source path at build time.
    static var repo: URL {
        // <repo>/Sources/LarynxCore/Paths.swift -> <repo>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The larynx tool inside Larynx.app, when the app runs from its bundle.
    public static var bundledTool: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let tool = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/larynx")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    /// Makes a private folder (0700): dictation text is personal.
    /// A folder that already exists is set to 0700 too, whatever made it.
    public static func ensurePrivateDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
