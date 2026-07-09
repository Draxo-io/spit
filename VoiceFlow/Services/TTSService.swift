import AppKit
import ApplicationServices
import CoreGraphics
import Combine
import AVFoundation

// MARK: - TTSService
// Lê texto em voz alta.
// Estratégia de voz:
//   AVSpeechSynthesizer nativo como fallback (macOS 14+, funciona no macOS 26 Tahoe)
//   NSSpeechSynthesizer foi removido — disparava didFinishSpeaking imediatamente no macOS 26
//
// Estratégia para obter o texto:
//   1. kAXSelectedTextAttribute via Accessibility API (nativo, sem clipboard)
//   2. Fallback: simula Cmd+C e lê o clipboard (funciona em qualquer app)

// MARK: - ReadingPhase

enum ReadingPhase: Equatable {
    case idle
    case warmingUp     // primeiro uso da sessão — motor a compilar JIT (~20s)
    case reloading     // recarregamento após standby automático
    case processing    // a aguardar geração de áudio (motor já aquecido)
    case translating   // a traduzir o texto antes de ler
    case standingBy    // motor a ser descarregado por inatividade
    case playing
    case paused
    case failed(String)
}

// MARK: - TTSService

final class TTSService: NSObject, ObservableObject {

    static let shared = TTSService()

    // MARK: - Published state

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused   = false
    @Published private(set) var speedMultiplier: Float = 1.0
    @Published private(set) var readingPhase: ReadingPhase = .idle
    /// Non-nil when shown as a transient note in the Reading HUD.
    @Published private(set) var truncationNote: String? = nil

    /// Maximum chars per reading session (single key-press).
    /// 5 000 chars ≈ 5 min of audio — covers any article or email; prevents
    /// accidental abuse (selecting entire books) that would waste TTS quota.
    /// If the selected text exceeds this, only the first 5 000 chars are read.
    static let ttsSessionCap = 5_000

    // MARK: - Native synthesizer fallback (AVSpeechSynthesizer, macOS 14+)
    // Used only when Qwen3-TTS model is not yet downloaded/ready.

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - MLX Chatterbox support

    private var mlxCancellable: AnyCancellable?
    private var mlxPlayingCancellable: AnyCancellable?
    private var mlxLoadCancellable: AnyCancellable?
    private var mlxStandbyCancellable: AnyCancellable?

    // MARK: - Usage tracking (for Consumo section)
    /// Wall-clock timestamp when playback started (AI or native). nil while not playing.
    private var playbackStartedAt: Date?

    private func recordPlaybackUsage() {
        guard let start = playbackStartedAt else { return }
        let seconds = Date().timeIntervalSince(start)
        playbackStartedAt = nil
        guard seconds > 0.5 else { return }
        CreditsManager.shared.recordTTS(seconds: seconds)
        vfLog("TTSService — recorded \(Int(seconds))s of playback")
    }

    // MARK: - Playback keyboard shortcuts (Space/ESC/Arrows active only while speaking)

    private var playbackEventTap: CFMachPort?
    private var playbackRunLoopSource: CFRunLoopSource?

    private static weak var tapTarget: TTSService?

    private static let playbackTapCallback: CGEventTapCallBack = { _, type, event, _ in
        guard type == .keyDown, let tts = TTSService.tapTarget, tts.isSpeaking else {
            return Unmanaged.passUnretained(event)
        }
        let kc = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch kc {
        case 49:        // Space — pausa / retoma
            DispatchQueue.main.async { tts.isPaused ? tts.resume() : tts.pause() }
            return nil
        case 53:        // ESC — para de vez
            DispatchQueue.main.async { tts.stop() }
            return nil
        case 126, 124:  // ↑ ou → — mais rápido
            DispatchQueue.main.async { tts.setSpeed(min(tts.speedMultiplier + 0.25, 3.0)) }
            return nil
        case 125, 123:  // ↓ ou ← — mais devagar
            DispatchQueue.main.async { tts.setSpeed(max(tts.speedMultiplier - 0.25, 0.5)) }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func startPlaybackKeyMonitor() {
        guard playbackEventTap == nil else { return }
        TTSService.tapTarget = self
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: TTSService.playbackTapCallback,
            userInfo: nil
        ) else {
            vfLog("TTSService — CGEventTap não criado (sem permissão de acessibilidade)")
            return
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        playbackEventTap = tap
        playbackRunLoopSource = src
        vfLog("TTSService — playback key monitor ON")
    }

    private func stopPlaybackKeyMonitor() {
        if let tap = playbackEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = playbackRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
                playbackRunLoopSource = nil
            }
            playbackEventTap = nil
        }
        TTSService.tapTarget = nil
        vfLog("TTSService — playback key monitor OFF")
    }

    // MARK: - Init

