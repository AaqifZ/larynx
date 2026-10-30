import Foundation

/// One words.toml entry: how a word is spelled, what the speech model writes instead,
/// and the neighbours that mean "this is the ordinary word, leave it".
public struct WordEntry: Equatable, Sendable, Encodable {
    public var spell: String
    public var soundsLike: [String]
    public var unlessAfter: [String]
    public var unlessBefore: [String]

    public init(spell: String, soundsLike: [String] = [], unlessAfter: [String] = [], unlessBefore: [String] = []) {
        self.spell = spell
        self.soundsLike = soundsLike
        self.unlessAfter = unlessAfter
        self.unlessBefore = unlessBefore
    }

    enum CodingKeys: String, CodingKey {
        case spell
        case soundsLike = "sounds_like"
        case unlessAfter = "unless_after"
        case unlessBefore = "unless_before"
    }
}

/// One style from styles.toml: what happens to the first letter and the final period.
public struct Style: Equatable, Sendable {
    public enum FirstLetter: String, Sendable { case lower, upper, keep }
    public enum FinalPeriod: String, Sendable { case drop, keep, ensure }

    public var name: String
    public var firstLetter: FirstLetter
    public var finalPeriod: FinalPeriod

    public init(name: String, firstLetter: FirstLetter = .keep, finalPeriod: FinalPeriod = .keep) {
        self.name = name
        self.firstLetter = firstLetter
        self.finalPeriod = finalPeriod
    }

    public static let plain = Style(name: "plain")
    public static let mailLike = Style(name: "default", firstLetter: .upper, finalPeriod: .keep)
}

/// Every rule the cleaner needs: the words and the styles by app bundle id.
public struct Rules: Sendable {
    public var words: [WordEntry]
    public var styles: [String: Style]       // by style name
    public var appStyle: [String: String]    // bundle id -> style name
    public var defaultStyle: String

    public init(words: [WordEntry] = [], styles: [String: Style] = [:], appStyle: [String: String] = [:],
                defaultStyle: String = "default") {
        self.words = words
        self.styles = styles
        self.appStyle = appStyle
        self.defaultStyle = defaultStyle
    }

    /// The style for the front app. Bundle id only, never a window title.
    /// An unknown app gets the default style; a missing default is mail-like.
    public func style(forApp bundleID: String?) -> Style {
        if let id = bundleID, let name = appStyle[id.lowercased()], let s = styles[name] { return s }
        if let s = styles[defaultStyle] { return s }
        return Style(name: defaultStyle, firstLetter: .upper, finalPeriod: .keep)
    }

    /// The [[word]] entries. An entry whose spell or sounds_like holds a control character
    /// (a "\n" or "\t" escape) is skipped and passed to `skipped`: the cleaner pastes spell
    /// verbatim, so a newline in it would press Return in the front app.
    public static func parseWords(_ text: String, skipped: ((String) -> Void)? = nil) -> [WordEntry] {
        TOMLDoc.parse(text).arrays["word", default: []].compactMap { t in
            guard let spell = t["spell"]?.string?.trimmingCharacters(in: .whitespaces), !spell.isEmpty else { return nil }
            let sounds = t["sounds_like"]?.list ?? []
            if ([spell] + sounds).contains(where: hasControl) { skipped?(spell); return nil }
            return WordEntry(spell: spell, soundsLike: sounds,
                             unlessAfter: t["unless_after"]?.list ?? [], unlessBefore: t["unless_before"]?.list ?? [])
        }
    }

    static func hasControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    public static func parseStyles(_ text: String) -> (styles: [String: Style], apps: [String: String], defaultStyle: String) {
        let doc = TOMLDoc.parse(text)
        var styles: [String: Style] = [:]
        var apps: [String: String] = [:]
        for (table, values) in doc.tables where table.hasPrefix("style.") {
            let name = String(table.dropFirst("style.".count))
            let first = values["first_letter"]?.string.flatMap(Style.FirstLetter.init(rawValue:)) ?? .keep
            let period = values["final_period"]?.string.flatMap(Style.FinalPeriod.init(rawValue:)) ?? .keep
            styles[name] = Style(name: name, firstLetter: first, finalPeriod: period)
            for app in values["apps"]?.list ?? [] { apps[app.lowercased()] = name }
        }
        return (styles, apps, doc.root["default"]?.string ?? "default")
    }

