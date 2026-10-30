import AppKit
import ApplicationServices
import LarynxCore

/// Asks Accessibility which element has keyboard focus. Reads roles and flags only,
/// never titles or text. Needs Accessibility.
struct AXFocusProbe: FocusProbe {
    func focused() -> FocusInfo? {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        if let el = element(system, kAXFocusedUIElementAttribute) {
            let first = info(el, app)
            if first.isTextInput { return first }
        }
        // Electron apps (Claude, Slack) build their tree only when asked: ask, wait a moment, look again.
        guard let pid = front?.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        usleep(80_000)
        if let el = element(appEl, kAXFocusedUIElementAttribute) ?? element(system, kAXFocusedUIElementAttribute) {
            return info(el, app)
        }
        return FocusInfo(role: nil, app: app)
    }

    private func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private func info(_ el: AXUIElement, _ app: String?) -> FocusInfo {
        var settable = DarwinBoolean(false)
        let settableOK = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success
        var editable: CFTypeRef?
        var isEditable = false
        if AXUIElementCopyAttributeValue(el, "AXEditable" as CFString, &editable) == .success, let b = editable as? Bool { isEditable = b }
        if !isEditable, element(el, "AXEditableAncestor") != nil { isEditable = true }
        return FocusInfo(role: string(el, kAXRoleAttribute), subrole: string(el, kAXSubroleAttribute),
                         valueSettable: settableOK && settable.boolValue, editable: isEditable, app: app)
    }
}

/// Posts exactly one Cmd+V, and nothing else, ever. Needs Accessibility.
struct CGPaster: Paster {
    func pasteOnce() throws {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else {
            throw SpeechFailure("could not make the paste key event")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own prompts once. The owner allows them in System Settings.
    static func ask() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
    }
}
