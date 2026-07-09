import Foundation
import AppKit
import Combine
import UserNotifications
import NaturalLanguage

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
    @Published var currentSettings: AppSettings = AppSettings.defaults
    private var pendingRetryDuration: TimeInterval = 0
    private var retryCleanupTask: Task<Void, Never>? = nil

    // MARK: - Dependências

    private var audioRecorder: AudioRecorder!
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

    /// Captured at stopDictation() — the focused AX element and frontmost app at the exact
    /// moment the user stops recording, before any async processing (transcription + translation).
    /// Passed to inject() to avoid using stale focus after 3-4 seconds of network calls.
    private var capturedFocusedElement: AXUIElement? = nil
    private var capturedTargetApp: NSRunningApplication? = nil
    /// True if the target app had a focused window at recording-stop time.
    /// Electron/web apps have a focused window even when no AX text field is exposed.
    private var capturedTargetHasFocusedWindow: Bool = false

    /// Last language detected by Whisper (e.g. "pt", "en") — used for live preview on next recording.
    /// Only populated when settings.language == "auto".
    private var lastDetectedLanguage: String?

    /// True if the live speech recognizer produced any words during the current recording.
    /// This is the single source of truth for "voice detected" — used to decide whether
    /// to call the transcription service at all. The previous dB-based energy gate
    /// (on the converted mono buffer) was replaced by this signal because the live
    /// recognizer reads the raw buffer and mirrors what the user sees in the pill.
    private var liveWordsSeen: Bool = false

    /// Guards against re-entrant calls to startDictation() while we await pauseMedia().
    /// Set synchronously (before any await) so no two async invocations can both pass.
    private var isStartingDictation = false

    /// Global NSEvent monitor for Escape key — active only during recording.
    private var escapeMonitor: Any?

    /// Auto-stop timer — fires at maxRecordingSeconds to prevent Groq API failures on long audio.
    private var autoStopTask: Task<Void, Never>?
    /// Groq/OpenAI Whisper handles files up to 25 MB reliably. 4 minutes (~240s) at typical
    /// mic bitrates stays well within that limit while supporting longer dictation sessions.
    private let maxRecordingSeconds: TimeInterval = 240

    // MARK: - Init

    nonisolated init() {
        vfLog("DictationController.init() — created (nonisolated)")
    }

    /// Chamar depois de init, já dentro do MainActor context
    func setup() {
        vfLog("DictationController.setup() — START")
        audioRecorder = AudioRecorder()
        vfLog("  - AudioRecorder OK")
        localWhisperService = LocalWhisperService.shared
        vfLog("  - LocalWhisperService OK")
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
        currentSettings = loadSettings()
        vfLog("DictationController.setup() — DONE ✅")
    }

    // MARK: - Accessibility Monitor

    private var axTimer: Timer?

    /// Re-check imediato de AX — chamado quando a app volta ao foreground (AppDelegate).
    func recheckAccessibility() {
        let trusted = AXIsProcessTrusted()
        if isAccessibilityTrusted != trusted {
            isAccessibilityTrusted = trusted
            vfLog("Accessibility re-check on foreground → trusted: \(trusted)")
        }
    }

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

                // If TTS is speaking, stop it first (Globe = universal stop)
                if TTSService.shared.isSpeaking {
                    TTSService.shared.stop()
                    return
                }

                // Smart Globe: text selected → read aloud; nothing selected → dictate
                if case .idle = self.state {
                    // Uses AX (instant) + Cmd+C change-detection fallback (100ms)
                    if let text = await TTSService.shared.selectedTextForSmartKey(), !text.isEmpty {
                        await TTSService.shared.speak(text)
                        return
                    }
                }

                switch self.state {
                case .idle:
                    await self.startDictation()
                case .recording:
                    self.stopDictation()
                case .processing, .injecting:
                    break
                case .error:
                    self.state = .idle
                }
            }
        }

        // Smart PTT+Toggle: keyUp
        hotkeyManager.onSmartKeyUp = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let held = Date().timeIntervalSince(self.hotkeyPressStart ?? Date()) * 1000
                vfLog("Smart keyUp — held: \(Int(held))ms, state: \(self.state)")
                guard self.state == .recording else { return }
                if held >= AppSettings.pttThresholdMs {
                    // PTT release — stop immediately.
                    vfLog("PTT release — stopping dictation")
                    self.stopDictation()
                }
                // Toggle tap (held < threshold): keep recording until user taps again.
            }
        }
        vfLog("Smart hotkey setup — keyCode:\(settings.hotkeyKeyCode) modifiers:\(settings.hotkeyModifiers)")
    }

    // MARK: - Pause/Resume hotkey during capture (called from SettingsView)

    /// Suspends hotkey callbacks without removing monitors.
    /// Used during hotkey-capture UI so pressing any key doesn't trigger dictation.
    func suspendHotkeyCallbacks() {
        hotkeyManager.onSmartKeyDown = nil
        hotkeyManager.onSmartKeyUp = nil
    }

    func resumeHotkeyCallbacks() {
        setupHotkeyCallbacks()
    }

    // MARK: - Update Hotkey (called from SettingsView)

    func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        var settings = loadSettings()
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        // Single-key model: TTS always follows dictation hotkey
        settings.ttsHotkeyKeyCode   = keyCode
        settings.ttsHotkeyModifiers = modifiers
        saveSettings(settings)
        hotkeyManager.register(keyCode: keyCode, modifiers: modifiers)
        // TTS handled by smart handler — no separate monitor needed for same key
        hotkeyManager.unregisterTTS()
        setupHotkeyCallbacks()
        vfLog("Hotkey updated — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    private func setupHotkeyCallbacks() {
        hotkeyManager.onSmartKeyDown = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hotkeyPressStart = Date()
                vfLog("Smart keyDown — state: \(self.state)")

                if TTSService.shared.isSpeaking {
                    TTSService.shared.stop()
                    return
                }

                if case .idle = self.state {
                    if let text = await TTSService.shared.selectedTextForSmartKey(), !text.isEmpty {
                        await TTSService.shared.speak(text)
                        return
                    }
                }

                switch self.state {
                case .idle:      await self.startDictation()
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
                guard self.state == .recording else { return }
                if held >= AppSettings.pttThresholdMs {
                    self.stopDictation()
                }
                // Toggle tap: keep recording until the user taps again.
            }
        }
    }

    // MARK: - Queue Dictation While Model Loads

    private func queueDictationAfterLoad() {
        guard !pendingDictationAfterLoad else { return }
        pendingDictationAfterLoad = true
        vfLog("queueDictationAfterLoad — model loading, queuing start")

        // Mostrar a pill com estado de loading para o utilizador saber o que se passa.
        HUDCoordinator.shared.modelLoadingStarted()

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
                Task { await self.startDictation() }
            }
    }

    // MARK: - TTS Read Selection

    private func setupTTSHotkey() {
        let settings = loadSettings()
        guard settings.ttsHotkeyEnabled else { return }

        // Single-key model: TTS key always mirrors dictation key.
        // The smart handler in onSmartKeyDown already covers TTS when same key.
        // Only register a separate TTS monitor if someone manually set a different key.
        guard settings.ttsHotkeyKeyCode != settings.hotkeyKeyCode ||
              settings.ttsHotkeyModifiers != settings.hotkeyModifiers else { return }

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
                vfLog("[DictationController] Dispositivo alterado durante gravação")
                // Continua a gravar — AVAudioEngine adapta-se automaticamente ao novo device
            }
        }
    }

    // MARK: - Iniciar Ditação

    func startDictation() async {
        // Guard against re-entrant calls. isStartingDictation is set SYNCHRONOUSLY
        // before any await, so no two async invocations can both pass this check.
        guard state == .idle, !isStartingDictation else {
            vfLog("startDictation() — ignorado, estado:\(state) isStarting:\(isStartingDictation)")
            return
        }
        isStartingDictation = true
        defer { isStartingDictation = false }

        vfLog("startDictation() called")

        // Verificar Accessibility (essencial para colar automaticamente)
        if !AXIsProcessTrusted() {
            vfLog("startDictation — Accessibility NOT trusted")
            // Continue anyway — text will go to clipboard and ReviewHUD will explain
            // (This commonly happens after rebuilds — macOS revokes permission when app signature changes)
        }

        // Local engine — se o modelo não está pronto (loading ou descarregado por pressão de memória),
        // recarregar automaticamente e encadear o início do ditado.
        if !localWhisperService.isReady {
            if !localWhisperService.isLoading {
                // Modelo descarregado (ex: pressão de memória) — recarregar silenciosamente.
                Task { await LocalWhisperService.shared.load(model: .small) }
            }
            queueDictationAfterLoad()
            return
        }
        vfLog("startDictation — local engine, model: \(localWhisperService.loadedModel?.rawValue ?? "?")")

        let settings = loadSettings()

        // Pause media playback (only if something is playing) so it doesn't bleed into the mic.
        // After the await, re-check state — an external stop (e.g. another task) may have fired.
        if settings.muteAudioOnActivity {
            await SystemAudioManager.shared.pauseMedia()
            // If state changed while awaiting, undo the pause and bail.
            guard state == .idle else {
                vfLog("startDictation() — estado mudou durante pauseMedia (\(state)), revertendo")
                SystemAudioManager.shared.resumeMedia()
                return
            }
        }

        // Feedback sonoro
        if settings.playSoundFeedback {
            playStartSound()
        }

        // Start recording
        do {
            _ = try audioRecorder.startRecording()
            state = .recording
            startEscapeMonitor()
            startAutoStopTimer()
            HUDCoordinator.shared.recordingStarted()

            // Idioma para o LIVE preview (proof-of-life, não transcrição final).
            //  - Se o user definiu explicitamente um idioma, esse manda.
            //  - Se está em "auto", **NÃO** usar lastDetectedLanguage — fica preso
            //    no idioma da sessão anterior. Se o user alternar idiomas (ex.: uma
            //    sessão acidental em EN), todas as sessões seguintes ficavam em EN
            //    mesmo a ditar em PT. Em "auto", confia no LiveSpeechRecognizer que
            //    resolve via NSLocale.preferredLanguages (idioma do macOS — robusto).
            //  O Whisper, na fase de transcrição, faz auto-detect real do áudio,
            //  então o texto final permanece correto.
            let liveLanguage: String = (settings.language == "auto") ? "auto" : settings.language
            liveWordsSeen = false
            liveSpeechRecognizer.onRollingWords = { [weak self] words in
                if !words.isEmpty { self?.liveWordsSeen = true }
                HUDCoordinator.shared.recordingWords(words)
            }
            if liveSpeechRecognizer.start(language: liveLanguage) {
                audioRecorder.onAudioBuffer = { [weak self] buffer in
                    self?.liveSpeechRecognizer.appendBuffer(buffer)
                }
                vfLog("Live speech recognizer active")
            } else {
                liveSpeechRecognizer.onRollingWords = nil
                vfLog("Live speech recognizer unavailable — HUD shows without words")
            }

        } catch {
            // Recording failed — undo media pause so music isn't left paused
            SystemAudioManager.shared.resumeMedia()
            showError("Microphone error: \(error.localizedDescription)")
        }
    }

    // MARK: - Escape key monitor (ativo apenas durante gravação)

    private func startEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // keyCode 53 = Escape
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self, case .recording = self.state else { return }
                vfLog("Escape pressed — cancelling dictation")
                self.cancelDictation()
            }
        }
        vfLog("Escape monitor started")
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
            vfLog("Escape monitor stopped")
        }
    }

    /// Cancela a ditação em curso sem transcrever — descarta o áudio.
    func cancelDictation() {
        vfLog("cancelDictation() called")
        stopEscapeMonitor()
        stopAutoStopTimer()

        liveSpeechRecognizer.stop()
        audioRecorder.onAudioBuffer = nil

        let recording = audioRecorder.stopRecording()
        SystemAudioManager.shared.resumeMedia()

        // Apagar o ficheiro de áudio — não queremos transcrever
        if let url = recording?.url {
            try? FileManager.default.removeItem(at: url)
        }

        finishCycle(
            result: .placeholder(
                outcome: .empty(reason: String(localized: "Ditado cancelado.")),
                duration: recording?.duration ?? 0
            )
        )
    }

    // MARK: - Auto-stop (limite de duração para proteger contra rejeição do Groq)

    private func startAutoStopTimer() {
        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            guard let self else { return }
            let limit = self.maxRecordingSeconds
            try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard case .recording = self.state else { return }
                vfLog("Auto-stop: \(Int(limit))s limit reached — stopping to avoid Groq rejection")
                self.stopDictation()
            }
        }
    }

    private func stopAutoStopTimer() {
        autoStopTask?.cancel()
        autoStopTask = nil
    }

    // MARK: - Parar Ditação

    func stopDictation() {
        vfLog("stopDictation() called")
        stopEscapeMonitor()
        stopAutoStopTimer()

        // Stop live speech recognizer and clear buffer callback
        liveSpeechRecognizer.stop()
        audioRecorder.onAudioBuffer = nil

        // ── Capturar foco AGORA — antes de qualquer operação async ───────────
        // A transcrição + tradução demora 2-5s. Durante esse tempo o foco pode
        // mudar. Capturamos o elemento AX e o app-alvo neste momento exato
        // (utilizador acabou de falar — o campo de texto alvo está ativo).
        capturedTargetApp = NSWorkspace.shared.frontmostApplication
        if AXIsProcessTrusted() {
            capturedFocusedElement = focusDetector.getFocusedElement()
            // Also record whether the app has a focused window at all.
            // Electron/web apps don't expose AX text fields but DO have a focused window,
            // so this helps distinguish "Electron with field" from "no field at all".
            capturedTargetHasFocusedWindow = focusDetector.hasFocusedWindow(for: capturedTargetApp)
        } else {
            capturedFocusedElement = nil
            capturedTargetHasFocusedWindow = false
        }
        vfLog("Captured target: \(capturedTargetApp?.localizedName ?? "?") / element: \(capturedFocusedElement != nil) / window: \(capturedTargetHasFocusedWindow)")

        // Single voice signal: did the live speech recognizer see any word?
        let voiceDetected = liveWordsSeen
        vfLog("[SpeechDetect] liveWordsSeen:\(liveWordsSeen) → voiceDetected:\(voiceDetected)")

        // Snapshot settings once — used for all decisions in this stop cycle.
        let stopSettings = loadSettings()

        guard let recording = audioRecorder.stopRecording() else {
            vfLog("stopRecording returned nil")
            // Resume media even on error — don't leave music paused
            SystemAudioManager.shared.resumeMedia()
            finishCycle(
                result: .placeholder(outcome: .error(message: String(localized: "Microphone unavailable.")), duration: 0)
            )
            return
        }

        // Resume media now that recording has fully stopped
        SystemAudioManager.shared.resumeMedia()

        if recording.duration < Constants.minimumRecordingSeconds {
            vfLog("Recording too short (\(recording.duration)s) — treat as empty")
            try? FileManager.default.removeItem(at: recording.url)
            finishCycle(
                result: .placeholder(
                    outcome: .empty(reason: String(localized: "Recording too short.")),
                    duration: recording.duration
                )
            )
            return
        }

        let tq = stopSettings.textQuality
        if tq.enabled && tq.energyGate && !voiceDetected {
            vfLog("No voice detected by live recognizer — skipping proxy, showing empty ReviewHUD")
            try? FileManager.default.removeItem(at: recording.url)
            finishCycle(
                result: .placeholder(
                    outcome: .empty(reason: String(localized: "No voice detected.")),
                    duration: recording.duration
                )
            )
            return
        }

        vfLog("Recording: \(recording.duration)s, voice detected — processing…")

        // Transition HUD to processing state
        HUDCoordinator.shared.processingStarted()

        state = .processing

        // Cancel any previous task still running (e.g. user triggered new dictation
        // while prior processRecording was still in flight).
        dictationTask?.cancel()
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

        state = .processing
        HUDCoordinator.shared.processingStarted()

        dictationTask?.cancel()
        dictationTask = Task {
            await processRecording(url: url, duration: duration)
        }
    }

    // MARK: - Processar Gravação
    //
    // Every dictation cycle ends through `finishCycle(...)`. There is no silent
    // discard path: on failure / empty result, a placeholder DictationResult is
    // produced with the appropriate outcome and handed to the HUDCoordinator.

    private func processRecording(url: URL, duration: TimeInterval) async {
        vfLog("[processRecording] START duration:\(String(format: "%.2f", duration))s")
        let settings = loadSettings()

        // ── Stage 1: Transcribe (with retry on transient HTTP 5xx) ───────────
        let transcribed: (text: String, detectedLang: String?)
        let maxTranscribeAttempts = 3
        var lastTranscribeError: Error? = nil
        var transcribeResult: (text: String, detectedLang: String?)? = nil

        for attempt in 1...maxTranscribeAttempts {
            do {
                transcribeResult = try await transcribe(url: url, settings: settings)
                vfLog("[processRecording] transcribe OK (attempt \(attempt)) — \(transcribeResult!.text.count) chars, lang:\(transcribeResult!.detectedLang ?? "?")")
                lastTranscribeError = nil
                break
            } catch let error as LicenseError {
                vfLog("[processRecording] ❌ LicenseError: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: url)
                finishCycle(
                    result: .placeholder(outcome: .error(message: error.localizedDescription), duration: duration)
                )
                return
            } catch {
                let isTransient = isTransientHTTPError(error)
                vfLog("[processRecording] ❌ transcribe error (attempt \(attempt)/\(maxTranscribeAttempts)): \(describeError(error))\(isTransient ? " — will retry" : "")")
                lastTranscribeError = error

                if isTransient && attempt < maxTranscribeAttempts {
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s back-off
                } else {
                    break
                }
            }
        }

        if let error = lastTranscribeError {
            let message = describeError(error)
            vfLog("[processRecording] ❌ transcribe failed after \(maxTranscribeAttempts) attempts: \(message)")
            storePendingRetry(url: url, duration: duration)
            finishCycle(
                result: .placeholder(outcome: .error(message: message), duration: duration)
            )
            return
        }

        guard let transcribedResult = transcribeResult else {
            // Should never happen — loop above either sets transcribeResult or returns early.
            finishCycle(result: .placeholder(outcome: .error(message: "Internal error"), duration: duration))
            return
        }
        transcribed = transcribedResult

        if let detected = transcribed.detectedLang {
            // Whisper/Groq returns full English names ("Portuguese", "English", etc.).
            // Normalise to a BCP-47 base code so LiveSpeechRecognizer can match locales.
            lastDetectedLanguage = Self.normalizeWhisperLang(detected)
        }

        // ── Stage 2: Cleanup + vocabulary + optional LLM formatting ───────────
        var text = transcribed.text
        text = DictationController.removeWhisperNoiseTokens(text)
        // Substituições inequívocas (proper nouns, marcas, siglas) — regex word-boundary.
        text = vocabularyManager.apply(to: text)
        let textBeforeFormatting = text  // guardar Whisper output puro (antes da formatação)
        if settings.autoparagraphEnabled {
            text = TextFormattingService.shared.applyLocal(text)
        }
        vfLog("[processRecording] after cleanup: \(text.count) chars")

        // Empty after filters → show empty ReviewHUD (no injection, no retry).
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            vfLog("[processRecording] empty after filters — empty outcome")
            try? FileManager.default.removeItem(at: url)
            finishCycle(
                result: .placeholder(
                    outcome: .empty(reason: String(localized: "Nothing transcribed.")),
                    duration: duration
                )
            )
            return
        }

        // ── Stage 3: Translate (before adding final period) ───────────────────
        var translationApplied = false
        var preTranslationText: String? = nil
        var translationErrorMessage: String? = nil
        let translateTarget = settings.autoTranslateTargetLanguage

        if settings.autoTranslateEnabled, !translateTarget.isEmpty {
            // Pass the Whisper-detected language so attemptTranslation can skip the
            // NLLanguageRecognizer check when we already know the source language.
            // NLLanguageRecognizer can misfire after autoparagraph rewrites the text.
            let whisperLang = lastDetectedLanguage  // already normalised to BCP-47
            switch await attemptTranslation(text: text, target: translateTarget,
                                            knownSourceLanguage: whisperLang) {
            case .skipped(let reason):
                vfLog("[processRecording] translation skipped — \(reason)")
            case .applied(let translated):
                preTranslationText = text
                text = translated
                translationApplied = true
                vfLog("[processRecording] translation applied '\(whisperLang ?? "?")' → '\(translateTarget)': \(translated.prefix(60))")
            case .failed(let message):
                translationErrorMessage = message
                vfLog("[processRecording] translation failed — pasting original: \(message)")
            }
        }

        // ── Stage 4: Add final period if missing (after translation) ──────────
        if !settings.autoparagraphEnabled {
            let terminalPunctuation: Set<Character> = [".", "!", "?", "…", ":", ";", ",", "\"", "'", "»", ")"]
            if let last = text.last, !terminalPunctuation.contains(last) {
                text += "."
            }
        }

        // ── Stage 5: Inject text ──────────────────────────────────────────────
        HistoryManager.shared.add(text: text, duration: duration)
        CreditsManager.shared.recordTranscription(seconds: duration)
        pendingRetryURL = nil
        retryCleanupTask?.cancel()
        retryCleanupTask = nil

        state = .injecting
        vfLog("[processRecording] injecting \(text.count) chars (translated:\(translationApplied)): \(text.prefix(80))")

        // Snapshot before clearing — used to decide ReviewHUD visibility for keyboard injection
        let targetBundleID = capturedTargetApp?.bundleIdentifier ?? ""
        // Snapshot capture flags before clearing — used to decide ReviewHUD visibility.
        let hadCapturedAXElement = capturedFocusedElement != nil
        let hadFocusedWindow    = capturedTargetHasFocusedWindow

        let injectionResult = textInjector.inject(
            text: text,
            precapturedElement: capturedFocusedElement,
            targetApp: capturedTargetApp
        )
        capturedFocusedElement = nil
        capturedTargetApp = nil
        capturedTargetHasFocusedWindow = false

        var result = DictationResult(text: text, duration: duration)
        result.wasTranslated = translationApplied
        result.translatedToLanguage = translationApplied ? translateTarget : ""
        result.preTranslationText = preTranslationText
        // Só guardar rawTranscriptionText se o LLM de formatação mudou alguma coisa
        if textBeforeFormatting != text && !translationApplied {
            result.rawTranscriptionText = textBeforeFormatting
        }
        result.translationErrorMessage = translationErrorMessage
        result.outcome = .success

        let injectionMethodLabel: String
        switch injectionResult {
        case .injectedViaAX:
            vfLog("[processRecording] ✅ injected via AX")
            result.pastedViaClipboard = false
            injectionMethodLabel = "ax"
        case .injectedViaKeyboard:
            result.pastedViaClipboard = false
            // Distinguish two sub-paths:
            //   A) hadCapturedAXElement == false → clipboard+Cmd+V used (no AX text field found).
            //      Sub-cases:
            //        • Electron/web WITH a field focused → app has a focused window → paste worked.
            //        • No field at all (desktop, non-interactive area) → no focused window → nothing received the paste.
            //      Use hadFocusedWindow to tell them apart: if window exists, assume paste worked.
            //   B) hadCapturedAXElement == true → CGEvent keyboard used (rare native-app edge case).
            //      Injection likely worked; no banner needed.
            let isDefinitelyNoField = targetBundleID == "com.apple.finder"
            let likelyNoField = !hadCapturedAXElement && !hadFocusedWindow
            result.usedKeyboardFallback = isDefinitelyNoField || likelyNoField
            if result.usedKeyboardFallback {
                // Auto-copy so the user can ⌘V immediately — the banner says exactly that.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                vfLog("[processRecording] ⌨ No field detected — text auto-copied to clipboard for ⌘V")
            }
            vfLog("[processRecording] ✅ injected via keyboard (target:\(targetBundleID), hadAX:\(hadCapturedAXElement), hadWindow:\(hadFocusedWindow), fallback:\(result.usedKeyboardFallback))")
            injectionMethodLabel = "keyboard"
        case .injectedViaClipboardPaste:
            // App blacklisted (Electron/Catalyst onde AX dá falso-positivo).
            // Texto foi copiado e ⌘V sintético enviado — o paste funciona na grande
            // maioria dos casos. NÃO marcamos usedKeyboardFallback nem pastedViaClipboard:
            // o ReviewHUD só abre pelos critérios normais (palavras suspeitas, erro,
            // modo always). O texto fica retido no clipboard como rede de segurança
            // silenciosa caso o utilizador precise de ⌘V manual.
            result.pastedViaClipboard = false
            result.usedKeyboardFallback = false
            vfLog("[processRecording] ✅ injected via clipboard-paste (blacklist target:\(targetBundleID)) — text kept in clipboard")
            injectionMethodLabel = "clipboard-paste"
        case .copiedToClipboard:
            vfLog("[processRecording] ⚠️ clipboard fallback (AX not trusted)")
            result.pastedViaClipboard = true
            injectionMethodLabel = "clipboard"
        case .failed(let reason):
            vfLog("[processRecording] ❌ injection failed: \(reason)")
            result.pastedViaClipboard = true
            injectionMethodLabel = "clipboard"
        }

        lastResult = result
        ActivityLogService.shared.logDictation(
            sourceText: preTranslationText ?? text,
            sourceLanguage: transcribed.detectedLang,
            outputText: text,
            outputLanguage: translationApplied ? translateTarget : transcribed.detectedLang,
            injectionMethod: injectionMethodLabel,
            wasTranslated: translationApplied,
            durationSeconds: duration,
            reviewShown: false
        )

        finishCycle(result: result)
    }

    // MARK: - Stage helpers

    /// Transcribes audio using the local Whisper engine.
    /// May throw `WhisperError` or any underlying error from LocalWhisperService.
    private func transcribe(url: URL, settings: AppSettings) async throws -> (text: String, detectedLang: String?) {
        let vocabularyPrompt = vocabularyManager.generateWhisperPrompt()
        vfLog("[transcribe] local engine")
        let r = try await localWhisperService.transcribe(
            audioURL: url,
            language: settings.language,
            vocabularyHint: vocabularyPrompt
        )
        return (r.text, r.detectedLanguage)
    }

    /// Outcome of a translation attempt.
    private enum TranslationAttempt {
        case skipped(String)
        case applied(String)
        case failed(String)
    }

    /// Translate `text` to `target`. Returns an explicit outcome so the caller can
    /// surface a warning in the ReviewHUD when the service fails (instead of silently
    /// pasting the original).
    ///
    /// - Parameter knownSourceLanguage: BCP-47 code already established by Whisper (e.g. "pt").
    ///   When provided, skips NLLanguageRecognizer — which can misidentify text after autoparagraph
    ///   rewrites it. When nil, falls back to NLLanguageRecognizer.
    private func attemptTranslation(text: String,
                                    target: String,
                                    knownSourceLanguage: String? = nil) async -> TranslationAttempt {
        let targetBase = target.components(separatedBy: "-").first ?? target

        // Determine source language: prefer known Whisper detection over NLLanguageRecognizer.
        let detectedBase: String
        if let known = knownSourceLanguage, !known.isEmpty, known != "auto" {
            detectedBase = known.components(separatedBy: "-").first ?? known
            vfLog("[translation] source language from Whisper: '\(detectedBase)'")
            // Safety check: Whisper sometimes silently translates audio to English during
            // transcription (a known quirk). If the text is already in the target language,
            // skip translation to avoid garbled double-translation.
            let crossCheck = NLLanguageRecognizer()
            crossCheck.processString(String(text.prefix(500)))
            let actualLang = (crossCheck.dominantLanguage?.rawValue ?? "").components(separatedBy: "-").first ?? ""
            if !actualLang.isEmpty && actualLang == targetBase {
                return .skipped("text already in target '\(targetBase)' — Whisper silent translation detected (audio: '\(detectedBase)')")
            }
        } else {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(text.prefix(500)))
            let dominantRaw = recognizer.dominantLanguage?.rawValue ?? "?"
            detectedBase = dominantRaw.components(separatedBy: "-").first ?? dominantRaw
            vfLog("[translation] source language from NLLanguageRecognizer: '\(detectedBase)'")
        }

        if detectedBase == targetBase {
            return .skipped("already in '\(target)' (source: '\(detectedBase)')")
        }

        guard let translated = await AppleTranslationService.shared.translate(text, to: target) else {
            return .failed(String(localized: "Translation service unavailable."))
        }
        let changed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                    != text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !changed {
            return .skipped("service returned same text")
        }
        return .applied(translated)
    }

    /// Final leg of every dictation cycle. Hands the result to the HUDCoordinator
    /// and resets state to `.idle`. This is the SINGLE exit point so the state
    /// machine can't drift into partial states.
    private func finishCycle(result: DictationResult) {
        HUDCoordinator.shared.dictationCompleted(result: result)
        state = .idle
    }

    // MARK: - ReviewHUD public helpers

    /// Translate text on behalf of the ReviewHUD (e.g. when the user changes the target language).
    func translateText(_ text: String, to targetLang: String) async -> String? {
        return await AppleTranslationService.shared.translate(text, to: targetLang)
    }

    /// Fonte única para a tradução do ditado: persiste a config E re-processa o
    /// último resultado, para que o ReviewHUD e a "Última digitação" no popover
    /// fiquem sempre prontos a copiar com (ou sem) a tradução escolhida —
    /// independentemente de o controlo ter sido mexido no menu bar ou no HUD.
    @MainActor
    func setDictationTranslation(enabled: Bool, target: String) async {
        var s = loadSettings()
        s.autoTranslateEnabled = enabled
        if enabled, !target.isEmpty { s.autoTranslateTargetLanguage = target }
        saveSettings(s)
        await reprocessLastResultTranslation(enabled: enabled, target: enabled ? target : "")
    }

    /// Re-traduz (ou remove a tradução de) `lastResult` in-place, a partir do
    /// texto formatado no idioma original. Desativar é instantâneo (sem chamada
    /// ao serviço); ativar/mudar idioma faz uma tradução.
    @MainActor
    func reprocessLastResultTranslation(enabled: Bool, target: String) async {
        guard var r = lastResult, case .success = r.outcome else { return }

        // Texto formatado no idioma de origem — nunca o já traduzido.
        let formattedOriginal = (r.wasTranslated ? r.preTranslationText : nil) ?? r.correctedText

        if enabled, !target.isEmpty {
            // Já está no idioma certo → nada a fazer.
            if r.wasTranslated, r.translatedToLanguage == target { return }
            guard let translated = await translateText(formattedOriginal, to: target),
                  !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            r.preTranslationText   = formattedOriginal
            r.correctedText        = translated
            r.wasTranslated        = true
            r.translatedToLanguage = target
            r.translationErrorMessage = nil
        } else {
            // Remover tradução → voltar ao texto formatado original.
            guard r.wasTranslated else { return }
            r.correctedText        = formattedOriginal
            r.wasTranslated        = false
            r.translatedToLanguage = ""
        }
        lastResult = r
    }

    /// Re-inject text from the ReviewHUD into the currently focused app.
    @MainActor
    func reInjectFromReview(_ text: String) {
        let injector = TextInjector()
        _ = injector.inject(text: text, precapturedElement: nil, targetApp: nil)
    }

    /// Converts full Whisper/Groq language names ("Portuguese", "English") to BCP-47 base codes
    /// ("pt", "en") so they can be used by LiveSpeechRecognizer's locale matching.
    /// Unknown names are returned lowercased as-is — they just won't start the live recognizer.
    private static func normalizeWhisperLang(_ raw: String) -> String {
        let lower = raw.lowercased()
        // Already looks like a BCP-47 code (e.g. "pt", "pt-BR", "zh-CN")
        if !lower.contains(" ") && lower.count <= 6 { return lower }
        let map: [String: String] = [
            "afrikaans": "af",  "albanian": "sq",    "amharic": "am",
            "arabic": "ar",     "armenian": "hy",    "azerbaijani": "az",
            "basque": "eu",     "belarusian": "be",  "bengali": "bn",
            "bosnian": "bs",    "bulgarian": "bg",   "burmese": "my",
            "catalan": "ca",    "chinese": "zh",     "croatian": "hr",
            "czech": "cs",      "danish": "da",      "dutch": "nl",
            "english": "en",    "estonian": "et",    "filipino": "tl",
            "finnish": "fi",    "french": "fr",      "galician": "gl",
            "georgian": "ka",   "german": "de",      "greek": "el",
            "gujarati": "gu",   "haitian creole": "ht", "hebrew": "he",
            "hindi": "hi",      "hungarian": "hu",   "icelandic": "is",
            "indonesian": "id", "italian": "it",     "japanese": "ja",
            "kannada": "kn",    "kazakh": "kk",      "khmer": "km",
            "korean": "ko",     "lao": "lo",         "latvian": "lv",
            "lithuanian": "lt", "macedonian": "mk",  "malay": "ms",
            "malayalam": "ml",  "maltese": "mt",     "maori": "mi",
            "marathi": "mr",    "mongolian": "mn",   "nepali": "ne",
            "norwegian": "no",  "pashto": "ps",      "persian": "fa",
            "polish": "pl",     "portuguese": "pt",  "punjabi": "pa",
            "romanian": "ro",   "russian": "ru",     "serbian": "sr",
            "sinhala": "si",    "slovak": "sk",      "slovenian": "sl",
            "somali": "so",     "spanish": "es",     "swahili": "sw",
            "swedish": "sv",    "tagalog": "tl",     "tajik": "tg",
            "tamil": "ta",      "telugu": "te",      "thai": "th",
            "turkish": "tr",    "ukrainian": "uk",   "urdu": "ur",
            "uzbek": "uz",      "vietnamese": "vi",  "welsh": "cy",
            "yoruba": "yo",     "zulu": "zu",
        ]
        return map[lower] ?? lower
    }

    /// Produce a human-readable message for log + ReviewHUD error banner.
    private func describeError(_ error: Error) -> String {
        if let e = error as? WhisperError { return e.localizedDescription }
        if let e = error as? LicenseError { return e.localizedDescription }
        if let e = error as? URLError { return e.localizedDescription }
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) #\(ns.code)]"
    }

    /// Returns true if the error is a transient server-side failure (HTTP 5xx or timeout)
    /// that warrants an automatic retry without user intervention.
    private func isTransientHTTPError(_ error: Error) -> Bool {
        if let whisper = error as? WhisperError {
            switch whisper {
            case .apiError(let msg):
                // Matches "HTTP 500", "HTTP 502", "HTTP 503", "HTTP 504" etc.
                return msg.hasPrefix("HTTP 5")
            case .timeout, .networkError:
                return true
            default:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return false // not transient — user connectivity issue, don't retry silently
            default:
                return false
            }
        }
        return false
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
    internal nonisolated static func removeWhisperNoiseTokens(_ input: String) -> String {
        var text = input

        // ── 1. Bracket/paren sound annotations ───────────────────────────────
        // Removes: [Música], (risos), [Som de fundo], etc.
        let bracketPattern = try? NSRegularExpression(
            pattern: #"[\[\(][^\]\)]{1,60}[\]\)]"#,
            options: [.caseInsensitive]
        )
        if let regex = bracketPattern {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        }

        // ── 2. Caption/subtitle credit hallucinations ─────────────────────────
        // Whisper emits these when given silence or very short ambient-noise audio.
        // Patterns mirror the Worker's hallucination filter so both paths agree.
        let captionPatterns: [String] = [
            #"^[♪♫\s]+$"#,
            #"^\.{2,}$"#,
            #"^…+$"#,
            #"^legendas?\s*[:por\-].*$"#,
            #"^legendado\s+por\b.*$"#,
            #"^legendaç[aã]o\s*[:por].*$"#,
            #"^(tradução|revisão|transcrição)\s*[:por].*$"#,
            #"^subtitles?\s*(by|:).*$"#,
            #"^(obrigado|obrigada)\s+por\s+(assistir|ver|acompanhar).*$"#,
            #"^thanks?\s+for\s+watching.*$"#,
            #"^(amara\.org|dotsub\.com).*$"#,
        ]
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in captionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern,
                                                     options: [.caseInsensitive, .anchorsMatchLines]),
               regex.firstMatch(in: normalized,
                                range: NSRange(normalized.startIndex..., in: normalized)) != nil {
                return ""  // entire output is a hallucination — discard
            }
        }

        // ── 3. Whisper tail hallucinations ───────────────────────────────────
        // Em gravações longas o Whisper "alucina" texto no final: créditos de vídeo,
        // nomes de produtos, fragmentos curtos. Dois padrões mais comuns:

        // (a) Fragmento 1-4 chars após pontuação terminal: "...Claude. eo"
        //     "eo" é um artefacto muito frequente do Whisper.
        if let regex = try? NSRegularExpression(pattern: #"(?<=[.!?…])\s+[a-z]{1,4}\s*$"#) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // (b) Lista de 4+ nomes próprios separados por vírgulas após pontuação terminal.
        //     Padrão: "...funcionamento? Ekey, AAcross, Mautis, Spit, Claude."
        //     Cada item começa com maiúscula, separados só por vírgulas (sem artigos/preposições).
        //     Requer 4+ itens para evitar falsos positivos com listas legítimas de 3 itens.
        if let regex = try? NSRegularExpression(
            pattern: #"(?<=\w[.!?])\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚ][A-Za-zÁÀÂÃÉÊÍÓÔÕÚÜÇáàâãéêíóôõúüç]*(?:,\s*[A-ZÁÀÂÃÉÊÍÓÔÕÚ][A-Za-zÁÀÂÃÉÊÍÓÔÕÚÜÇáàâãéêíóôõúüç]*){3,}\.?\s*$"#
        ) {
            let range = NSRange(text.startIndex..., in: text)
            let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            if stripped.count < text.count {
                text = stripped.trimmingCharacters(in: .whitespaces)
            }
        }

        // (c) Removed — trailing filler detection delegated to the LLM formatting
        //     prompt, which handles these patterns dynamically with semantic context.

        // ── 4. Cleanup leftover whitespace ────────────────────────────────────
        text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        return text
    }

    private func showError(_ message: String) {
        state = .error(message)
        vfLog("[showError] \(message)")
        // Voltar ao idle após errorResetSeconds
        let seconds = Constants.errorResetSeconds
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
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
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings.defaults
        }
        if settings.migrateIfNeeded() {
            vfLog("AppSettings — migrated to schema v\(AppSettings.currentSchemaVersion)")
            saveSettings(settings)
        }
        return settings
    }

    func saveSettings(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
        currentSettings = settings
    }
}
