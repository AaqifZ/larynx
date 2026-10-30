import Foundation

/// The fn key, as a pure state machine. The app feeds it key events with
/// timestamps; tests feed it made-up timestamps. It never reads a clock itself.
///
/// - Hold fn: record while held, stop on release.
/// - Tap fn twice (release then press again within `doubleTapGap`): hands-free until the next tap.
/// - Press fn with control once: hands-free until the next fn press.
/// - Tap ⌃⇧ alone (press and release, no other key, mouse click or modifier between): the same
///   hands-free toggle as fn+⌃, for a keyboard with no fn key. It acts on release, so
///   ⌃⇧+key shortcuts never trigger it.
/// - Hold shift with fn: raw path.
/// - fn plus another key in the first second (fn+delete, fn+F1): a shortcut, not a dictation. Cancel.
/// - Esc during any recording: cancel, throw the audio away.
/// - A missed fn release never leaves it stuck: `watch` checks the real key, and
///   `maxHold` / `maxHandsFree` end any recording that runs too long.
public struct KeyMachine: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case start          // begin recording, show the pill
        case stop(raw: Bool) // end recording, transcribe and hand over
        case cancel          // end recording, throw the audio away
    }

    public enum State: Equatable, Sendable {
        case idle
        case holding(downAt: Double)
        case tapPending(deadline: Double) // first short tap done; waiting for the second
        case handsFreeArming              // second tap is down; its release starts hands-free
        case handsFree
        case stopping                     // the stopping tap is down; ignore its release
    }

    public var state: State = .idle
    public private(set) var raw = false
    public let tapMax: Double        // a press shorter than this can be the first of a double tap
    public let doubleTapGap: Double  // max gap between first release and second press
    public let chordWindow: Double   // another key this soon after fn down means a shortcut
    public let maxHold: Double       // a hold this long ends, as if fn came up
    public let maxHandsFree: Double  // a hands-free recording this long ends
    private var startedAt = 0.0
    private var chordDownAt: Double?        // ⌃⇧ is held alone and may become a tap
    private var chordFromFewer = true       // the last flags held only part of ⌃⇧, or nothing
    public private(set) var watchSawFn = false // `watch` acts on fn up only after it has seen fn down itself

    public init(tapMax: Double = 0.35, doubleTapGap: Double = 0.35, chordWindow: Double = 1.0,
                maxHold: Double = 120, maxHandsFree: Double = 600) {
        self.tapMax = tapMax
        self.doubleTapGap = doubleTapGap
        self.chordWindow = chordWindow
        self.maxHold = maxHold
        self.maxHandsFree = maxHandsFree
    }

    public var isRecording: Bool { state != .idle && state != .stopping }

    /// A change of modifier flags. `fn` and `shift` are the states after the change.
    /// `other` is any modifier Larynx does not use (⌘ or ⌥).
    public mutating func flags(fn: Bool, shift: Bool, control: Bool = false, other: Bool = false,
                               at t: Double, wasFn: Bool) -> Action {
        let chord = controlShift(control: control, shift: shift, other: fn || other, at: t)
        if chord != .none { return chord }
        if fn && shift && isRecording { raw = true }
        // control added while fn is held: this press becomes the hands-free toggle
        if fn && control && wasFn, case .holding = state { state = .handsFreeArming; return .none }
        guard fn != wasFn else { return .none }
        return fn ? down(at: t, shift: shift, control: control) : up(at: t)
    }

    public mutating func down(at t: Double, shift: Bool, control: Bool = false) -> Action {
        switch state {
        case .idle:
            raw = shift
            startedAt = t
            watchSawFn = false
            state = control ? .handsFreeArming : .holding(downAt: t)
            return .start
        case .tapPending(let deadline):
            if shift { raw = true }
            if t <= deadline { state = .handsFreeArming; return .none }
            // Late second press: the first recording ends, a new hold begins on the next press.
            state = .idle
            return .stop(raw: raw)
        case .handsFree:
            state = .stopping
            return .stop(raw: raw)
        case .holding, .handsFreeArming, .stopping:
            return .none
        }
    }

    public mutating func up(at t: Double) -> Action {
        switch state {
        case .holding(let downAt):
            if t - downAt < tapMax { state = .tapPending(deadline: t + doubleTapGap); return .none }
            state = .idle
            return .stop(raw: raw)
        case .handsFreeArming:
            state = .handsFree
            return .none
        case .stopping:
            state = .idle
            return .none
        case .idle, .tapPending, .handsFree:
            return .none
        }
    }

    /// ⌃⇧ tapped alone toggles hands-free, as fn+⌃ does. It arms only when ⌃⇧ is reached
    /// by pressing keys (not by letting go of ⌘ or ⌥), and fires on the first release within
    /// `chordWindow`. Any other key, click or modifier in between disarms it.
    private mutating func controlShift(control: Bool, shift: Bool, other: Bool, at t: Double) -> Action {
        let exact = control && shift && !other
        let fewer = !other && !(control && shift)
        defer { chordFromFewer = fewer }
        if exact {
            if chordDownAt == nil && chordFromFewer { chordDownAt = t }
            return .none
        }
        guard let downAt = chordDownAt else { return .none }
        chordDownAt = nil
        guard fewer, t - downAt <= chordWindow else { return .none }
        switch state {
        case .idle:
            raw = false
            startedAt = t
            watchSawFn = false
            state = .handsFree
            return .start
        case .handsFree:
            state = .idle
            return .stop(raw: raw)
        case .holding, .tapPending, .handsFreeArming, .stopping:
            return .none
        }
    }

    /// A mouse click. Only ⌃⇧ cares: ⌃⇧-click is a shortcut, not a tap.
    public mutating func click() { chordDownAt = nil }

    /// Time passing. Ends a lone short tap once the double-tap window closes.
    public mutating func tick(at t: Double) -> Action {
        if case .tapPending(let deadline) = state, t > deadline {
            state = .idle
            return .stop(raw: raw)
        }
        return .none
    }

    /// The real fn state, read from the system while not idle. Catches a release the event tap
    /// missed (the tap was off, or macOS kept the event). Trusts "fn up" only after it has read
    /// "fn down" in this recording, so a system that never reports fn cannot cut a hold short.
    public mutating func watch(fnDown: Bool, at t: Double) -> Action {
        if fnDown { watchSawFn = true }
        switch state {
        case .holding(let downAt):
            if !fnDown && watchSawFn { return up(at: t) }
            if t - downAt > maxHold { state = .idle; return .stop(raw: raw) }
        case .handsFreeArming, .stopping:
            if !fnDown && watchSawFn { return up(at: t) }
        case .handsFree:
            if t - startedAt > maxHandsFree { state = .idle; return .stop(raw: raw) }
        case .idle, .tapPending:
            break
        }
        return .none
    }

    /// Esc: cancels any recording, held or hands-free. Its audio is thrown away.
    public mutating func escape() -> Action {
        chordDownAt = nil
        guard isRecording else { return .none }
        state = .idle
        return .cancel
    }

    /// Any non-modifier key down.
    public mutating func otherKey(at t: Double) -> Action {
        chordDownAt = nil
        switch state {
        case .holding(let downAt) where t - downAt < chordWindow:
            state = .idle
            return .cancel
        case .tapPending:
            state = .idle
            return .cancel
        default:
            return .none
        }
    }
}
