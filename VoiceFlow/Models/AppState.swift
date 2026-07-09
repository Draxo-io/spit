import Foundation
import Combine

// MARK: - Constants
// Valores centralizados. Pensados para ser sobrepostos por remote config
// puxado do backoffice (tarefa futura).

enum Constants {

    // MARK: - Network timeouts
    /// Unified timeout for LLM and transcription HTTP calls.
    static let networkTimeoutSeconds: TimeInterval = 20

    // MARK: - State recovery
    /// How long the state stays in `.error` before returning to `.idle`.
    static let errorResetSeconds: Double = 3

    // MARK: - Recording
    /// Minimum recording duration to be considered a real dictation.
    static let minimumRecordingSeconds: Double = 0.5
    /// RMS dB threshold below which audio is considered silence.
    static let silenceThresholdDB: Float = -30.0
}

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

/// Outcome of a dictation cycle — used to choose the layout of the ReviewHUD.
/// Every completed hotkey press produces one of these, even when there is no text.
enum DictationOutcome {
    /// Successful transcription with non-empty text.
    case success
    /// Recording happened but produced no text (silence, energy gate, empty after filters).
    /// The message is shown inside the ReviewHUD where the transcription would normally be.
    case empty(reason: String)
    /// Transcription itself failed (network, API error, license, etc.).
    /// The message is shown inside the ReviewHUD.
    case error(message: String)
}

struct DictationResult {
    let originalText: String          // texto injetado (traduzido se tradução ativa)
    var correctedText: String
    let duration: TimeInterval
    let timestamp: Date
    var pastedViaClipboard: Bool = false     // true = AX not trusted, text only in clipboard, user must ⌘V
    var usedKeyboardFallback: Bool = false   // true = keyboard events sent without a confirmed AX element (browsers OK, but desktop/Finder = text lost)
    var wasTranslated: Bool = false       // true = auto-translate was applied before injection
    var translatedToLanguage: String = "" // target language code, e.g. "en"
    var preTranslationText: String? = nil  // texto original antes de traduzir (para mostrar no ReviewHUD)
    var rawTranscriptionText: String? = nil // Whisper output antes do TextFormattingService (para mostrar no ReviewHUD)

    /// If non-nil, translation was attempted but failed. The original was pasted instead.
    var translationErrorMessage: String? = nil

    /// Outcome of the dictation — drives the ReviewHUD layout (success/empty/error).
    var outcome: DictationOutcome = .success

    init(text: String, duration: TimeInterval) {
        self.originalText = text
        self.correctedText = text
        self.duration = duration
        self.timestamp = Date()
    }

    /// Create a result representing an empty/error outcome (no pasted text).
    static func placeholder(outcome: DictationOutcome, duration: TimeInterval) -> DictationResult {
        var r = DictationResult(text: "", duration: duration)
        r.outcome = outcome
        return r
    }
}

// MARK: - Melhorias de Qualidade de Texto

struct TextQualitySettings: Codable {
    /// Mestre — se false, todos os filtros abaixo ficam desativados
    var enabled: Bool = true

    /// 1. Energy gate — não enviar áudio sem voz detectada.
    /// A detecção usa o live speech recognizer (mesmo sinal que o pill mostra).
    /// Desligar este toggle permite enviar mesmo sem fala detectada.
    var energyGate: Bool = true

    /// 2. Lista negra de alucinações — remove outputs gerados em silêncio/ruído
    var hallucinationFilter: Bool = true

    /// 3. Ratio check — descarta output suspeito se chars/segundo for muito alto
    var ratioCheck: Bool = true

    /// 4. Remoção de repetições — elimina frases repetidas no final
    var repetitionFilter: Bool = true

    /// 5. Filtro de fillers — remove "uh", "hmm", "eh"
    var fillerFilter: Bool = true
}

// MARK: - Configurações

struct AppSettings: Codable {
    var language: String = "auto"
    // Default: Globe (🌐, keyCode 63) — atalho oficial do Spit.
    // Não requer modificador; o CGEventTap supressivo está aprovado pela App Store
    // (risco aceite, conforme CLAUDE.md).
    // Utilizadores existentes mantêm a sua configuração guardada; este default
    // aplica-se apenas a instalações novas.
    //
    // Na build de DEV o default é ⌥ Option direito (keyCode 61) para não competir
    // com o Globe da build de produção quando ambas correm em simultâneo.
    #if DEBUG
    var hotkeyKeyCode: UInt32 = 61   // ⌥ Option direito (Dev)
    #else
    var hotkeyKeyCode: UInt32 = 63   // Globe / Fn
    #endif
    var hotkeyModifiers: UInt32 = 0  // sem modificador
    var textQuality: TextQualitySettings = TextQualitySettings()
    var playSoundFeedback: Bool = true
    var autoDetectFocus: Bool = true
    // Push-to-talk threshold — unified PTT+Toggle, always active, not configurable
    // tap < pttThresholdMs ms = toggle, hold ≥ pttThresholdMs ms = PTT
    static let pttThresholdMs: Double = 500

