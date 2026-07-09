import AppKit
import SwiftUI

// MARK: - OnboardingWindowController
// Janela de onboarding — mostrada na primeira execução.

class OnboardingWindowController: NSWindowController {

    static let shared = OnboardingWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "onboarding.window.title", defaultValue: "Welcome to Spit")
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showIfNeeded() {
        let completed = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        vfLog("[Onboarding] showIfNeeded — completed=\(completed)")
        guard !completed else {
            vfLog("[Onboarding] já completado, a saltar")
            return
        }
        show()
    }

    func show() {
        vfLog("[Onboarding] show() — a configurar janela")
        let dc = (NSApp.delegate as? AppDelegate)?.dictationController ?? DictationController()
        window?.contentView = NSHostingView(
            rootView: OnboardingView()
                .environmentObject(CreditsManager.shared)
                .environmentObject(dc)
        )
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        vfLog("[Onboarding] janela apresentada — frame=\(window?.frame ?? .zero) visible=\(window?.isVisible ?? false)")
    }

    override func close() {
        window?.close()
        NSApp.setActivationPolicy(.accessory)
    }
}
