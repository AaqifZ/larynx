import AppKit

// Larynx: a menu bar app. LSUIElement in Info.plist keeps it out of the Dock;
// .accessory does the same when run unbundled.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
