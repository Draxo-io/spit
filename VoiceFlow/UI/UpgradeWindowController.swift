import AppKit
import SwiftUI

// UpgradeWindowController stub — open-source v2.0.
// App is free; this window is kept as a no-op so call sites compile.

final class UpgradeWindowController: NSWindowController {

    static let shared = UpgradeWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spit"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        // No-op — app is free, no paywall needed.
    }
}
