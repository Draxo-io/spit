import AppKit
import SwiftUI

// MARK: - SettingsWindowController
// Janela de definições gerida via AppKit — compatível com LSUIElement apps.

class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()
    private weak var dictationController: DictationController?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spit — \(String(localized: "Settings"))"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(dictationController: DictationController) {
        vfLog("SettingsWindowController.show() called")
        self.dictationController = dictationController

        window?.contentView = NSHostingView(
            rootView: SettingsView()
                .environmentObject(dictationController)
                .environmentObject(CreditsManager.shared)
                .environmentObject(VocabularyManager.shared)
        )

        // LSUIElement apps precisam de mudar para .regular temporariamente para mostrar janelas
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()

        // Voltar a .accessory quando a janela fechar
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
