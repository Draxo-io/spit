import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - TTSService
// Lê texto em voz alta.
// Estratégia de voz:
//   NSSpeechSynthesizer nativo (gratuito, offline, sem chave)
//
// Estratégia para obter o texto:
//   1. kAXSelectedTextAttribute via Accessibility API (nativo, sem clipboard)
//   2. Fallback: simula Cmd+C e lê o clipboard (funciona em qualquer app)

// MARK: - ReadingPhase

enum ReadingPhase: Equatable {
    case idle
    case processing    // a aguardar resposta da API TTS
    case translating   // a traduzir o texto antes de ler
    case playing
    case paused
    case failed(String) // AI TTS falhou — mostra mensagem e auto-dispensa
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

    // MARK: - Native synthesizer (system voice)

    private let synthesizer: NSSpeechSynthesizer

    /// "" = voz padrão do sistema
    var voiceIdentifier: String = ""

    /// Default rate from the synthesizer — captured once at init
    private var baseRate: Float = 175.0

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
        synthesizer = NSSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
        if let rate = (try? synthesizer.object(forProperty: .rate)) as? Float {
            baseRate = rate
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
            synthesizer.stopSpeaking()
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

        await MainActor.run { speakNative(textToSpeak) }
    }

    func stop() {
        stopAll()
    }

    func pause() {
        guard isSpeaking && !isPaused else { return }
        synthesizer.pauseSpeaking(at: .wordBoundary)
        isPaused = true
        readingPhase = .paused
        vfLog("TTSService — paused")
    }

    func resume() {
        guard isSpeaking && isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
        readingPhase = .playing
        vfLog("TTSService — resumed")
    }

    func setSpeed(_ multiplier: Float) {
        speedMultiplier = multiplier
        if isSpeaking {
            try? synthesizer.setObject(NSNumber(value: baseRate * multiplier), forProperty: .rate)
        }
        vfLog("TTSService — speed set to \(multiplier)x")
    }

    // MARK: - Native voice (must be called from main thread)

    private func speakNative(_ text: String) {
        applyVoiceAndRate()
        isSpeaking = synthesizer.startSpeaking(text)
        isPaused = false
        vfLog("TTSService — native voice isSpeaking:\(isSpeaking)")
        if isSpeaking {
            readingPhase = .playing
            playbackStartedAt = Date()
            startPlaybackKeyMonitor()
            ReadingHUDWindowController.shared.show()
        } else {
            readingPhase = .idle
            ReadingHUDWindowController.shared.dismiss()
        }
    }

    // MARK: - Stop all (safe to call from any thread)

    private func stopAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.synthesizer.stopSpeaking()
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

    private func applyVoiceAndRate() {
        if voiceIdentifier.isEmpty {
            synthesizer.setVoice(nil)
        } else {
            synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier))
        }
        if let rate = (try? synthesizer.object(forProperty: .rate)) as? Float {
            baseRate = rate
        }
        if speedMultiplier != 1.0 {
            try? synthesizer.setObject(NSNumber(value: baseRate * speedMultiplier), forProperty: .rate)
        }
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

// MARK: - NSSpeechSynthesizerDelegate

extension TTSService: NSSpeechSynthesizerDelegate {
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
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
