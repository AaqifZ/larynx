import AppKit

/// Anything that can hold text for the user. The real one is the system pasteboard;
/// tests pass a fake so they can see the order of steps.
public protocol Clipboard {
    func write(_ text: String) throws
}

public struct SystemClipboard: Clipboard {
    public init() {}
    public func write(_ text: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { throw HandOverError.clipboard }
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
