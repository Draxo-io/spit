import Foundation
import AppKit
import Combine
import UserNotifications

// MARK: - DictationController
// Orquestra todo o fluxo de ditação:
// idle → recording → processing → injecting → review → idle

@MainActor
class DictationController: ObservableObject {

    // MARK: - Estado Publicado

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastResult: DictationResult?
    @Published private(set) var audioLevel: Float = -60.0  // dB
    @Published private(set) var isAccessibilityTrusted: Bool = false
    @Published private(set) var pendingRetryURL: URL? = nil
    private var pendingRetryDuration: TimeInterval = 0
    private var retryCleanupTask: Task<Void, Never>? = nil

    // MARK: - Dependências

    private var audioRecorder: AudioRecorder!
    private var whisperService: WhisperService!
    private var proxyService: ProxyTranscriptionService!
    private var localWhisperService: LocalWhisperService!
    private var focusDetector: FocusDetector!
    private var textInjector: TextInjector!
    var vocabularyManager: VocabularyManager!
    var creditsManager: CreditsManager!
    var licenseManager: LicenseManager = .shared

    private var hotkeyManager: HotkeyManager!
    private var liveSpeechRecognizer: LiveSpeechRecognizer!
    private var dictationTask: Task<Void, Never>?

    /// Utilizador premiu a hotkey enquanto o modelo local ainda estava a carregar.
    /// Quando isReady disparar, inicia a ditação automaticamente.
    private var pendingDictationAfterLoad = false
    private var modelReadyCancellable: AnyCancellable?

