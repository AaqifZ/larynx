import Foundation

/// What the Accessibility API says about the focused element. The app fills it in;
/// tests build it by hand. Only roles and flags: never titles or contents.
public struct FocusInfo: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var valueSettable: Bool
    public var editable: Bool // AXEditable true, or the element sits inside an editable web area
    public var app: String?   // the front app's bundle id; never a window title

    public init(role: String?, subrole: String? = nil, valueSettable: Bool = false, editable: Bool = false, app: String? = nil) {
        self.role = role
        self.subrole = subrole
        self.valueSettable = valueSettable
        self.editable = editable
        self.app = app
    }

    public static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Controls whose AXValue can be set but which are not text.
    public static let nonTextRoles: Set<String> = [
        "AXSlider", "AXCheckBox", "AXRadioButton", "AXIncrementor", "AXScrollBar", "AXPopUpButton",
        "AXColorWell", "AXDisclosureTriangle", "AXSplitter", "AXValueIndicator", "AXLevelIndicator",
        "AXMenuButton", "AXButton", "AXStepper",
        "AXList", "AXScrollArea", "AXOutline", "AXTable", "AXImage", "AXMenu", "AXMenuBar", "AXMenuItem",
    ]

    /// Apps where an unknown focus means "no text box" (the desktop and file windows).
    public static let noTextApps: Set<String> = ["com.apple.finder"]

    /// The paste decision: paste only into a text input.
    public var isTextInput: Bool {
        guard let role else { return false }
        if FocusInfo.textRoles.contains(role) { return true }
        if FocusInfo.nonTextRoles.contains(role) { return false }
        return editable || valueSettable
    }

    /// The paste decision. Paste unless we are sure there is no text box: the text is
    /// already saved and on the clipboard, so a paste into nothing costs nothing.
    /// Electron apps (Claude, Slack) often answer slowly or with a vague role; those paste.
    public static func shouldPaste(_ info: FocusInfo?) -> Bool {
        guard let info else { return true }
        if info.isTextInput { return true }
        if let role = info.role, nonTextRoles.contains(role) { return false }
        if let app = info.app, noTextApps.contains(app) { return false }
        return true
    }
}

/// Answers "is a text box focused?" right now.
public protocol FocusProbe {
    func focused() -> FocusInfo?
}

/// Posts exactly one Cmd+V.
public protocol Paster {
    func pasteOnce() throws
}

/// For the CLI and tests: nothing is ever focused, nothing is ever pasted.
public struct NoFocus: FocusProbe {
    public init() {}
    public func focused() -> FocusInfo? { nil }
}

/// What the pill says after a hand over.
public enum PillText {
    public static let listening = "listening…"
    public static let clipboard = "No text box. On your clipboard, ⌘V to paste."
    public static let clipboardSeconds = 4.0
    public static let pasted = "Pasted · also on your clipboard"
    public static let nothing = "Heard nothing"
    public static func silent(_ mic: String) -> String { "Mic is silent (\(mic)). Nothing pasted." }
    public static func failed(_ why: String) -> String { "Kept your audio; retry on next launch (\(why))" }

    public static func result(_ landed: Landed) -> String { landed == .pasted ? pasted : clipboard }
}

/// Save first, paste second, with the paste step.
/// 1. Save to history (landed = clipboard). If this throws, nothing else happens.
/// 2. `onSaved`: the text is safe, so the inflight audio can go.
/// 3. Put the text on the clipboard, always.
/// 4. If a text input is focused, post one Cmd+V and record landed = pasted.
@discardableResult
public func deliver(_ dictation: Dictation, history: History, clipboard: Clipboard, focus: FocusProbe,
                    paster: Paster?, onSaved: () -> Void = {}) throws -> Dictation {
    var d = dictation
    d.landed = .clipboard
    try history.save(d)
    onSaved()
    try clipboard.write(d.textFinal)
    if let paster, FocusInfo.shouldPaste(focus.focused()) {
        try paster.pasteOnce()
        d.landed = .pasted
        try history.setLanded(id: d.id, .pasted)
    }
    return d
}
