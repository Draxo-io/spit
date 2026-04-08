import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - TTSService
// Lê texto em voz alta usando o sintetizador de voz nativo do macOS.
// Estratégia para obter o texto:
//   1. kAXSelectedTextAttribute via Accessibility API (nativo, sem clipboard)
//   2. Fallback: simula Cmd+C e lê o clipboard (funciona em qualquer app)

final class TTSService: NSObject, ObservableObject {

    static let shared = TTSService()

    private let synthesizer: NSSpeechSynthesizer

    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var speedMultiplier: Float = 1.0

    /// "" = voz padrão do sistema
    var voiceIdentifier: String = ""

    /// Default rate from the synthesizer — captured once at init
    private var baseRate: Float = 175.0

    private override init() {
        synthesizer = NSSpeechSynthesizer()
        super.init()
        synthesizer.delegate = self
        // Capture the default rate for the system voice
        if let rate = (try? synthesizer.object(forProperty: .rate)) as? Float {
            baseRate = rate
        }
    }

    // MARK: - Public

    func speakSelection() async {
        vfLog("TTSService.speakSelection() called")

        if synthesizer.isSpeaking {
            stop()
            return
        }

        // 1. Tentar via AX
        if let text = selectedTextViaAX(), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            vfLog("TTSService — text via AX (\(text.count) chars)")
            speak(text)
            return
        }

        // 2. Fallback: simular Cmd+C e ler clipboard
        if let text = await selectedTextViaCopy(), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            vfLog("TTSService — text via Cmd+C (\(text.count) chars)")
            speak(text)
            return
        }

        vfLog("TTSService — nenhum texto encontrado (AX + clipboard)")
        NSSound.beep()   // feedback audível: hotkey funcionou mas não há seleção
    }

    func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking() }
        applyVoiceAndRate()
        isSpeaking = synthesizer.startSpeaking(text)
        isPaused = false
        vfLog("TTSService — startSpeaking:\(isSpeaking) voice:\(voiceIdentifier.isEmpty ? "system" : voiceIdentifier) speed:\(speedMultiplier)x")
        if isSpeaking {
            DispatchQueue.main.async { ReadingHUDWindowController.shared.show() }
        }
    }

    func stop() {
        synthesizer.stopSpeaking()
        isSpeaking = false
        isPaused = false
        DispatchQueue.main.async { ReadingHUDWindowController.shared.dismiss() }
    }

    func pause() {
        guard isSpeaking && !isPaused else { return }
        synthesizer.pauseSpeaking(at: .wordBoundary)
        isPaused = true
        vfLog("TTSService — paused")
    }

    func resume() {
        guard isSpeaking && isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
        vfLog("TTSService — resumed")
    }

    func setSpeed(_ multiplier: Float) {
        speedMultiplier = multiplier
        if isSpeaking {
            try? synthesizer.setObject(NSNumber(value: baseRate * multiplier), forProperty: .rate)
        }
        vfLog("TTSService — speed set to \(multiplier)x (rate: \(baseRate * multiplier))")
    }

    // MARK: - Private helpers

    private func applyVoiceAndRate() {
        if voiceIdentifier.isEmpty {
            synthesizer.setVoice(nil)
        } else {
            synthesizer.setVoice(NSSpeechSynthesizer.VoiceName(rawValue: voiceIdentifier))
        }
        // Apply speed — update baseRate for the (potentially new) voice
        if let rate = (try? synthesizer.object(forProperty: .rate)) as? Float {
            baseRate = rate
        }
        if speedMultiplier != 1.0 {
            try? synthesizer.setObject(NSNumber(value: baseRate * speedMultiplier), forProperty: .rate)
        }
    }

    // MARK: - Obter texto selecionado

    private func selectedTextViaAX() -> String? {
        guard AXIsProcessTrusted() else {
            vfLog("TTSService — AX not trusted")
            return nil
        }
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

    /// Simula Cmd+C no app em foco, espera 120 ms e lê o clipboard.
    private func selectedTextViaCopy() async -> String? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: false) else { return nil }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        try? await Task.sleep(nanoseconds: 120_000_000)  // 120 ms

        return NSPasteboard.general.string(forType: .string)
    }
}

// MARK: - NSSpeechSynthesizerDelegate

extension TTSService: NSSpeechSynthesizerDelegate {
    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isSpeaking = false
            self?.isPaused = false
            ReadingHUDWindowController.shared.dismiss()
        }
    }
}
