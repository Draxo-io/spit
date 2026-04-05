import AppKit
import SwiftUI

// MARK: - OnboardingWindowController
// Janela de onboarding — mostrada na primeira execução.

class OnboardingWindowController: NSWindowController {

    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Spit"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showIfNeeded() {
        let completed = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        guard !completed else { return }
        show()
    }

    func show() {
        window?.contentView = NSHostingView(
            rootView: OnboardingView()
                .environmentObject(CreditsManager.shared)
        )
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    func close() {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}
