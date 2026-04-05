import Foundation
import Combine

// MARK: - Estado da App

enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case injecting
    case error(String)

    var displayName: String {
        switch self {
        case .idle:           return String(localized: "Ready")
        case .recording:      return String(localized: "Recording...")
        case .processing:     return String(localized: "Processing...")
        case .injecting:      return String(localized: "Inserting text...")
        case .error(let msg): return String(format: String(localized: "Error: %@"), msg)
        }
    }

    var menuBarIcon: String {
        switch self {
        case .idle:        return "waveform"
        case .recording:   return "waveform.badge.microphone"
        case .processing:  return "ellipsis.circle"
        case .injecting:   return "checkmark.circle"
        case .error:       return "exclamationmark.triangle"
        }
    }
}

// MARK: - Resultado de Ditação

struct DictationResult {
    let originalText: String
    var correctedText: String
    let duration: TimeInterval
    let timestamp: Date
    var pastedViaClipboard: Bool = false  // true = no focused field detected, used clipboard fallback

    init(text: String, duration: TimeInterval) {
        self.originalText = text
        self.correctedText = text
        self.duration = duration
        self.timestamp = Date()
    }
}

// MARK: - Configurações

struct AppSettings: Codable {
    var language: String = "auto"
    var hotkeyKeyCode: UInt32 = 2    // D
    var hotkeyModifiers: UInt32 = 768 // Cmd + Shift
    var showReviewHUD: Bool = true
    var playSoundFeedback: Bool = true
    var autoDetectFocus: Bool = true
    var freeTrialMinutesUsed: Double = 0
    var freeTrialMinutesTotal: Double = 60  // 60 min free trial

    // Silence auto-stop
    var silenceAutoStopEnabled: Bool = true
    var silenceAutoStopSeconds: Double = 2.0  // seconds of silence before auto-stopping

    // Push-to-talk
    var pttEnabled: Bool = false
    var pttKeyCode: UInt32 = 96     // F5
    var pttModifiers: UInt32 = 0    // sem modificadores por defeito

    // Interface language: "system" = follow OS, otherwise BCP-47 tag (e.g. "pt", "en", "fr")
    var interfaceLanguage: String = "system"

    static let defaults = AppSettings()

    // Quick load just the interface language — used before UI initialises
    static func loadInterfaceLanguage() -> String {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return "system"
        }
        return settings.interfaceLanguage
    }
}

// MARK: - Entrada de Vocabulário

struct VocabularyEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var wrong: String    // Como o Whisper costuma transcrever (vazio se hintOnly)
    var correct: String  // Como deve ficar / termo a reconhecer
    var caseSensitive: Bool = false
    var hintOnly: Bool = false  // true = só envia ao Whisper como contexto, sem substituição automática
}
