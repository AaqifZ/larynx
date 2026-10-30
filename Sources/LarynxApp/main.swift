import AppKit
import LarynxCore

// Larynx: a menu bar app. LSUIElement in Info.plist keeps it out of the Dock;
// .accessory does the same when run unbundled.
#if DEBUG
// Only a debug build honours LARYNX_HOME, LARYNX_CONFIG_DIR and LARYNX_DEBUG. The release app
// holds TCC grants, and any process of this user can set its environment.
Paths.trustsEnvironment = true
#endif

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
