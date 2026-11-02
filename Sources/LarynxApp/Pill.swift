import AppKit

/// The pill. While you talk: a small capsule with only the moving level meter, no text.
/// After a paste: a quick check, then gone.
/// Only when words need saying (no text box, errors) does it widen to one line of text.
/// A borderless, non-activating panel that ignores the mouse, so it never takes focus.
final class Pill {
    static let small = NSSize(width: 64, height: 26)
    static let wide = NSSize(width: 360, height: 34)

    private let panel: NSPanel
    private let bar = NSView()
    private let label = NSTextField(labelWithString: "")
    private let meter = Meter()
    private var hideWork: DispatchWorkItem?
    private var meterTimer: Timer?
    private var widthC: NSLayoutConstraint!
    private var heightC: NSLayoutConstraint!
    private var meterCenter: NSLayoutConstraint!
    private var meterLeading: NSLayoutConstraint!
    private var labelCenter: NSLayoutConstraint!
    private var labelSides: [NSLayoutConstraint] = []
    var levelSource: (() -> Float)?
    var quiet = false

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Pill.small),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.97).cgColor
        bar.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        bar.layer?.borderWidth = 1

        label.textColor = NSColor(white: 0.95, alpha: 1)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        label.maximumNumberOfLines = 1
        label.alignment = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for v in [meter, label] { v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v) }
        widthC = bar.widthAnchor.constraint(equalToConstant: Pill.small.width)
        heightC = bar.heightAnchor.constraint(equalToConstant: Pill.small.height)
        meterCenter = meter.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        meterLeading = meter.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14)
        labelCenter = label.centerXAnchor.constraint(equalTo: bar.centerXAnchor)
        labelSides = [label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
                      label.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14)]
        NSLayoutConstraint.activate([
            widthC, heightC, meterCenter,
            meter.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: 26),
            meter.heightAnchor.constraint(equalToConstant: 14),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        panel.contentView = bar
    }

    private func layout(_ size: NSSize, meterOn: Bool, text: String?) {
        widthC.constant = size.width
        heightC.constant = size.height
        bar.layer?.cornerRadius = size.height / 2
        meter.isHidden = !meterOn
        label.isHidden = text == nil
        label.stringValue = text ?? ""
        NSLayoutConstraint.deactivate([meterLeading, labelCenter] + labelSides)
        meterCenter.isActive = true
        if text != nil { NSLayoutConstraint.activate(labelSides) }
        panel.setContentSize(size)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 28))
    }

    /// Shows without activating Larynx or taking key focus.
    private func front() { if !quiet { panel.orderFrontRegardless() } }

    /// Recording: the small capsule, meter only. The text argument is ignored on purpose.
    func listening(_ text: String = "") {
        hideWork?.cancel()
        layout(Pill.small, meterOn: true, text: nil)
        front()
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.meter.push(self.levelSource?() ?? 0)
        }
    }

    /// Live words are no longer shown.
    func words(_ text: String) {}

    /// Pasted: a quick green check in the small capsule, then gone.
    func done() {
        meterTimer?.invalidate()
        layout(Pill.small, meterOn: false, text: "✓")
        label.textColor = NSColor(red: 0.45, green: 0.85, blue: 0.65, alpha: 1)
        front()
        hide(after: 0.15) // a blink, not a pause
    }

    /// Words that must be said (no text box, errors): the wide bar, for `seconds`.
    func show(_ text: String, for seconds: Double) {
        meterTimer?.invalidate()
        label.textColor = NSColor(white: 0.95, alpha: 1)
        layout(Pill.wide, meterOn: false, text: text)
        front()
        hide(after: seconds)
    }

    private func hide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        meterTimer?.invalidate()
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
    var text: String { label.isHidden ? "" : label.stringValue }
}

/// Five bars that follow the mic level.
final class Meter: NSView {
    private var levels = [Float](repeating: 0, count: 5)
    func push(_ l: Float) { levels.removeFirst(); levels.append(l); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(red: 0.45, green: 0.85, blue: 0.65, alpha: 1).setFill()
        let w: CGFloat = 4, gap = (bounds.width - w * 5) / 4
        for (i, l) in levels.enumerated() {
            let h = max(3, bounds.height * CGFloat(l))
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        }
    }
}
