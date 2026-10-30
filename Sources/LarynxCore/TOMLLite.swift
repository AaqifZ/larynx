import Foundation

/// A small TOML reader for words.toml and styles.toml. It knows:
/// `# comments`, `[table]`, `[[array of tables]]`, `key = "string"`, `key = ["a", "b"]`
/// (one line or several), `key = true/false`, `key = 12`. Nothing else; unknown lines are skipped.
public enum TOMLValue: Equatable, Sendable {
    case string(String)
    case list([String])
    case bool(Bool)
    case number(Double)

    public var string: String? { if case let .string(s) = self { return s }; return nil }
    public var list: [String]? {
        switch self {
        case let .list(l): return l
        case let .string(s): return [s]
        default: return nil
        }
    }
    public var bool: Bool? { if case let .bool(b) = self { return b }; return nil }
}

public struct TOMLDoc: Sendable {
    public var root: [String: TOMLValue] = [:]
    /// `[style.chat]` -> tables["style.chat"]
    public var tables: [String: [String: TOMLValue]] = [:]
    /// `[[word]]` -> arrays["word"], in file order
    public var arrays: [String: [[String: TOMLValue]]] = [:]

    public static func parse(_ text: String) -> TOMLDoc {
        var doc = TOMLDoc()
        enum Target { case root, table(String), array(String) }
        var target = Target.root
        var pending = ""  // a multi-line array being collected

        func assign(_ line: String) {
            guard let eq = line.firstIndex(of: "=") else { return }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = TOMLDoc.value(raw) else { return }
            switch target {
            case .root: doc.root[key] = value
            case let .table(name): doc.tables[name, default: [:]][key] = value
            case let .array(name):
                if var list = doc.arrays[name], !list.isEmpty {
                    list[list.count - 1][key] = value
                    doc.arrays[name] = list
                }
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if !pending.isEmpty {
                pending += " " + line
                if bracketsBalanced(pending) { assign(pending); pending = "" }
                continue
            }
            if line.isEmpty { continue }
            if line.hasPrefix("[[") && line.hasSuffix("]]") {
                let name = String(line.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespaces)
                doc.arrays[name, default: []].append([:])
                target = .array(name)
            } else if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                doc.tables[name, default: [:]] = doc.tables[name] ?? [:]
                target = .table(name)
            } else if line.contains("=") {
                if bracketsBalanced(line) { assign(line) } else { pending = line }
            }
        }
        if !pending.isEmpty { assign(pending + "]") }
        return doc
    }

    /// Drops a `#` comment that is outside any string.
    static func stripComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (i, c) in line.enumerated() {
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle() }
            if c == "#" && !inString { return String(line.prefix(i)) }
        }
        return line
    }

    static func bracketsBalanced(_ s: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for c in s {
            if escaped { escaped = false; continue }
            if c == "\\" && inString { escaped = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
        }
        return depth <= 0
    }

    static func value(_ raw: String) -> TOMLValue? {
        if raw.hasPrefix("\"") { return readString(Substring(raw)).map { .string($0.0) } }
        if raw.hasPrefix("[") {
            var items: [String] = []
            var rest = Substring(raw.dropFirst())
            while true {
                rest = rest.drop { $0 == " " || $0 == "," || $0 == "\t" }
                guard let first = rest.first, first != "]" else { break }
                guard first == "\"", let (s, after) = readString(rest) else { return nil }
                items.append(s)
                rest = after
            }
            return .list(items)
        }
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let n = Double(raw) { return .number(n) }
        return nil
    }

    /// Reads one "..." string with \" and \\ escapes. Returns it and the text after it.
    static func readString(_ s: Substring) -> (String, Substring)? {
        guard s.first == "\"" else { return nil }
        var out = ""
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let n = s.index(after: i)
                guard n < s.endIndex else { return nil }
                switch s[n] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(s[n])
                }
                i = s.index(after: n)
                continue
            }
            if c == "\"" { return (out, s[s.index(after: i)...]) }
            out.append(c)
            i = s.index(after: i)
        }
        return nil
    }

    /// Writes a string as a TOML "..." literal.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
