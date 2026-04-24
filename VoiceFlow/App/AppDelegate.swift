import AppKit
import SwiftUI
import AVFoundation
import UserNotifications

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

        // Crash reporting — detect .ips files from previous crashes and ship to back-office
        CrashReporter.shared.checkAndReport()

        // Telemetry — ping de primeiro lançamento (device info anónimo)
        TelemetryService.shared.pingIfNeeded()

        // Onboarding — mostrar apenas na primeira execução
        OnboardingWindowController.shared.showIfNeeded()

        // Update checker — verifica actualizações 5s após launch, depois cada 24h
        UpdateChecker.shared.startChecking()

        vfLog("applicationDidFinishLaunching — DONE ✅")
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictationController?.teardown()
    }

    // MARK: - URL Scheme: spit://activate?token=xxx  |  spit://auth?jwt=xxx

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "spit",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { continue }

            if url.host == "activate",
               let token = components.queryItems?.first(where: { $0.name == "token" })?.value {
                vfLog("Deep link activation — token: \(token.prefix(8))…")
                Task { @MainActor in
                    await handleActivation(token: token)
                }
            } else if url.host == "auth",
                      let jwt = components.queryItems?.first(where: { $0.name == "jwt" })?.value {
                vfLog("Deep link auth — JWT received (\(jwt.count) chars)")
                Task { await AuthManager.shared.handleDeepLink(jwt: jwt) }
            }
        }
    }


    @MainActor
    private func handleActivation(token: String) async {
        sendNotification(title: "Spit", body: String(localized: "Activating license…"))

        do {
            try await LicenseManager.shared.activate(token: token)
            sendNotification(title: "Spit", body: String(localized: "License activated! Enjoy Spit."))
            vfLog("License activated successfully ✅")
        } catch {
            sendNotification(title: String(localized: "Activation failed"), body: error.localizedDescription)
            vfLog("Activation error: \(error.localizedDescription)")
        }
    }

    private func sendNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
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

        // Trigger the macOS system permission prompt (shows the system dialog directly).
        // We intentionally do NOT change NSApp.setActivationPolicy here — switching to
        // .regular and back to .accessory destroys the NSStatusItem on macOS 13+, leaving
        // the app running but invisible. The system prompt is explanation enough; a
        // UNUserNotification provides the extra context without the side-effect.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)

        // Secondary notification with extra instructions (non-modal, no activation policy change)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.sendNotification(
                title: String(localized: "Accessibility Permission Required"),
                body: String(localized: "accessibility.permission.body",
                    defaultValue: "Spit needs Accessibility to paste text automatically. Open System Settings → Privacy & Security → Accessibility and toggle Spit ON.")
            )
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
