import Foundation
import SQLite3

/// history.db: one table of dictations, kept for 30 days.
public final class History {
    public static let retentionDays = 30

    public enum Failure: Error, CustomStringConvertible {
        case sqlite(String)
        public var description: String { if case let .sqlite(m) = self { return m }; return "" }
    }

    public let path: URL
    private var db: OpaquePointer?

    /// Opens (and creates) the store, then drops rows past retention.
    public init(path: URL = Paths.historyDB, now: Date = Date()) throws {
        self.path = path
        try Paths.ensurePrivateDir(path.deletingLastPathComponent())
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure.sqlite(message)
        }
        chmod(path.path, 0o600)
        sqlite3_busy_timeout(db, 2000)
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS dictations(
              id TEXT PRIMARY KEY,
              created_at REAL NOT NULL,
              text_raw TEXT NOT NULL,
              text_final TEXT NOT NULL,
              style TEXT NOT NULL,
              model TEXT NOT NULL,
              cleanup TEXT NOT NULL,
              duration_s REAL NOT NULL,
              landed TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dictations_created ON dictations(created_at);
            CREATE TABLE IF NOT EXISTS daily(
              day TEXT PRIMARY KEY,
              dictations INTEGER NOT NULL,
              words INTEGER NOT NULL,
              talk_s REAL NOT NULL,
              fixes INTEGER NOT NULL,
              kept_safe INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS daily_apps(
              day TEXT NOT NULL,
              app TEXT NOT NULL,
              dictations INTEGER NOT NULL,
              words INTEGER NOT NULL,
              PRIMARY KEY(day, app)
            );
            """)
        try migrate()
        try backfill()
        try prune(now: now)
    }

    deinit { sqlite3_close(db) }

    /// Timings came later. Old files get the columns with ALTER TABLE; old rows stay null.
    private func migrate() throws {
        var have: Set<String> = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(dictations)", -1, &stmt, nil) == SQLITE_OK else { throw Failure.sqlite(message) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) { have.insert(String(cString: name)) }
        }
        sqlite3_finalize(stmt)
        for col in ["transcribe_ms", "clean_ms"] where !have.contains(col) {
            try exec("ALTER TABLE dictations ADD COLUMN \(col) REAL")
        }
        // The dashboard: app name, word count and fixes per row (no new text is kept).
        for (col, type) in [("app", "TEXT"), ("words", "INTEGER"), ("fixes", "INTEGER")] where !have.contains(col) {
            try exec("ALTER TABLE dictations ADD COLUMN \(col) \(type)")
        }
    }

    // MARK: daily totals (the dashboard). Numbers only, never text, and never pruned,
    // so totals outlast the 30-day history.

    /// Words in a text: runs of letters or digits.
    public static func words(_ s: String) -> Int {
        s.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }).count
    }

    /// Words the cleanup removed or changed (fillers out, names fixed), ignoring case and punctuation.
    public static func fixes(raw: String, final: String) -> Int {
        func toks(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }).map(String.init)
        }
        var left: [String: Int] = [:]
        for t in toks(final) { left[t, default: 0] += 1 }
        var changed = 0
        for t in toks(raw) {
            if let n = left[t], n > 0 { left[t] = n - 1 } else { changed += 1 }
        }
        return changed
    }

    /// Fills words and fixes on rows from before the dashboard, then rebuilds every day still in history.
    private func backfill() throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, text_raw, text_final FROM dictations WHERE words IS NULL", -1, &stmt, nil) == SQLITE_OK
        else { throw Failure.sqlite(message) }
        var todo: [(String, Int, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ c: Int32) -> String { sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "" }
            let final = text(2)
            todo.append((text(0), History.words(final), History.fixes(raw: text(1), final: final)))
        }
        sqlite3_finalize(stmt)
        for (id, w, f) in todo {
            try run("UPDATE dictations SET words = ?, fixes = ? WHERE id = ?", [.int(w), .int(f), .text(id)])
        }
        try exec("BEGIN")
        try exec("""
            INSERT OR REPLACE INTO daily(day, dictations, words, talk_s, fixes, kept_safe)
            SELECT date(created_at, 'unixepoch', 'localtime'), COUNT(*), COALESCE(SUM(words), 0), COALESCE(SUM(duration_s), 0),
                   COALESCE(SUM(fixes), 0), SUM(landed = 'clipboard')
            FROM dictations WHERE text_final != '' GROUP BY 1;
            DELETE FROM daily_apps WHERE day IN (SELECT DISTINCT date(created_at, 'unixepoch', 'localtime') FROM dictations);
            INSERT INTO daily_apps(day, app, dictations, words)
            SELECT date(created_at, 'unixepoch', 'localtime'), COALESCE(app, 'unknown'), COUNT(*), COALESCE(SUM(words), 0)
            FROM dictations WHERE text_final != '' GROUP BY 1, 2;
            """)
        try exec("COMMIT")
    }

    /// Recomputes one day's totals from its rows. Called after every save and landed change.
    private func refresh(day createdAt: Double) throws {
        let day = "date(\(createdAt), 'unixepoch', 'localtime')"
        try exec("""
            INSERT OR REPLACE INTO daily(day, dictations, words, talk_s, fixes, kept_safe)
            SELECT date(created_at, 'unixepoch', 'localtime'), COUNT(*), COALESCE(SUM(words), 0), COALESCE(SUM(duration_s), 0),
                   COALESCE(SUM(fixes), 0), SUM(landed = 'clipboard')
            FROM dictations WHERE text_final != '' AND date(created_at, 'unixepoch', 'localtime') = \(day) GROUP BY 1;
            DELETE FROM daily_apps WHERE day = \(day);
            INSERT INTO daily_apps(day, app, dictations, words)
            SELECT date(created_at, 'unixepoch', 'localtime'), COALESCE(app, 'unknown'), COUNT(*), COALESCE(SUM(words), 0)
            FROM dictations WHERE text_final != '' AND date(created_at, 'unixepoch', 'localtime') = \(day) GROUP BY 1, 2;
            """)
    }

    private enum Bind { case int(Int), text(String) }
    private func run(_ sql: String, _ binds: [Bind]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.sqlite(message) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            switch b {
            case let .int(v): sqlite3_bind_int64(stmt, Int32(i + 1), sqlite3_int64(v))
            case let .text(v): sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient)
            }
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(message) }
    }

    /// One row of daily totals, oldest first.
    public struct Day: Codable, Equatable, Sendable {
        public let day: String, dictations: Int, words: Int, talkS: Double, fixes: Int, keptSafe: Int
        enum CodingKeys: String, CodingKey { case day, dictations, words, fixes; case talkS = "talk_s"; case keptSafe = "kept_safe" }
    }

    public func days() throws -> [Day] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT day, dictations, words, talk_s, fixes, kept_safe FROM daily ORDER BY day", -1, &stmt, nil) == SQLITE_OK
        else { throw Failure.sqlite(message) }
        defer { sqlite3_finalize(stmt) }
        var out: [Day] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Day(day: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                           dictations: Int(sqlite3_column_int64(stmt, 1)), words: Int(sqlite3_column_int64(stmt, 2)),
                           talkS: sqlite3_column_double(stmt, 3), fixes: Int(sqlite3_column_int64(stmt, 4)),
                           keptSafe: Int(sqlite3_column_int64(stmt, 5))))
        }
        return out
    }

    private var message: String { db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open history.db" }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.sqlite(message) }
    }

    /// Writes one dictation. Returns only after SQLite has committed it.
    public func save(_ d: Dictation) throws {
        var stmt: OpaquePointer?
        let sql = """
            INSERT OR REPLACE INTO dictations(id, created_at, text_raw, text_final, style, model, cleanup, duration_s, landed,
              transcribe_ms, clean_ms, app, words, fixes)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.sqlite(message) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func text(_ i: Int32, _ s: String) { sqlite3_bind_text(stmt, i, s, -1, transient) }
        text(1, d.id)
        sqlite3_bind_double(stmt, 2, d.createdAt.timeIntervalSince1970)
        text(3, d.textRaw)
        text(4, d.textFinal)
        text(5, d.style)
        text(6, d.model)
        text(7, d.cleanup)
        sqlite3_bind_double(stmt, 8, d.durationS)
        text(9, d.landed.rawValue)
        func real(_ i: Int32, _ v: Double?) { if let v { sqlite3_bind_double(stmt, i, v) } else { sqlite3_bind_null(stmt, i) } }
        real(10, d.transcribeMs)
        real(11, d.cleanMs)
        if let app = d.app { text(12, app) } else { sqlite3_bind_null(stmt, 12) }
        sqlite3_bind_int64(stmt, 13, sqlite3_int64(History.words(d.textFinal)))
        sqlite3_bind_int64(stmt, 14, sqlite3_int64(d.cleanup == "none" ? 0 : History.fixes(raw: d.textRaw, final: d.textFinal)))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(message) }
        try refresh(day: d.createdAt.timeIntervalSince1970)
    }

