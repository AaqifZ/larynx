import Foundation

/// The default cleanup: rules only, no language model. Deterministic and pure.
/// 1. Fillers out (um, uh, uhm, erm, er, hmm, mm) and stutters ("the the"). "like" and
///    "you know" stay: they carry meaning. Spacing, punctuation and capitals are repaired.
/// 2. words.toml: sound-alikes become your spelling, whole words only, longest match first,
///    unless a guard word says it is the ordinary word ("the cat clawed the sofa").
/// 3. The style: the first letter and the final period, per styles.toml.
/// URLs and file paths are never touched. Numbers and your words always survive.
public struct Cleaner: Sendable {
    public let rules: Rules
    private let index: [String: [Form]]   // first token -> forms, longest first
    private let properNouns: Set<String>  // spellings, for "keep the capital" in chat style

    struct Form: Sendable { let tokens: [String]; let entry: Int }

    public init(rules: Rules) {
        self.rules = rules
        var index: [String: [Form]] = [:]
        var nouns: Set<String> = []
        for (i, w) in rules.words.enumerated() {
            nouns.insert(w.spell)
            if let first = w.spell.split(separator: " ").first { nouns.insert(String(first)) }
            var seen: Set<[String]> = []
            for form in [w.spell] + w.soundsLike {
                let tokens = form.lowercased().split(separator: " ").map(String.init)
                guard let head = tokens.first, seen.insert(tokens).inserted else { continue }
                index[head, default: []].append(Form(tokens: tokens, entry: i))
            }
        }
        for k in index.keys { index[k]!.sort { $0.tokens.count > $1.tokens.count } }
        self.index = index
        self.properNouns = nouns
    }

    public struct Cleaned: Sendable, Encodable {
        public let text: String
        public let style: String
    }

    /// Cleans for the front app (bundle id only).
    public func clean(_ raw: String, app: String?) -> Cleaned {
        let style = rules.style(forApp: app)
        return Cleaned(text: clean(raw, style: style), style: style.name)
    }

    public func clean(_ raw: String, style: Style) -> String {
        var chunks = Cleaner.chunks(raw)
        chunks = Cleaner.dropFillers(chunks)
        chunks = fixWords(chunks)
        applyStyle(&chunks, style)
        return chunks.map(\.text).joined(separator: " ")
    }

    // MARK: chunks

    struct Chunk {
        var lead: String
        var core: String
        var trail: String
        var protected: Bool   // a URL, path, email, file name or dotted thing: never touched
        var proper = false    // a words.toml spelling
        let lower: String     // core, lowercased once (capitals change, letters do not)
        init(lead: String, core: String, trail: String, protected: Bool, lower: String? = nil) {
            self.lead = lead; self.core = core; self.trail = trail; self.protected = protected
            self.lower = lower ?? core.lowercased()
        }
        var text: String { lead + core + trail }
        var endsSentence: Bool { trail.contains { $0 == "." || $0 == "?" || $0 == "!" } }
        var isNumber: Bool { core.first?.isNumber ?? false }
    }

