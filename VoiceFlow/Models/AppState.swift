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
        case .recording:      return String(localized: "Listening…")
        case .processing:     return String(localized: "Transcribing…")
        case .injecting:      return String(localized: "Inserting text…")
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

    // Push-to-talk threshold — unified PTT+Toggle, always active, not configurable
    // tap < pttThresholdMs ms = toggle, hold ≥ pttThresholdMs ms = PTT
    static let pttThresholdMs: Double = 500

    // Interface language: "system" = follow OS, otherwise BCP-47 tag (e.g. "pt", "en", "fr")
    var interfaceLanguage: String = "system"

    // Paragraph auto-formatting (LLM post-processing)
    var autoparagraphEnabled: Bool = true

    // Quick-access language in popup
    var dictationLanguage: String = "auto"
    var ttsLanguage: String = "auto"
    var autoTranslateEnabled: Bool = false
    var autoTranslateTargetLanguage: String = "en"

    // Local transcription
    var transcriptionEngine: TranscriptionEngine = .cloud
    var localModel: LocalWhisperModel = .small

    // BYOK provider
    var byokProvider: BYOKProvider = .openai

    // Read Selection (TTS)
    var ttsHotkeyEnabled: Bool = false
    var ttsHotkeyKeyCode: UInt32 = 37    // L key
    var ttsHotkeyModifiers: UInt32 = 768 // ⌘⇧
    var ttsVoiceIdentifier: String = ""  // "" = voz padrão do sistema

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

// MARK: - Transcription Engine

enum TranscriptionEngine: String, Codable {
    case cloud  // trial/pro via proxy, or BYOK via OpenAI
    case local  // on-device via WhisperKit (free, unlimited, offline)
}

enum LocalWhisperModel: String, Codable, CaseIterable {
    case tiny       = "openai_whisper-tiny"
    case base       = "openai_whisper-base"
    case small      = "openai_whisper-small"
    case largeTurbo = "openai_whisper-large-v3_turbo"

    var displayName: String {
        switch self {
        case .tiny:       return "Tiny"
        case .base:       return "Base"
        case .small:      return "Small"
        case .largeTurbo: return "Large Turbo"
        }
    }

    var sizeMB: Int {
        switch self {
        case .tiny:       return 75
        case .base:       return 140
        case .small:      return 466
        case .largeTurbo: return 1500
        }
    }

    var sizeLabel: String {
        sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000.0) : "\(sizeMB) MB"
    }

    var typicalLatency: String {
        switch self {
        case .tiny:       return "< 1s"
        case .base:       return "≈ 1s"
        case .small:      return "≈ 2s"
        case .largeTurbo: return "≈ 8s"
        }
    }

    /// 1 (slowest) → 4 (fastest)
    var speedRank: Int {
        switch self {
        case .tiny:       return 4
        case .base:       return 3
        case .small:      return 2
        case .largeTurbo: return 1
        }
    }

    /// 1 (worst) → 4 (best)
    var qualityRank: Int {
        switch self {
        case .tiny:       return 1
        case .base:       return 2
        case .small:      return 3
        case .largeTurbo: return 4
        }
    }
}

// MARK: - BYOK Provider

enum BYOKProvider: String, Codable {
    case openai
    case groq

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .groq:   return "Groq"
        }
    }

    var keyPrefix: String {
        switch self {
        case .openai: return "sk-"
        case .groq:   return "gsk_"
        }
    }

    var endpoint: URL {
        switch self {
        case .openai: return URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .groq:   return URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        }
    }

    var model: String {
        switch self {
        case .openai: return "whisper-1"
        case .groq:   return "whisper-large-v3-turbo"
        }
    }

    var docsURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .groq:   return URL(string: "https://console.groq.com/keys")!
        }
    }

    var costLabel: String {
        switch self {
        case .openai: return "OpenAI charges $0.006 USD/min."
        case .groq:   return "Groq has a generous free tier. Check console.groq.com for limits."
        }
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
