import AppKit
import SwiftUI
import AVFoundation
import UserNotifications
import Sparkle

class AppDelegate: NSObject, NSApplicationDelegate {

    var menuBarController: MenuBarController!
    var dictationController: DictationController!
    // Sparkle updater — mantido como propriedade para evitar que o ARC o liberte.
    private(set) var updaterController: SPUStandardUpdaterController!

    // Mantido como propriedade para evitar que o ARC liberte a fonte de eventos.
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // Apply stored language preference before any UI loads
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Guard: impede múltiplas instâncias mesmo quando lançadas de paths diferentes
        // (ex: DerivedData vs /Applications). LSMultipleInstancesProhibited no Info.plist
        // cobre o caso do Finder, mas não do open(1) ou Xcode.
        //
        // Usa o PRÓPRIO bundle ID (não hardcoded): a build de dev (app.getspit.dev)
        // e a de produção (app.getspit) são apps distintas e coexistem — cada uma só
        // termina outras cópias de SI MESMA, nunca a outra build.
        let ownBundleID = Bundle.main.bundleIdentifier ?? "app.getspit"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: ownBundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            vfLog("Outra instância já em execução — a terminar esta.")
            NSApp.terminate(nil)
            return
        }

        let lang = AppSettings.loadInterfaceLanguage()
        if lang != "system" {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
            UserDefaults.standard.synchronize()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        vfLog("applicationDidFinishLaunching — START")

        // Watchdog in-process: capta exceções/sinais E deteta morte silenciosa da
        // sessão anterior (que o .ips do sistema não vê, sobretudo SIGKILL/kernel).
        // Instalar O MAIS CEDO POSSÍVEL para apanhar problemas no resto do setup.
        MainActor.assumeIsolated { CrashWatchdog.shared.install() }

        // LaunchAgent: pede ao launchd para relançar a app em caso de crash ou
        // saída anormal (NÃO relança em ⌘Q / NSApp.terminate). Idempotente.
        // Só em Release: a build de dev NÃO se auto-relança — matar deve mantê-la
        // morta durante o desenvolvimento, e evita conflito de label no launchd.
        #if !DEBUG
        MainActor.assumeIsolated { LaunchAgentManager.shared.register() }
        #endif

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

        // Permissões — só pedir se o onboarding já foi concluído.
        // Durante o onboarding, cada passo pede a sua própria permissão no momento
        // certo (microfone no passo 1, acessibilidade no passo 2).
        let onboardingDone = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if onboardingDone {
            requestMicrophonePermission()
            requestAccessibilityPermission()
            LiveSpeechRecognizer.requestPermission()
        }

        // Onboarding — mostrar no primeiro lançamento
        Task { @MainActor in
            let onboardingDone = UserDefaults.standard.bool(forKey: "onboardingCompleted")
            if !onboardingDone {
                OnboardingWindowController.shared.showIfNeeded()
            }
        }

        // MLX TTS — NÃO carrega no startup. Carrega lazily quando o utilizador usa TTS
        // pela primeira vez. Evita os 1.7 GB de footprint constante que causavam Jetsam.

        // Sparkle — apenas em Release; builds de debug não têm appcast publicado.
        #if !DEBUG
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif

        // Gestão de memória: descarregar modelos em pressão ou antes de dormir,
        // para evitar que o kernel (Jetsam) nos mate silenciosamente com SIGKILL.
        setupMemoryPressureHandler()
        setupSleepObservers()

        vfLog("applicationDidFinishLaunching — DONE ✅")
        logMemoryFootprint(context: "launch")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Força re-check imediato de AX quando a app volta ao foreground
        // (ex.: utilizador regressou das Definições após conceder a permissão).
        dictationController?.recheckAccessibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Marcar saída limpa para o próximo arranque não confundir com crash.
        MainActor.assumeIsolated { CrashWatchdog.shared.markGraceful() }
        dictationController?.teardown()
    }

    // MARK: - Deep link handler

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "spit" else { continue }
            vfLog("AppDelegate — deep link desconhecido: \(url)")
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

    // MARK: - Gestão de Memória

    private func setupMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let source = self?.memoryPressureSource else { return }
            let isCritical = source.data.contains(.critical)
            let level = isCritical ? "critical" : "warning"
            self?.logMemoryFootprint(context: "pressure-\(level)")
            // "warning" dispara com frequência em sistemas sob uso normal (múltiplas
            // vezes por hora nalgumas máquinas) — reagir a isso descarregando o Whisper
            // (466 MB, usado a cada ditado) causa reloads frequentes e perceptíveis.
            // Só o TTS (1.7 GB, o maior consumidor) descarrega em "warning"; o Whisper
            // só descarrega em "critical" (evento raro, risco real de Jetsam).
            vfLog("[Memory] pressão \(level) — a descarregar TTS\(isCritical ? " + Whisper" : "")")
            Task { @MainActor in
                MLXTTSService.shared.enterStandby()
                if isCritical {
                    await LocalWhisperService.shared.unload()
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func setupSleepObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Ecrã bloqueado (Lock Screen / proteção de ecrã)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
    }

    @objc private func systemWillSleep() {
        logMemoryFootprint(context: "pre-sleep")
        vfLog("[Memory] sistema vai dormir — a descarregar modelos para libertar RAM")
        Task { @MainActor in
            MLXTTSService.shared.enterStandby()
            await LocalWhisperService.shared.unload()
        }
    }

    @objc private func systemDidWake() {
        vfLog("[Memory] sistema acordou — modelos serão recarregados na próxima utilização")
        logMemoryFootprint(context: "post-wake")
    }

    @objc private func screenDidLock() {
        logMemoryFootprint(context: "screen-locked")
        vfLog("[Memory] ecrã bloqueado — a descarregar modelo TTS")
        Task { @MainActor in MLXTTSService.shared.enterStandby() }
    }

    private func logMemoryFootprint(context: String) {
        // phys_footprint é a métrica que o Jetsam usa — inclui memória ANE/GPU/unified.
        // resident_size subestima muito (ex: WhisperKit no ANE não aparece no RSS).
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let mb = Double(info.phys_footprint) / 1_048_576
            vfLog("[Memory] footprint (\(context)): \(String(format: "%.0f", mb)) MB phys")
        }
    }

    // MARK: - Updates

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
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