    static let trailing: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "\"", "'", "”", "’", "…"]

    static func chunks(_ text: String) -> [Chunk] {
        text.split(whereSeparator: { $0.isWhitespace }).map { piece in
            let s = String(piece)
            let lead = s.prefix { !($0.isLetter || $0.isNumber) }
            var rest = s.dropFirst(lead.count)
            var trailCount = 0
            for c in rest.reversed() { if trailing.contains(c) { trailCount += 1 } else { break } }
            let trail = rest.suffix(trailCount)
            rest = rest.dropLast(trailCount)
            let core = String(rest)
            let protected = s.contains("://") || s.contains { "/\\@_=<>{}|~".contains($0) }
                || core.contains(".") || core.contains(":")
            return Chunk(lead: String(lead), core: core, trail: String(trail), protected: protected)
        }
    }

    // MARK: 1. fillers and stutters

    /// um, umm, uh, uhh, uhm, erm, er, hm, hmm, mm, mmm.
    static func isFillerWord(_ w: String) -> Bool {
        let s = Array(w.unicodeScalars)
        guard let first = s.first, s.count >= 2, s.count <= 6 else { return false }
        func rest(from i: Int, _ allowed: Set<Unicode.Scalar>) -> Bool { s[i...].allSatisfy { allowed.contains($0) } }
        switch first {
        case "u":
            // u + m+  |  u + h+ + m*
            if s[1] == "m" { return rest(from: 1, ["m"]) }
            if s[1] == "h" {
                guard let firstM = s.firstIndex(of: "m") else { return rest(from: 1, ["h"]) }
                return rest(from: 1, ["h", "m"]) && s[firstM...].allSatisfy { $0 == "m" }
            }
            return false
        case "e": return w == "er" || w == "erm" || w == "ermm"
        case "h": return s[1] == "m" && rest(from: 1, ["m"])
        case "m": return rest(from: 1, ["m"])
        default: return false
        }
    }

    /// Words repeated by a stumble ("the the"). Words that are often doubled on purpose
    /// ("that that", "had had", "no no", "very very") are not here.
    static let stutters: Set<String> = [
        "the", "a", "an", "i", "to", "of", "and", "in", "it", "we", "you", "he", "she", "they", "for", "on",
        "with", "my", "this", "but", "at", "or", "if", "our", "your", "their", "its", "me", "us", "from", "i'm",
    ]

    /// Words whose comma stays when a filler after them goes ("Yes, um, I agree").
    static let interjections: Set<String> = [
        "yes", "yeah", "yep", "no", "nope", "okay", "ok", "so", "well", "hey", "hi", "oh", "right", "sure", "thanks", "alright",
    ]

    static func dropFillers(_ input: [Chunk]) -> [Chunk] {
        var out: [Chunk] = []
        out.reserveCapacity(input.count)
        var capNext = false
        var carryLead = ""
        for var c in input {
            let atStart = out.last.map { $0.endsSentence } ?? true
            let lower = c.lower
            if !c.protected, isFillerWord(lower), !(lower.hasPrefix("m") && out.last?.isNumber == true) {
                if atStart && (c.core.first?.isUppercase ?? false) { capNext = true }
                // Keep the sentence end the filler carried: "it works um." -> "it works."
                if let end = c.trail.last(where: { $0 == "." || $0 == "?" || $0 == "!" }), !out.isEmpty {
                    if !out[out.count - 1].endsSentence {
                        while let l = out[out.count - 1].trail.last, l == "," || l == ";" || l == ":" {
                            out[out.count - 1].trail.removeLast()
                        }
                        out[out.count - 1].trail.append(end)
                    }
                }
                // "I think, um, we" -> "I think we"; but "Yes, um, I agree" -> "Yes, I agree".
                if c.trail == ",", let last = out.last, last.trail == ",", !interjections.contains(last.lower) {
                    out[out.count - 1].trail = ""
                }
                if !c.trail.contains(where: { ")]\"”’'".contains($0) }) { carryLead += c.lead }
                continue
            }
            if !c.protected, let last = out.last, !last.protected, last.lower == lower, stutters.contains(lower),
               last.trail.isEmpty || last.trail == "," {
                out.removeLast()
                let lastAtStart = out.last.map { $0.endsSentence } ?? true
                if lastAtStart && (last.core.first?.isUppercase ?? false) { capNext = true }
                c.lead = last.lead + c.lead
            }
            if capNext {
                c.core = capitalizedFirst(c.core)
                capNext = false
            }
            if !carryLead.isEmpty { c.lead = carryLead + c.lead; carryLead = "" }
            out.append(c)
        }
        // A comma left hanging at the very end by a removed filler.
        if let l = out.last?.trail.last, l == "," || l == ";" { out[out.count - 1].trail.removeLast() }
        return out
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first, f.isLowercase else { return s }
        return f.uppercased() + s.dropFirst()
    }

    static func lowercasedFirst(_ s: String) -> String {
        guard let f = s.first, f.isUppercase else { return s }
        return f.lowercased() + s.dropFirst()
    }

    // MARK: 2. words.toml

    /// "clawed's" -> ("clawed", "'s")
    static func possessive(_ lower: String) -> (stem: String, suffix: String) {
        for p in ["'s", "’s"] where lower.hasSuffix(p) && lower.count > p.count {
            return (String(lower.dropLast(p.count)), p)
        }
        return (lower, "")
    }

    func fixWords(_ input: [Chunk]) -> [Chunk] {
        guard !index.isEmpty else { return input }
        var out: [Chunk] = []
        out.reserveCapacity(input.count)
        var i = 0
        let lowers = input.map(\.lower)
        while i < input.count {
            let c = input[i]
            if !c.protected, let (form, suffix) = match(input, lowers, at: i, prev: out.last) {
                let n = form.tokens.count
                let spell = rules.words[form.entry].spell
                var r = Chunk(lead: c.lead, core: spell + suffix, trail: input[i + n - 1].trail, protected: false,
                              lower: rules.words[form.entry].spell.lowercased() + suffix.lowercased())
                r.proper = true
                out.append(r)
                i += n
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private func match(_ cs: [Chunk], _ lowers: [String], at i: Int, prev: Chunk?) -> (Form, String)? {
        let head = lowers[i]
        let headStem = Cleaner.possessive(head)
        var candidates = index[head] ?? []
        if !headStem.suffix.isEmpty { candidates += index[headStem.stem] ?? [] }
        guard !candidates.isEmpty else { return nil }
        for form in candidates {
            let n = form.tokens.count
            guard i + n <= cs.count else { continue }
            var ok = true
            var suffix = ""
            for k in 0..<n {
                let c = cs[i + k]
                if k > 0 && (c.protected || !c.lead.isEmpty || !cs[i + k - 1].trail.isEmpty) { ok = false; break }
                if k == n - 1 {
                    let p = Cleaner.possessive(lowers[i + k])
                    if lowers[i + k] == form.tokens[k] { suffix = "" }
                    else if p.stem == form.tokens[k] && !p.suffix.isEmpty {
                        suffix = String(c.core.suffix(p.suffix.count))
                    } else { ok = false }
                } else if lowers[i + k] != form.tokens[k] { ok = false }
                if !ok { break }
            }
            guard ok else { continue }
            let w = rules.words[form.entry]
            if let p = prev, !p.endsSentence, w.unlessAfter.contains(where: { $0.lowercased() == p.lower }) { continue }
            let last = cs[i + n - 1]
            if i + n < cs.count, last.trail.isEmpty,
               w.unlessBefore.contains(where: { $0.lowercased() == lowers[i + n] }) { continue }
            return (form, suffix)
        }
        return nil
    }

    // MARK: 3. style

    static let questionWords: Set<String> = ["is", "are", "am", "was", "were", "do", "does", "did", "can", "could", "would",
        "will", "should", "shall", "have", "has", "what", "why", "how", "when", "where", "who", "which", "whose", "isn't", "aren't",
        "don't", "doesn't", "didn't", "can't", "won't", "shouldn't", "wouldn't", "couldn't"]
    static let firstPerson: Set<String> = ["I", "I'm", "I'll", "I've", "I'd", "I’m", "I’ll", "I’ve", "I’d"]

    func applyStyle(_ cs: inout [Chunk], _ style: Style) {
        if let i = cs.firstIndex(where: { $0.core.first?.isLetter ?? false }), !cs[i].protected {
            let core = cs[i].core
            switch style.firstLetter {
            case .lower:
                let keep = cs[i].proper || Cleaner.firstPerson.contains(core)
                    || properNouns.contains(core) || core.filter(\.isUppercase).count >= 2
                if !keep { cs[i].core = Cleaner.lowercasedFirst(core) }
            case .upper: cs[i].core = Cleaner.capitalizedFirst(core)
            case .keep: break
            }
        }
        if style.firstLetter == .upper {
            // Proper sentence case: every sentence starts with a capital, and "i" is "I".
            for j in cs.indices where !cs[j].protected && (cs[j].core.first?.isLetter ?? false) {
                let lower = cs[j].core.lowercased()
                if ["i", "i'm", "i'll", "i've", "i'd", "i’m", "i’ll", "i’ve", "i’d"].contains(lower) {
                    cs[j].core = Cleaner.capitalizedFirst(cs[j].core)
                } else if j > 0, cs[j - 1].endsSentence {
                    cs[j].core = Cleaner.capitalizedFirst(cs[j].core)
                }
            }
        }
        if style.finalPeriod == .ensure, let last = cs.indices.last, !cs[last].protected,
           cs[last].core.last.map({ $0.isLetter || $0.isNumber }) ?? false,
           !cs[last].trail.contains(where: { ".?!…:;".contains($0) }) {
            // A last sentence that opens like a question gets "?", not "." ("is it ready" -> "Is it ready?").
            var start = last
            while start > 0, !cs[start - 1].endsSentence { start -= 1 }
            cs[last].trail += Cleaner.questionWords.contains(cs[start].core.lowercased()) ? "?" : "."
        }
        if style.finalPeriod == .drop, let last = cs.indices.last {
            let t = cs[last].trail
            if t.hasSuffix(".") && !t.hasSuffix("..") { cs[last].trail.removeLast() }
        }
    }
}