    public static func parse(words: String, styles: String, skipped: ((String) -> Void)? = nil) -> Rules {
        let s = parseStyles(styles)
        return Rules(words: parseWords(words, skipped: skipped), styles: s.styles, appStyle: s.apps, defaultStyle: s.defaultStyle)
    }
}

/// Holds the rules and re-reads words.toml and styles.toml when their modification time
/// changes. Checked at dictation time with one stat() per file; no timer.
public final class RulesStore {
    public let wordsFile: URL
    public let stylesFile: URL
    private var stamps: [Stamp?] = [nil, nil]
    private var cached: Rules?
    private var cachedCleaner: Cleaner?
    public private(set) var reloads = 0

    struct Stamp: Equatable { let sec: Int; let nsec: Int; let size: Int64 }

    public init(dir: URL = Paths.config) {
        wordsFile = dir.appendingPathComponent("words.toml")
        stylesFile = dir.appendingPathComponent("styles.toml")
    }

    static func stamp(_ url: URL) -> Stamp? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Stamp(sec: st.st_mtimespec.tv_sec, nsec: st.st_mtimespec.tv_nsec, size: Int64(st.st_size))
    }

    /// The current cleaner. Re-reads the files only if one changed since the last call.
    public func cleaner() -> Cleaner {
        let now = [RulesStore.stamp(wordsFile), RulesStore.stamp(stylesFile)]
        if let c = cachedCleaner, now == stamps { return c }
        let w = (try? String(contentsOf: wordsFile, encoding: .utf8)) ?? ""
        let s = (try? String(contentsOf: stylesFile, encoding: .utf8)) ?? ""
        var skipped: [String] = []
        let rules = Rules.parse(words: w, styles: s) { skipped.append($0) }
        if !skipped.isEmpty {
            // %@, not interpolation: a spell may hold a % that NSLog would read as a format.
            NSLog("%@", "larynx: words.toml: skipped \(skipped.count) [[word]] with a control character (newline or tab): \(skipped.debugDescription)")
        }
        let c = Cleaner(rules: rules)
        cached = rules
        cachedCleaner = c
        stamps = now
        reloads += 1
        return c
    }

    public var rules: Rules { _ = cleaner(); return cached ?? Rules() }
}

public struct WordsFileError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// `larynx words add`: appends one [[word]] entry to words.toml.
/// Safe: checks the input, refuses duplicates, writes a temp file and renames it over the
/// old one (never a half-written file), and re-reads the result before it counts.
public func addWord(_ spell: String, soundsLike: [String], to file: URL) throws -> WordEntry {
    let spell = spell.trimmingCharacters(in: .whitespaces)
    let sounds = soundsLike.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let bad: (String) -> Bool = { $0.contains("\n") || $0.contains("\r") || $0.contains("#") }
    guard !spell.isEmpty, !bad(spell), !sounds.contains(where: bad) else {
        throw WordsFileError("the word and its sounds-like must be one line with no #")
    }
    let old = (try? String(contentsOf: file, encoding: .utf8)) ?? "# words.toml: words Larynx must spell your way.\n"
    if Rules.parseWords(old).contains(where: { $0.spell.lowercased() == spell.lowercased() }) {
        throw WordsFileError("\(spell) is already in \(file.lastPathComponent); edit that entry instead")
    }
    var entry = "\n[[word]]\nspell = \(TOMLDoc.quote(spell))\n"
    if !sounds.isEmpty { entry += "sounds_like = [\(sounds.map(TOMLDoc.quote).joined(separator: ", "))]\n" }
    let new = (old.hasSuffix("\n") ? old : old + "\n") + entry
    let added = Rules.parseWords(new).first { $0.spell == spell }
    guard let added, added.soundsLike == sounds, Rules.parseWords(new).count == Rules.parseWords(old).count + 1 else {
        throw WordsFileError("the new entry did not read back; \(file.lastPathComponent) is unchanged")
    }
    let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
    try new.write(to: tmp, atomically: false, encoding: .utf8)
    if rename(tmp.path, file.path) != 0 {
        try? FileManager.default.removeItem(at: tmp)
        throw WordsFileError("could not replace \(file.path)")
    }
    return added
}
