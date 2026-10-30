import AppKit
import CoreGraphics

/// A listen-only event tap: sees fn (maskSecondaryFn) and ⌃⇧ on flagsChanged, and other keys
/// and mouse clicks only to spot shortcuts. It never changes or blocks an event, and never posts one.
/// Needs Input Monitoring.
final class KeyTap {
    enum Event {
        case flags(fn: Bool, shift: Bool, control: Bool, other: Bool, wasFn: Bool)
        case otherKey
        case click
        case escape
    }

    private var tap: CFMachPort?
    private var fnDown = false
    private let onEvent: (Event) -> Void

    init(onEvent: @escaping (Event) -> Void) { self.onEvent = onEvent }

    static var hasAccess: Bool { CGPreflightListenEventAccess() }

    /// Returns false when Input Monitoring is not allowed (the tap cannot be created).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            let me = Unmanaged<KeyTap>.fromOpaque(info!).takeUnretainedValue()
            me.handle(type, event)
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let fn = event.flags.contains(.maskSecondaryFn)
            let shift = event.flags.contains(.maskShift)
            let control = event.flags.contains(.maskControl)
            let other = !event.flags.isDisjoint(with: [.maskCommand, .maskAlternate])
            let was = fnDown
            fnDown = fn
            onEvent(.flags(fn: fn, shift: shift, control: control, other: other, wasFn: was))
        case .keyDown:
            onEvent(event.getIntegerValueField(.keyboardEventKeycode) == 53 ? .escape : .otherKey) // 53 = Esc
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onEvent(.click)
        default:
            break
        }
    }
}
