import AppKit

/// Anything that can hold text for the user. The real one is the system pasteboard;
/// tests pass a fake so they can see the order of steps.
public protocol Clipboard {
    func write(_ text: String) throws
}

/// Nothing leaves the Mac: the text stays off Universal Clipboard, and the
/// nspasteboard.org markers tell clipboard managers not to keep it. Cmd+V reads `.string`.
public struct SystemClipboard: Clipboard {
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    public static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    let pb: NSPasteboard
    public init(_ pb: NSPasteboard = .general) { self.pb = pb }
    public func write(_ text: String) throws {
        pb.prepareForNewContents(with: .currentHostOnly) // also clears the old contents
        guard pb.setString(text, forType: .string),
              pb.setString("", forType: Self.transient),
              pb.setString("", forType: Self.concealed) else { throw HandOverError.clipboard }
    }
}

public enum HandOverError: Error, CustomStringConvertible {
    case clipboard
    public var description: String { "could not write to the clipboard" }
}

/// Save first, paste second.
/// 1. Save the dictation to history. If this throws, nothing else happens.
/// 2. Put its final text on the clipboard.
/// 3. Return how it landed. Pasting is the next slice, so today it is always `.clipboard`.
@discardableResult
public func handOver(_ dictation: Dictation, history: History, clipboard: Clipboard = SystemClipboard()) throws -> Dictation {
    var d = dictation
    d.landed = .clipboard
    try history.save(d)
    try clipboard.write(d.textFinal)
    return d
}
