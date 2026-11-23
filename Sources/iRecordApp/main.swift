import AppKit
import iRecordCore

@MainActor
private enum AppBootstrap {
    // NSApplication.delegate is a weak reference; keep the delegate alive for
    // the entire lifetime of the process.
    static let delegate = AppDelegate()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = AppBootstrap.delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
