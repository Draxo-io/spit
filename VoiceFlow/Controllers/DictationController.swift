import Foundation
import AppKit
import Combine

// MARK: - DictationController
// Orquestra todo o fluxo de ditação:
// idle → recording → processing → injecting → review → idle

@MainActor
class DictationController: ObservableObject {

    // MARK: - Estado Publicado

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastResult: DictationResult?
    @Published private(set) var audioLevel: Float = -60.0  // dB

    // MARK: - Dependências

    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var focusDetector: FocusDetector!
    private var textInjector: TextInjector!
    var vocabularyManager: VocabularyManager!
    var creditsManager: CreditsManager!

    private var hotkeyManager: HotkeyManager!
    private var liveSpeechRecognizer: LiveSpeechRecognizer!
    private var dictationTask: Task<Void, Never>?

    /// Last language detected by Whisper (e.g. "pt", "en") — used for live preview on next recording.
    /// Only populated when settings.language == "auto".
    private var lastDetectedLanguage: String?

    // MARK: - Init

    nonisolated init() {
        vfLog("DictationController.init() — created (nonisolated)")
    }

    /// Chamar depois de init, já dentro do MainActor context
    func setup() {
        vfLog("DictationController.setup() — START")
        audioRecorder = AudioRecorder()
        vfLog("  - AudioRecorder OK")
        whisperService = WhisperService()
        vfLog("  - WhisperService OK")
        focusDetector = FocusDetector()
        vfLog("  - FocusDetector OK")
        textInjector = TextInjector()
        vfLog("  - TextInjector OK")
        vocabularyManager = VocabularyManager.shared
        vfLog("  - VocabularyManager OK")
        creditsManager = CreditsManager.shared
        vfLog("  - CreditsManager OK")
        hotkeyManager = HotkeyManager()
        vfLog("  - HotkeyManager OK")
        liveSpeechRecognizer = LiveSpeechRecognizer()
        vfLog("  - LiveSpeechRecognizer OK")
        setupAudioRecorder()
        vfLog("DictationController.setup() — audioRecorder setup done")
        setupHotkey()
        vfLog("DictationController.setup() — DONE ✅")
    }

    func teardown() {
        hotkeyManager.unregister()
        hotkeyManager.unregisterPTT()
        audioRecorder.stopRecording()
    }

    // MARK: - Setup

    private func setupHotkey() {
        let settings = loadSettings()
        hotkeyManager.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        hotkeyManager.onHotkeyPressed = { [weak self] in
            vfLog("onHotkeyPressed callback fired!")
            Task { @MainActor in
                self?.handleHotkeyPressed()
            }
        }
        vfLog("Hotkey setup — keyCode:\(settings.hotkeyKeyCode) modifiers:\(settings.hotkeyModifiers)")

        if settings.pttEnabled {
            setupPTT(keyCode: settings.pttKeyCode, modifiers: settings.pttModifiers)
        }
    }

