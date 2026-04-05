import AppKit
import SwiftUI
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarController: MenuBarController!
    var dictationController: DictationController!

    // Apply stored language preference before any UI loads
    func applicationWillFinishLaunching(_ notification: Notification) {
        let lang = AppSettings.loadInterfaceLanguage()
        if lang != "system" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        vfLog("applicationDidFinishLaunching — START")

        // Menu bar app — sem ícone no Dock
        NSApp.setActivationPolicy(.accessory)
        vfLog("Activation policy set to .accessory")

        // MainActor.assumeIsolated necessário porque:
        // - applicationDidFinishLaunching corre no main thread
        // - Mas o compilador Swift 6 não sabe disso (nonisolated context)
        // - DictationController e MenuBarController são @MainActor
        // DictationController tem nonisolated init() para evitar deadlock Swift 6
        dictationController = DictationController()
        vfLog("DictationController created")

        // Setup no main actor context (applicationDidFinishLaunching corre no main thread)
        MainActor.assumeIsolated {
            dictationController.setup()
            vfLog("DictationController setup done")

            menuBarController = MenuBarController(dictationController: dictationController)
            menuBarController.setup()
            vfLog("MenuBarController created and setup")
        }

        // Permissões
        requestMicrophonePermission()
        requestAccessibilityPermission()
        LiveSpeechRecognizer.requestPermission()

        // Onboarding — mostrar apenas na primeira execução
        OnboardingWindowController.shared.showIfNeeded()

        vfLog("applicationDidFinishLaunching — DONE ✅")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationController?.teardown()
    }

    // MARK: - Abrir Definições

    func openSettings() {
        vfLog("openSettings() called")
        SettingsWindowController.shared.show(dictationController: dictationController)
    }

    func openAbout() {
        AboutWindowController.shared.show()
    }

    // MARK: - Permissões

    private func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    DispatchQueue.main.async { self.showMicrophoneAlert() }
                }
            }
        case .denied, .restricted:
            showMicrophoneAlert()
        default:
            break
        }
    }

    private func requestAccessibilityPermission() {
        if AXIsProcessTrusted() {
            vfLog("Accessibility: trusted ✅")
            return
        }

        vfLog("Accessibility: NOT trusted — requesting...")

        // Trigger the system prompt
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)

        // Show explanatory alert
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Accessibility Permission Required")
            alert.informativeText = String(localized: "accessibility.permission.body",
                defaultValue: "Spit needs Accessibility permission to paste text automatically.\n\n1. Open System Settings → Privacy & Security → Accessibility\n2. Toggle Spit ON (remove and re-add if it was already there)\n3. Restart Spit")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Open Settings"))
            alert.addButton(withTitle: String(localized: "Later"))

            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            NSApp.setActivationPolicy(.accessory)
        }
    }

    // Called at app startup to re-check after the user may have granted permission
    func recheckAccessibilityAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if AXIsProcessTrusted() {
                vfLog("Accessibility: now trusted ✅ (re-check)")
            } else {
                vfLog("Accessibility: still NOT trusted after 3s")
            }
        }
    }

    private func showMicrophoneAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Microphone Access Required")
        alert.informativeText = String(localized: "microphone.permission.body",
            defaultValue: "Spit needs microphone access to work. Go to System Settings → Privacy & Security → Microphone.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Open Settings"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }
}