    // Interface language: "system" = follow OS, otherwise BCP-47 tag (e.g. "pt", "en", "fr")
    var interfaceLanguage: String = "system"

    // Paragraph auto-formatting (LLM post-processing)
    // Habilitado por defeito conforme SPEC §4.3.2. Protegido por gates de
    // plausibilidade em TextFormattingService (ver CHANGELOG 2026-04-22).
    var autoparagraphEnabled: Bool = true

    // Quick-access language in popup
    var dictationLanguage: String = "auto"
    var ttsLanguage: String = "auto"
    var autoTranslateEnabled: Bool = false
    var autoTranslateTargetLanguage: String = "en"
    var ttsAutoTranslateEnabled: Bool = AppSettings.systemTranslationLanguage != nil
    var ttsAutoTranslateTargetLanguage: String = AppSettings.systemTranslationLanguage ?? "en"

    // Local transcription
    var transcriptionEngine: TranscriptionEngine = .local

    // Read Selection (TTS)
    var ttsEnabled: Bool = true            // master toggle para leitura por voz
    var ttsHotkeyEnabled: Bool = true
    var ttsHotkeyKeyCode: UInt32 = 49    // ⌥Space — mesma tecla que ditado
    var ttsHotkeyModifiers: UInt32 = 2048  // optionKey (Carbon)
    var ttsVoiceIdentifier: String = ""  // "" = voz padrão do sistema
    var ttsVoice: TTSVoice = .nova       // AI voice for proxy/BYOK; .system = native macOS
    var ttsEngine: TTSEngine = .chatterbox // .system = NSSpeechSynthesizer; .chatterbox = MLX Qwen3-TTS
    var ttsContextMenuEnabled: Bool = true // "Ler com Spit" no clique direito
    // Inatividade do motor MLX TTS: minutos até descarregar da GPU/RAM. 0 = nunca descarregar.
    var ttsInactivityMinutes: Int = 20

    // Privacidade
    var privacyModeEnabled: Bool = false   // tudo local, sem rede

    // Sistema
    var launchAtLogin: Bool = true         // SPEC §4.1 — default Sim
    var muteAudioOnActivity: Bool = true   // mute system output while dictating or reading

    // MARK: - Schema migration
    /// Current schema version of AppSettings on disk.
    /// Bump this whenever defaults change in a way that existing installs should pick up,
    /// and add the corresponding branch in `migrateIfNeeded()`.
    static let currentSchemaVersion: Int = 7

    /// Maps interface language (BCP-47) → TTS language code supported by MLX TTS.
    /// Returns "en" when the interface language has no equivalent TTS language.
    static func ttsLanguageForInterface(_ interfaceLang: String) -> String {
        let supported: Set<String> = ["zh","en","ja","ko","fr","de","es","it","pt","pt-BR","ru","nl","pl","tr","ar","hi","uk"]
        let lower = interfaceLang.lowercased()
        // Chinese variants
        if lower.hasPrefix("zh") { return "zh" }
        // Portuguese — distinguish BR vs PT
        if lower.hasPrefix("pt-br") || lower.hasPrefix("pt_br") { return "pt-BR" }
        if lower.hasPrefix("pt") { return "pt" }
        let base = String(lower.prefix(2))
        return supported.contains(base) ? base : "en"
    }

    /// Resolves the TTS language from settings:
    /// - If ttsLanguage is set explicitly → use it
    /// - If "auto" → derive from interfaceLanguage; "system" interface → detect OS locale
    static func resolvedTTSLanguage(settings: AppSettings) -> String {
        guard settings.ttsLanguage == "auto" else { return settings.ttsLanguage }
        let iface = settings.interfaceLanguage == "system"
            ? (Locale.preferredLanguages.first ?? "en")
            : settings.interfaceLanguage
        return ttsLanguageForInterface(iface)
    }

    /// Detects the macOS system language and returns it if it's in the supported
    /// translation set (pt, pt-BR, en, es, fr, de, it). Returns nil for unsupported
    /// locales — TTS translation stays disabled rather than defaulting to a foreign language.
    static var systemTranslationLanguage: String? {
        let preferred = (Locale.preferredLanguages.first ?? "en").lowercased()
        if preferred.hasPrefix("pt") && preferred.contains("br") { return "pt-BR" }
        let lang = String(preferred.prefix(2))
        let supported: Set<String> = ["pt", "en", "es", "fr", "de", "it"]
        return supported.contains(lang) ? lang : nil
    }