    private func setupPTT(keyCode: UInt32, modifiers: UInt32) {
        hotkeyManager.registerPTT(keyCode: keyCode, modifiers: modifiers)
        hotkeyManager.onPTTKeyDown = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .idle else { return }
                vfLog("PTT keyDown — starting dictation")
                self.startDictation()
            }
        }
        hotkeyManager.onPTTKeyUp = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                vfLog("PTT keyUp — stopping dictation")
                self.stopDictation()
            }
        }
    }

    // MARK: - Update Hotkey / PTT (called from SettingsView)

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        var settings = loadSettings()
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        saveSettings(settings)
        hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
        vfLog("Hotkey updated — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    func updatePTT(enabled: Bool, keyCode: UInt32, modifiers: UInt32) {
        var settings = loadSettings()
        settings.pttEnabled = enabled
        settings.pttKeyCode = keyCode
        settings.pttModifiers = modifiers
        saveSettings(settings)

        if enabled {
            setupPTT(keyCode: keyCode, modifiers: modifiers)
        } else {
            hotkeyManager.unregisterPTT()
        }
        vfLog("PTT updated — enabled:\(enabled) keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    private func setupAudioRecorder() {
        audioRecorder.onLevelUpdate = { [weak self] level in
            self?.audioLevel = level
        }
        audioRecorder.onDeviceChanged = { [weak self] in
            // Se estiver a gravar quando o dispositivo muda, reiniciar a gravação
            Task { @MainActor in
                guard let self = self, self.state == .recording else { return }
                print("[DictationController] Dispositivo alterado durante gravação")
                // Continua a gravar — AVAudioEngine adapta-se automaticamente ao novo device
            }
        }
    }

    // MARK: - Hotkey Handler

    func handleHotkeyPressed() {
        vfLog("handleHotkeyPressed() — current state: \(state)")
        switch state {
        case .idle:
            startDictation()
        case .recording:
            stopDictation()
        case .processing, .injecting:
            // Ignorar — aguardar conclusão
            break
        case .error:
            state = .idle
        }
    }

    // MARK: - Iniciar Ditação

    func startDictation() {
        vfLog("startDictation() called")

        // Verificar Accessibility (essencial para colar automaticamente)
        if !AXIsProcessTrusted() {
            vfLog("startDictation — Accessibility NOT trusted")
            // Continue anyway — text will go to clipboard and ReviewHUD will explain
            // (This commonly happens after rebuilds — macOS revokes permission when app signature changes)
        }

        // Check credits
        guard creditsManager.canDictate() else {
            showError("Free trial exhausted. Add your API key in Settings.")
            return
        }

        guard let apiKey = creditsManager.activeAPIKey, !apiKey.isEmpty else {
            showError("No API key configured. Open Settings.")
            return
        }

        vfLog("startDictation — apiKey present (length: \(apiKey.count)), mode: \(creditsManager.mode)")

        // Verificar foco (se configurado)
        let settings = loadSettings()

        // Feedback sonoro
        if settings.playSoundFeedback {
            playStartSound()
        }

        // Configure silence auto-stop
        audioRecorder.silenceAutoStopSeconds = settings.silenceAutoStopEnabled ? settings.silenceAutoStopSeconds : nil
        audioRecorder.onSilenceAutoStop = { [weak self] in
            guard let self, self.state == .recording else { return }
            vfLog("Silence auto-stop triggered")
            self.stopDictation()
        }

        // Start recording
        do {
            _ = try audioRecorder.startRecording()
            state = .recording

            // Show recording HUD
            RecordingHUDWindowController.shared.showRecording()

            // Start live speech recognizer for rolling word preview.
            // Use lastDetectedLanguage if available (from previous Whisper response),
            // otherwise fall back to settings.language.
            // This ensures the live preview uses the correct language after the first dictation.
            let liveLanguage = lastDetectedLanguage ?? settings.language
            if liveSpeechRecognizer.start(language: liveLanguage) {
                liveSpeechRecognizer.onRollingWords = { words in
                    RecordingHUDWindowController.shared.updateWords(words)
                }
                // Feed audio buffers to live recognizer
                audioRecorder.onAudioBuffer = { [weak self] buffer in
                    self?.liveSpeechRecognizer.appendBuffer(buffer)
                }
                vfLog("Live speech recognizer active")
            } else {
                vfLog("Live speech recognizer unavailable — HUD shows without words")
            }

        } catch {
            showError("Microphone error: \(error.localizedDescription)")
        }
    }

    // MARK: - Parar Ditação

    func stopDictation() {
        vfLog("stopDictation() called")

        // Stop live speech recognizer and clear buffer callback
        liveSpeechRecognizer.stop()
        audioRecorder.onAudioBuffer = nil

        guard let recording = audioRecorder.stopRecording() else {
            vfLog("stopRecording returned nil")
            RecordingHUDWindowController.shared.dismiss()
            state = .idle
            return
        }

        guard recording.duration > 0.5 else {
            vfLog("Recording too short (\(recording.duration)s) — ignored")
            RecordingHUDWindowController.shared.dismiss()
            state = .idle
            return
        }

        vfLog("Recording: \(recording.duration)s — processing...")

        // Transition HUD to processing state
        RecordingHUDWindowController.shared.transitionToProcessing()

        state = .processing

        dictationTask = Task {
            await processRecording(url: recording.url, duration: recording.duration)
        }
    }

    // MARK: - Processar Gravação

    private func processRecording(url: URL, duration: TimeInterval) async {
        let settings = loadSettings()
        guard let apiKey = creditsManager.activeAPIKey else {
            showError("Sem chave API")
            return
        }

        // Vocabulário hint para Whisper
        let vocabularyPrompt = vocabularyManager.generateWhisperPrompt()

        do {
            let lang = settings.language == "auto" ? "auto-detect" : settings.language
            vfLog("Sending to Whisper — language: \(lang)")
            let whisperResult = try await whisperService.transcribe(
                audioURL: url,
                language: settings.language,
                apiKey: apiKey,
                vocabularyHint: vocabularyPrompt
            )

            // Store detected language for next live preview
            if let detected = whisperResult.detectedLanguage {
                lastDetectedLanguage = detected
                vfLog("Detected language stored for next live preview: \(detected)")
            }

            var text = whisperResult.text
            vfLog("Whisper retornou: '\(text)'")

            // Aplicar substituições de vocabulário
            text = vocabularyManager.apply(to: text)

            guard !text.isEmpty else {
                vfLog("Empty transcription")
                state = .idle
                return
            }

            // Registar uso (só free trial)
            creditsManager.registerUsage(seconds: duration)

            // Inject text
            vfLog("Injecting text...")
            state = .injecting
            let injectionResult = textInjector.inject(text: text)

            var result = DictationResult(text: text, duration: duration)

            switch injectionResult {
            case .injected:
                vfLog("✅ Text injected directly via AX")
                result.pastedViaClipboard = false
            case .pastedAndRestored:
                vfLog("✅ Text pasted via ⌘V (AX trusted)")
                result.pastedViaClipboard = false
            case .copiedToClipboard:
                vfLog("⚠️ AX not trusted — text in clipboard, user must paste with ⌘V")
                result.pastedViaClipboard = true
            case .failed(let reason):
                vfLog("❌ Injection failed: \(reason)")
                result.pastedViaClipboard = true
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }

            lastResult = result

            // Dismiss recording HUD, show review HUD
            RecordingHUDWindowController.shared.dismiss()

            if settings.showReviewHUD {
                let resultCopy = result
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms — let paste process first
                ReviewHUDWindowController.shared.show(result: resultCopy, controller: self)
            }

            state = .idle

        } catch let error as WhisperError {
            RecordingHUDWindowController.shared.dismiss()
            showError(error.localizedDescription ?? "Unknown error")
        } catch {
            RecordingHUDWindowController.shared.dismiss()
            showError("Unexpected error: \(error.localizedDescription)")
        }
    }

    // MARK: - Review: Aplicar Correcção

    @discardableResult
    func applyCorrection(original: String, corrected: String) -> [(wrong: String, correct: String)] {
        guard original != corrected else { return [] }
        let learned = vocabularyManager.learnFromCorrection(original: original, corrected: corrected)
        if !learned.isEmpty {
            vfLog("Vocabulary learned \(learned.count) substitution(s): \(learned.map { "'\($0.wrong)'→'\($0.correct)'" }.joined(separator: ", "))")
        }
        return learned
    }

    // MARK: - Hotkey Update

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
        var settings = loadSettings()
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        saveSettings(settings)
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        state = .error(message)
        print("[DictationController] Erro: \(message)")
        // Voltar ao idle após 3 segundos
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .error = self.state {
                self.state = .idle
            }
        }
    }

    private func playStartSound() {
        // Som do sistema — discreto e imediato
        NSSound(named: "Tink")?.play()
    }

    // MARK: - Settings

    private let settingsKey = "appSettings"

    func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings.defaults
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}