    /// Smart hotkey timing — start of current keyDown press
    private var hotkeyPressStart: Date?

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
        proxyService = ProxyTranscriptionService()
        vfLog("  - ProxyTranscriptionService OK")
        localWhisperService = LocalWhisperService.shared
        vfLog("  - LocalWhisperService OK")
        // Auto-load local model on startup if engine is set to local
        let startupSettings = loadSettings()
        if startupSettings.transcriptionEngine == .local {
            Task { await LocalWhisperService.shared.load(model: startupSettings.localModel) }
        }
        focusDetector = FocusDetector()
        vfLog("  - FocusDetector OK")
        textInjector = TextInjector()
        vfLog("  - TextInjector OK")
        vocabularyManager = VocabularyManager.shared
        vfLog("  - VocabularyManager OK")
        creditsManager = CreditsManager.shared
        vfLog("  - CreditsManager OK")
        _ = TTSService.shared          // força inicialização na main thread
        vfLog("  - TTSService OK")
        hotkeyManager = HotkeyManager()
        vfLog("  - HotkeyManager OK")
        liveSpeechRecognizer = LiveSpeechRecognizer()
        vfLog("  - LiveSpeechRecognizer OK")
        setupAudioRecorder()
        vfLog("DictationController.setup() — audioRecorder setup done")
        setupHotkey()
        setupTTSHotkey()
        startAccessibilityMonitor()
        vfLog("DictationController.setup() — DONE ✅")
    }

    // MARK: - Accessibility Monitor

    private var axTimer: Timer?

    /// Verifica AX a cada 2s e publica o resultado — garante que a UI reflecte
    /// mudanças sem reiniciar o app (ex.: utilizador concede permissão a meio da sessão).
    private func startAccessibilityMonitor() {
        isAccessibilityTrusted = AXIsProcessTrusted()
        axTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            let trusted = AXIsProcessTrusted()
            DispatchQueue.main.async {
                if self?.isAccessibilityTrusted != trusted {
                    self?.isAccessibilityTrusted = trusted
                    vfLog("Accessibility changed → trusted: \(trusted)")
                }
            }
        }
    }

    func teardown() {
        hotkeyManager.unregister()
        hotkeyManager.unregisterTTS()
        audioRecorder.stopRecording()
    }

    // MARK: - Setup

    private func setupHotkey() {
        let settings = loadSettings()
        hotkeyManager.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)

        // Smart PTT+Toggle: keyDown = always start if idle / stop if recording
        hotkeyManager.onSmartKeyDown = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hotkeyPressStart = Date()
                vfLog("Smart keyDown — state: \(self.state)")
                switch self.state {
                case .idle:
                    self.startDictation()
                case .recording:
                    self.stopDictation()
                case .processing, .injecting:
                    break
                case .error:
                    self.state = .idle
                }
            }
        }

        // Smart PTT+Toggle: keyUp — if held ≥ 500ms and still recording, stop (PTT release)
        hotkeyManager.onSmartKeyUp = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let held = Date().timeIntervalSince(self.hotkeyPressStart ?? Date()) * 1000
                vfLog("Smart keyUp — held: \(Int(held))ms, state: \(self.state)")
                if self.state == .recording && held >= AppSettings.pttThresholdMs {
                    vfLog("PTT release — stopping dictation")
                    self.stopDictation()
                }
            }
        }
        vfLog("Smart hotkey setup — keyCode:\(settings.hotkeyKeyCode) modifiers:\(settings.hotkeyModifiers)")
    }

    // MARK: - Update Hotkey (called from SettingsView)

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        var settings = loadSettings()
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        saveSettings(settings)
        hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
        setupHotkeyCallbacks()
        vfLog("Hotkey updated — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    private func setupHotkeyCallbacks() {
        hotkeyManager.onSmartKeyDown = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hotkeyPressStart = Date()
                switch self.state {
                case .idle:      self.startDictation()
                case .recording: self.stopDictation()
                case .error:     self.state = .idle
                default: break
                }
            }
        }
        hotkeyManager.onSmartKeyUp = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let held = Date().timeIntervalSince(self.hotkeyPressStart ?? Date()) * 1000
                if self.state == .recording && held >= AppSettings.pttThresholdMs {
                    self.stopDictation()
                }
            }
        }
    }

    // MARK: - Queue Dictation While Model Loads

    private func queueDictationAfterLoad() {
        guard !pendingDictationAfterLoad else { return }
        pendingDictationAfterLoad = true
        vfLog("queueDictationAfterLoad — model still loading, queuing start")

        // Show the menu bar icon in loading state (already handled by MenuBarController).
        // Additionally send a notification so the user knows what is happening.
        sendModelWaitNotification()

        // Observe isReady: when it flips true, auto-start
        modelReadyCancellable = LocalWhisperService.shared.$isReady
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.pendingDictationAfterLoad else { return }
                self.pendingDictationAfterLoad = false
                self.modelReadyCancellable = nil
                vfLog("queueDictationAfterLoad — model ready, auto-starting dictation")
                self.startDictation()
            }
    }

    private func sendModelWaitNotification() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Loading local AI…")
        content.body  = String(localized: "Dictation will start automatically when the model is ready.")
        content.sound = nil
        let request = UNNotificationRequest(identifier: "model-loading-\(UUID())", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - TTS Read Selection

    private func setupTTSHotkey() {
        let settings = loadSettings()
        guard settings.ttsHotkeyEnabled else { return }
        hotkeyManager.registerTTS(keyCode: settings.ttsHotkeyKeyCode, modifiers: settings.ttsHotkeyModifiers)
        hotkeyManager.onTTSPressed = {
            Task { await TTSService.shared.speakSelection() }
        }
    }

    func updateTTSHotkey(enabled: Bool, keyCode: UInt32, modifiers: UInt32) {
        var settings = loadSettings()
        settings.ttsHotkeyEnabled = enabled
        settings.ttsHotkeyKeyCode = keyCode
        settings.ttsHotkeyModifiers = modifiers
        saveSettings(settings)

        hotkeyManager.unregisterTTS()
        if enabled {
            hotkeyManager.registerTTS(keyCode: keyCode, modifiers: modifiers)
            hotkeyManager.onTTSPressed = {
                Task { await TTSService.shared.speakSelection() }
            }
        }
        vfLog("TTS hotkey updated — enabled:\(enabled) keyCode:\(keyCode) modifiers:\(modifiers)")
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

    // MARK: - Iniciar Ditação

    func startDictation() {
        vfLog("startDictation() called")

        // Verificar Accessibility (essencial para colar automaticamente)
        if !AXIsProcessTrusted() {
            vfLog("startDictation — Accessibility NOT trusted")
            // Continue anyway — text will go to clipboard and ReviewHUD will explain
            // (This commonly happens after rebuilds — macOS revokes permission when app signature changes)
        }

        // Check license gate (skip when using local engine)
        let settings0 = loadSettings()
        if settings0.transcriptionEngine == .cloud {
            let lPlan = licenseManager.plan
            if lPlan == .trial && licenseManager.trialExhausted {
                showError(String(localized: "Free trial exhausted. Upgrade in Settings."))
                return
            }
            if lPlan == .byok {
                guard let apiKey = creditsManager.activeAPIKey, !apiKey.isEmpty else {
                    showError("No API key configured. Open Settings.")
                    return
                }
                vfLog("startDictation — BYOK mode, apiKey length: \(apiKey.count)")
            } else {
                guard licenseManager.getJWT() != nil || lPlan == .trial else {
                    showError("No active license. Open Settings.")
                    return
                }
                vfLog("startDictation — proxy mode, plan: \(lPlan.rawValue)")
            }
        } else {
            // Local engine — if model is still loading, queue and auto-start when ready
            if !localWhisperService.isReady {
                if localWhisperService.isLoading {
                    queueDictationAfterLoad()
                } else {
                    showError(String(localized: "Local model not loaded. Open Settings → Local AI."))
                }
                return
            }
            vfLog("startDictation — local engine, model: \(localWhisperService.loadedModel?.rawValue ?? "?")")
        }

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

    // MARK: - Retry após falha

    func retryPendingDictation() {
        guard let url = pendingRetryURL else { return }
        let duration = pendingRetryDuration

        retryCleanupTask?.cancel()
        retryCleanupTask = nil
        pendingRetryURL = nil

        guard let apiKey = creditsManager.activeAPIKey, !apiKey.isEmpty else {
            showError("No API key configured.")
            return
        }

        state = .processing
        RecordingHUDWindowController.shared.transitionToProcessing()

        dictationTask = Task {
            await processRecording(url: url, duration: duration)
        }
    }

    // MARK: - Processar Gravação

    private func processRecording(url: URL, duration: TimeInterval) async {
        let settings = loadSettings()
        let vocabularyPrompt = vocabularyManager.generateWhisperPrompt()
        let plan = licenseManager.plan

        do {
            let transcribedText: String
            let detectedLang: String?

            if settings.transcriptionEngine == .local {
                // On-device via WhisperKit
                vfLog("processRecording — local engine")
                let result = try await localWhisperService.transcribe(
                    audioURL: url,
                    language: settings.language,
                    vocabularyHint: vocabularyPrompt
                )
                transcribedText = result.text
                detectedLang    = result.detectedLanguage
            } else if plan == .byok {
                let provider = settings.byokProvider
                guard let apiKey = KeychainManager.shared.getKey(for: provider) else {
                    throw WhisperError.noAPIKey
                }
                vfLog("processRecording — BYOK → \(provider.displayName)")
                let result = try await whisperService.transcribe(
                    audioURL: url,
                    language: settings.language,
                    apiKey: apiKey,
                    vocabularyHint: vocabularyPrompt,
                    endpoint: provider.endpoint,
                    model: provider.model
                )
                transcribedText = result.text
                detectedLang    = result.detectedLanguage
            } else {
                // trial / pro: proxy (Groq)
                vfLog("processRecording — proxy (plan: \(plan.rawValue))")
                let result = try await proxyService.transcribe(
                    audioURL: url,
                    language: settings.language,
                    vocabularyHint: vocabularyPrompt
                )
                transcribedText = result.text
                detectedLang    = result.detectedLanguage
                if plan == .trial {
                    licenseManager.recordTrialUsage(seconds: result.seconds)
                }
            }

            if let detected = detectedLang {
                lastDetectedLanguage = detected
                vfLog("Detected language stored for next live preview: \(detected)")
            }

            var text = transcribedText
            vfLog("Whisper retornou: '\(text)'")

            // Remover anotações de ruído/som que o Whisper alucina em silêncio ou ruído de fundo.
            // Exemplos: "[Som de fundo]", "[Música]", "(risos)", "(aplausos)"
            text = removeWhisperNoiseTokens(text)

            // Aplicar substituições de vocabulário
            text = vocabularyManager.apply(to: text)

            // LLM paragraph auto-formatting (optional, requires API key)
            if settings.autoparagraphEnabled {
                if let formatted = await TextFormattingService.shared.format(text, settings: settings) {
                    text = formatted
                }
            }

            // Adicionar ponto final se o texto não termina com pontuação
            // (only when LLM formatting is off — LLM already handles punctuation)
            if !settings.autoparagraphEnabled {
                let terminalPunctuation: Set<Character> = [".", "!", "?", "…", ":", ";", ",", "\"", "'", "»", ")"]
                if let last = text.last, !terminalPunctuation.contains(last) {
                    text += "."
                }
            }

            // Auto-translate if enabled
            if settings.autoTranslateEnabled, !settings.autoTranslateTargetLanguage.isEmpty {
                if let translated = await TranslationService.shared.translate(
                    text,
                    to: settings.autoTranslateTargetLanguage,
                    settings: settings
                ) {
                    text = translated
                }
            }

            guard !text.isEmpty else {
                vfLog("Empty transcription")
                state = .idle
                return
            }

            // Registar uso (só free trial)
            creditsManager.registerUsage(seconds: duration)
            // Guardar no histórico
            HistoryManager.shared.add(text: text, duration: duration)
            // Limpar pending retry (esta transcriçao teve sucesso)
            pendingRetryURL = nil
            retryCleanupTask?.cancel()
            retryCleanupTask = nil

            // Safety net: always put in clipboard BEFORE attempting injection.
            // Even if injection fails silently, user can recover with ⌘V.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)

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

            // Mostrar Review HUD apenas quando a colagem automática falhou —
            // se o texto já foi injectado/colado no campo, o utilizador não precisa
            // de rever nada e o HUD seria apenas ruído visual.
            // O utilizador pode forçar mostrar sempre via Settings (showReviewHUD).
            let pasteSucceeded = !result.pastedViaClipboard
            if !pasteSucceeded || settings.showReviewHUD {
                let resultCopy = result
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms — let paste settle first
                ReviewHUDWindowController.shared.show(result: resultCopy, controller: self)
            }

            state = .idle

        } catch let error as WhisperError {
            RecordingHUDWindowController.shared.dismiss()
            storePendingRetry(url: url, duration: duration)
            showError(error.localizedDescription)
        } catch {
            RecordingHUDWindowController.shared.dismiss()
            storePendingRetry(url: url, duration: duration)
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

    // MARK: - Helpers

    private func storePendingRetry(url: URL, duration: TimeInterval) {
        retryCleanupTask?.cancel()
        pendingRetryURL = url
        pendingRetryDuration = duration
        // Auto-delete audio after 10 minutes to avoid filling disk
        retryCleanupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000_000)  // 10 min
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { [weak self] in
                if self?.pendingRetryURL == url {
                    self?.pendingRetryURL = nil
                }
            }
        }
    }

    // MARK: - Limpeza de alucinações do Whisper

    /// Remove tokens de ruído/som que o Whisper insere quando detecta silêncio
    /// ou ruído de fundo: "[Som de fundo]", "[Música]", "(risos)", etc.
    private func removeWhisperNoiseTokens(_ input: String) -> String {
        // Padrão: qualquer conteúdo entre [ ] ou ( ) que seja uma anotação de som/ruído.
        // O Whisper usa tanto maiúsculas como minúsculas, em vários idiomas.
        let bracketPattern = try? NSRegularExpression(
            pattern: #"[\[\(][^\]\)]{1,60}[\]\)]"#,
            options: [.caseInsensitive]
        )
        var text = input
        if let regex = bracketPattern {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }
        // Limpar espaços múltiplos e espaços antes de pontuação que ficaram
        text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        return text
    }

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