    /// Optional so old JSON blobs (pre-migration) decode as `nil` and trigger migration.
    /// Fresh installs get `currentSchemaVersion` via `defaults`.
    var settingsSchemaVersion: Int? = AppSettings.currentSchemaVersion

    /// Apply migrations for existing installs so they pick up SPEC-correct defaults.
    /// Returns true if any migration was applied (caller should persist).
    mutating func migrateIfNeeded() -> Bool {
        var migrated = false
        if settingsSchemaVersion == nil {
            // Pre-v1 → v1 (2026-04-22): align defaults with SPEC §3.7 / §4.3.2.
            // Old builds shipped with autoparagraphEnabled=false.
            autoparagraphEnabled = true
            settingsSchemaVersion = 1
            migrated = true
        }
        if (settingsSchemaVersion ?? 0) < 2 {
            // v1 → v2 (2026-04-22): align with SPEC §4.1 (launchAtLogin = true default).
            // We intentionally do NOT flip users who previously unchecked it — only bump
            // existing installs that still carry the v0/v1 implicit default of `false`.
            // Since we cannot distinguish "user explicitly unchecked" from "never touched",
            // we opt for user-respectful behaviour: keep current value, only mark version.
            settingsSchemaVersion = 2
            migrated = true
        }
        if (settingsSchemaVersion ?? 0) < 3 {
            // v2 → v3 (2026-05-28): migrate hotkey from old default Option+Space to Globe.
            // Older builds shipped with hotkeyKeyCode=49 (Space) + hotkeyModifiers=2048 (Option).
            // Current SPEC default is Globe (keyCode=63, modifiers=0). Only reset users still
            // on the old default — anyone who changed from Option+Space to something else keeps
            // their custom shortcut.
            if hotkeyKeyCode == 49 && hotkeyModifiers == 2048 {
                hotkeyKeyCode  = 63   // Globe 🌐
                hotkeyModifiers = 0
            }
            settingsSchemaVersion = 3
            migrated = true
        }
        if (settingsSchemaVersion ?? 0) < 4 {
            // v3 → v4 (2026-06-01): enable TTS auto-translation to the system language by default.
            // Reading aloud in the user's own language is the natural expectation — they should
            // not need to configure this manually. We apply to ALL users (including existing)
            // because the behaviour is clearly superior and the toggle is immediately reversible
            // in the popover. Target language is derived from macOS locale.
            if let systemLang = AppSettings.systemTranslationLanguage {
                ttsAutoTranslateEnabled = true
                ttsAutoTranslateTargetLanguage = systemLang
            } else {
                ttsAutoTranslateEnabled = false   // unsupported locale — keep disabled
            }
            settingsSchemaVersion = 4
            migrated = true
        }
        if (settingsSchemaVersion ?? 0) < 5 {
            // v4 → v5 (2026-06-18): local-only open-source release.
            // Reset engine to local and TTS voice to system for all existing users.
            transcriptionEngine = .local
            ttsVoice = .system
            settingsSchemaVersion = 5
            migrated = true
        }
        if (settingsSchemaVersion ?? 0) < 6 {
            // v5 → v6 (2026-06-22): introduce Chatterbox TTS engine.
            settingsSchemaVersion = 6
            migrated = true
        }
        if (settingsSchemaVersion ?? 0) < 7 {
            // v6 → v7 (2026-06-22): switch default TTS engine to Chatterbox/Qwen3 for all users.
            // Also pre-set ttsLanguage from interface language so the picker arrives pre-selected.
            ttsEngine = .chatterbox
            if ttsLanguage == "auto" {
                ttsLanguage = AppSettings.ttsLanguageForInterface(
                    interfaceLanguage == "system"
                        ? (Locale.preferredLanguages.first ?? "en")
                        : interfaceLanguage
                )
            }
            settingsSchemaVersion = 7
            migrated = true
        }
        return migrated
    }

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

// MARK: - TTS Engine

enum TTSEngine: String, Codable {
    case system      // native NSSpeechSynthesizer (always available, lower quality)
    case chatterbox  // on-device Chatterbox via mlx-audio-swift (~1 GB, 23 languages)
}

enum LocalWhisperModel: String, Codable {
    case small = "openai_whisper-small"
}

// MARK: - Entrada de Vocabulário

struct VocabularyEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var wrong: String    // Como o Whisper costuma transcrever (vazio se hintOnly)
    var correct: String  // Como deve ficar / termo a reconhecer
    var caseSensitive: Bool = false
    var hintOnly: Bool = false  // true = só envia ao Whisper como contexto, sem substituição automática
}