    /// Records how a saved dictation landed (used once pasting exists).
    public func setLanded(id: String, _ landed: Landed) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE dictations SET landed = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.sqlite(message)
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, landed.rawValue, -1, transient)
        sqlite3_bind_text(stmt, 2, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw Failure.sqlite(message) }
        if let d = try select("WHERE id = '\(id.replacingOccurrences(of: "'", with: "''"))'").first {
            try refresh(day: d.createdAt.timeIntervalSince1970)
        }
    }

    /// Deletes rows older than the retention window. Returns how many went.
    @discardableResult
    public func prune(now: Date = Date(), days: Int = History.retentionDays) throws -> Int {
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        try exec("DELETE FROM dictations WHERE created_at < \(cutoff)")
        return Int(sqlite3_changes(db))
    }

    public func last() throws -> Dictation? {
        try select("ORDER BY created_at DESC, rowid DESC LIMIT 1").first
    }

    /// The newest `limit` rows, newest first.
    public func recent(_ limit: Int) throws -> [Dictation] {
        try select("ORDER BY created_at DESC, rowid DESC LIMIT \(max(0, limit))")
    }

    /// Newest first.
    public func all() throws -> [Dictation] {
        try select("ORDER BY created_at DESC, rowid DESC")
    }

    /// Rows created at or after `date`, newest first.
    public func since(_ date: Date) throws -> [Dictation] {
        try select("WHERE created_at >= \(date.timeIntervalSince1970) ORDER BY created_at DESC, rowid DESC")
    }

    public func count() throws -> Int {
        try all().count
    }

    private func select(_ tail: String) throws -> [Dictation] {
        var stmt: OpaquePointer?
        let sql = "SELECT id, created_at, text_raw, text_final, style, model, cleanup, duration_s, landed, transcribe_ms, clean_ms, app FROM dictations " + tail
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.sqlite(message) }
        defer { sqlite3_finalize(stmt) }
        func text(_ c: Int32) -> String { sqlite3_column_text(stmt, c).map { String(cString: $0) } ?? "" }
        func real(_ c: Int32) -> Double? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, c) }
        var rows: [Dictation] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.sqlite(message) }
            rows.append(Dictation(
                id: text(0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                textRaw: text(2), textFinal: text(3), style: text(4), model: text(5), cleanup: text(6),
                durationS: sqlite3_column_double(stmt, 7),
                landed: Landed(rawValue: text(8)) ?? .clipboard,
                transcribeMs: real(9), cleanMs: real(10),
                app: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : text(11)))
        }
        return rows
    }
}