    private override init() {
        super.init()
        synthesizer.delegate = self
        // Observa standby do motor MLX para mostrar HUD proactivo (sem interacção do utilizador).
        // Deve correr no MainActor porque MLXTTSService.shared e $state são @MainActor isolated.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.mlxStandbyCancellable = MLXTTSService.shared.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self, !self.isSpeaking else { return }
                    switch state {
                    case .standingBy:
                        self.readingPhase = .standingBy
                        ReadingHUDWindowController.shared.show()
                    case .idle where self.readingPhase == .standingBy:
                        self.readingPhase = .idle
                        ReadingHUDWindowController.shared.dismiss()
                    default:
                        break
                    }
                }
        }
    }

    // MARK: - Public

    func speakSelection() async {
        vfLog("TTSService.speakSelection() called")

        if isSpeaking {
            stop()
            return
        }

        if let text = selectedTextViaAX(), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            vfLog("TTSService — text via AX (\(text.count) chars)")
            await speak(text)
            return
        }

        if let text = await selectedTextViaCopy(), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            vfLog("TTSService — text via Cmd+C (\(text.count) chars)")
            await speak(text)
            return
        }

        vfLog("TTSService — nenhum texto encontrado (AX + clipboard)")
        NSSound.beep()
    }

    func speak(_ text: String) async {
        // Apply per-session cap — silently truncate at ttsSessionCap chars.
        // Covers articles, emails, long documents; prevents accidental book reads.
        let cappedText = text.count > Self.ttsSessionCap
            ? String(text.prefix(Self.ttsSessionCap))
            : text
        if text.count > Self.ttsSessionCap {
            vfLog("TTSService — texto truncado de \(text.count) para \(Self.ttsSessionCap) chars (per-session cap)")
        }
        await speakInternal(cappedText)
    }

    private func speakInternal(_ text: String) async {
        await MainActor.run {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
            isPaused = false
            stopPlaybackKeyMonitor()
            speedMultiplier = 1.0
            truncationNote = nil
            readingPhase = .processing
            ReadingHUDWindowController.shared.show()
        }

        let muteEnabled = loadSettings().muteAudioOnActivity
        if muteEnabled {
            await SystemAudioManager.shared.pauseMedia()
        }

        // Tradução local via Apple Translation framework (macOS 15+).
        // AppleTranslationService.swift existe no disco mas ainda não está linkado no projeto Xcode.
        // Até ser adicionado ao build target, a tradução TTS fica desactivada — texto original é lido.
        let textToSpeak = text
        let settings = loadSettings()

        if settings.ttsEngine == .chatterbox {
            let captured = textToSpeak
            let capturedSettings = settings
            await MainActor.run { self.speakWithMLX(captured, settings: capturedSettings) }
        } else {
            await MainActor.run { speakNative(textToSpeak) }
        }
    }

    // MARK: - MLX Chatterbox (must be called from main thread)

    @MainActor
    private func speakWithMLX(_ text: String, settings: AppSettings) {
        let mlx = MLXTTSService.shared

        // pt-BR: bypass MLX entirely — Qwen3-TTS has no Brazilian Portuguese codec.
        let language = settings.ttsLanguage == "auto" ? resolvedSystemTTSLanguage() : settings.ttsLanguage
        if language.lowercased() == "pt-br" {
            vfLog("TTSService — pt-BR → native Luciana (bypassing MLX warm-up)")
            speakNative(text, language: "pt-BR")
            return
        }

        // Determine initial HUD phase based on model readiness and JIT state.
        let initialPhase: ReadingPhase
        if mlx.state == .idle {
            initialPhase = mlx.hasEverBeenReady ? .reloading : .warmingUp
        } else if mlx.isReady && !mlx.hasCompletedFirstGeneration {
            initialPhase = .warmingUp
        } else if mlx.isReady {
            initialPhase = .processing
        } else {
            // Loading or error — fall back to native
            vfLog("TTSService — Chatterbox not ready (state:\(mlx.state)), falling back to system voice")
            speakNative(text)
            return
        }

        isSpeaking = true
        isPaused = false
        readingPhase = initialPhase
        startPlaybackKeyMonitor()
        ReadingHUDWindowController.shared.show()

        if mlx.state == .idle {
            // Model was unloaded — trigger reload, then speak when ready.
            let capturedText = text
            let capturedSettings = settings
            mlxLoadCancellable = mlx.$state
                .filter { $0 == .ready }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.doMLXSpeak(text: capturedText, settings: capturedSettings, mlx: mlx)
                }
            Task { await mlx.loadModel() }
            return
        }

        doMLXSpeak(text: text, settings: settings, mlx: mlx)
    }

    @MainActor
    private func doMLXSpeak(text: String, settings: AppSettings, mlx: MLXTTSService) {
        let language = settings.ttsLanguage == "auto"
            ? resolvedSystemTTSLanguage()
            : settings.ttsLanguage

        // pt-BR: Qwen3-TTS só tem um codec "portuguese" (sotaque PT).
        // Para sotaque brasileiro autêntico, usa a voz Luciana do macOS (nativa, local, sem warm-up).
        if language.lowercased() == "pt-br" {
            vfLog("TTSService — pt-BR → native Luciana voice (Qwen3-TTS has no pt-BR codec)")
            Task { @MainActor in MLXTTSService.shared.cancel() }
            mlxCancellable = nil; mlxPlayingCancellable = nil; mlxLoadCancellable = nil
            speakNative(text, language: "pt-BR")
            return
        }

        mlx.speak(text: text, language: language)

        // Muda para .playing quando o áudio começa realmente a tocar.
        mlxPlayingCancellable = mlx.$isPlayingAudio
            .filter { $0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.readingPhase = .playing
                self?.playbackStartedAt = Date()
            }

        // Detecta quando a reprodução termina (isSpeaking → false).
        mlxCancellable = mlx.$isSpeaking
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.finishMLXPlayback() }
    }

    @MainActor
    private func finishMLXPlayback() {
        recordPlaybackUsage()
        isSpeaking = false
        isPaused = false
        readingPhase = .idle
        mlxCancellable = nil
        mlxPlayingCancellable = nil
        mlxLoadCancellable = nil
        stopPlaybackKeyMonitor()
        SystemAudioManager.shared.resumeMedia()
        ReadingHUDWindowController.shared.dismiss()
    }

    private func resolvedSystemTTSLanguage() -> String {
        let iface = Locale.preferredLanguages.first ?? "en"
        return AppSettings.ttsLanguageForInterface(iface)
    }

    func stop() {
        stopAll()
    }

    func pause() {
        guard isSpeaking && !isPaused else { return }
        let settings = loadSettings()
        if settings.ttsEngine == .chatterbox {
            Task { @MainActor in MLXTTSService.shared.pause() }
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
        isPaused = true
        readingPhase = .paused
        vfLog("TTSService — paused")
    }

    func resume() {
        guard isSpeaking && isPaused else { return }
        let settings = loadSettings()
        if settings.ttsEngine == .chatterbox {
            Task { @MainActor in MLXTTSService.shared.resume() }
        } else {
            synthesizer.continueSpeaking()
        }
        isPaused = false
        readingPhase = .playing
        vfLog("TTSService — resumed")
    }

    func setSpeed(_ multiplier: Float) {
        speedMultiplier = multiplier
        // Live rate change not supported by AVSpeechSynthesizer — takes effect on next utterance
        vfLog("TTSService — speed set to \(multiplier)x")
    }

    // MARK: - Native voice fallback (AVSpeechSynthesizer, macOS 14+)

    private func speakNative(_ text: String, language: String? = nil) {
        let utterance = AVSpeechUtterance(string: text)
        // Map speedMultiplier (0.5–3.0) into AVSpeech rate range (min–max).
        let range = AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate
        utterance.rate = AVSpeechUtteranceMinimumSpeechRate + range * min(speedMultiplier / 3.0, 1.0)
        // Select voice by BCP-47 language tag when specified (e.g. "pt-BR" → Luciana).
        // AVSpeechSynthesisVoice picks the highest-quality installed voice for that locale.
        if let lang = language, let voice = AVSpeechSynthesisVoice(language: lang) {
            utterance.voice = voice
            vfLog("TTSService — native voice: \(voice.name) (\(lang))")
        }
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
        vfLog("TTSService — AVSpeechSynthesizer speaking (\(text.prefix(40))…)")
        readingPhase = .playing
        playbackStartedAt = Date()
        startPlaybackKeyMonitor()
        ReadingHUDWindowController.shared.show()
    }

    // MARK: - Stop all (safe to call from any thread)

    private func stopAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.mlxCancellable = nil
            self.mlxPlayingCancellable = nil
            self.mlxLoadCancellable = nil
            Task { @MainActor in MLXTTSService.shared.cancel() }
            self.isSpeaking = false
            self.isPaused = false
            self.truncationNote = nil
            self.readingPhase = .idle
            self.stopPlaybackKeyMonitor()
            SystemAudioManager.shared.resumeMedia()
            ReadingHUDWindowController.shared.dismiss()
        }
    }

    private func loadSettings() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return s
    }

    // MARK: - Obter texto selecionado

    func selectedTextSync() -> String? {
        return selectedTextViaAX()
    }

    func selectedTextForSmartKey() async -> String? {
        if let text = selectedTextViaAX(), !text.isEmpty { return text }

        let preCount = NSPasteboard.general.changeCount
        guard let dn = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return nil }
        dn.flags = .maskCommand
        up.flags = .maskCommand
        dn.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard NSPasteboard.general.changeCount != preCount else { return nil }
        return NSPasteboard.general.string(forType: .string)
    }

    private func selectedTextViaAX() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var rawEl: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &rawEl) == .success,
              let el = rawEl else { return nil }
        var rawVal: CFTypeRef?
        guard AXUIElementCopyAttributeValue(unsafeBitCast(el, to: AXUIElement.self),
                                             kAXSelectedTextAttribute as CFString,
                                             &rawVal) == .success,
              let text = rawVal as? String, !text.isEmpty else { return nil }
        return text
    }

    private func selectedTextViaCopy() async -> String? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        try? await Task.sleep(nanoseconds: 120_000_000)
        return NSPasteboard.general.string(forType: .string)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.recordPlaybackUsage()
            self?.isSpeaking = false
            self?.isPaused = false
            self?.readingPhase = .idle
            self?.stopPlaybackKeyMonitor()
            SystemAudioManager.shared.resumeMedia()
            ReadingHUDWindowController.shared.dismiss()
        }
    }
}
