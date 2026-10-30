import Foundation

/// How a dictation reached the user.
public enum Landed: String, Codable, Sendable {
    case pasted     // typed into the focused text box (next slice)
    case clipboard  // left on the clipboard only
}

/// One dictation: one row in history.db.
public struct Dictation: Codable, Equatable, Sendable {
    public var id: String
    public var createdAt: Date
    public var textRaw: String
    public var textFinal: String
    public var style: String
    public var model: String
    public var cleanup: String
    public var durationS: Double
    public var landed: Landed
    /// Milliseconds spent turning audio into text, and on the rules cleanup. Nil on rows
    /// from before slice 3 and where a step did not run.
    public var transcribeMs: Double?
    public var cleanMs: Double?
    /// The front app's bundle id when it landed: a name only, never a window title. Nil on old rows.
    public var app: String?

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), textRaw: String, textFinal: String? = nil,
                style: String = "plain", model: String, cleanup: String = "none", durationS: Double,
                landed: Landed = .clipboard, transcribeMs: Double? = nil, cleanMs: Double? = nil, app: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.textRaw = textRaw
        self.textFinal = textFinal ?? textRaw
        self.style = style
        self.model = model
        self.cleanup = cleanup
        self.durationS = durationS
        self.landed = landed
        self.transcribeMs = transcribeMs
        self.cleanMs = cleanMs
        self.app = app
    }

    enum CodingKeys: String, CodingKey {
        case id, style, model, cleanup, landed
        case createdAt = "created_at"
        case textRaw = "text_raw"
        case textFinal = "text_final"
        case durationS = "duration_s"
        case transcribeMs = "transcribe_ms"
        case cleanMs = "clean_ms"
        case app
    }

    /// Writes every key, with null for a missing timing, so --json always has the same shape.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(textRaw, forKey: .textRaw)
        try c.encode(textFinal, forKey: .textFinal)
        try c.encode(style, forKey: .style)
        try c.encode(model, forKey: .model)
        try c.encode(cleanup, forKey: .cleanup)
        try c.encode(app, forKey: .app)
        try c.encode(durationS, forKey: .durationS)
        try c.encode(landed, forKey: .landed)
        try c.encode(transcribeMs, forKey: .transcribeMs)
        try c.encode(cleanMs, forKey: .cleanMs)
    }
}
