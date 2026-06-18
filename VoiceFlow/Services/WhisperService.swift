import Foundation

// MARK: - WhisperError
// Shared error type used by LocalWhisperService and ProxyTranscriptionService.

enum WhisperError: LocalizedError {
    case noAPIKey
    case fileTooLarge
    case networkError(Error)
    case noInternet
    case timeout
    case unauthorized         // 401 — invalid or expired key
    case rateLimited          // 429 — too many requests
    case apiError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured. Go to Settings to add your OpenAI key."
        case .fileTooLarge:
            return "Audio too long (max 25 MB). Try a shorter dictation."
        case .noInternet:
            return "No internet connection. Check your network and try again."
        case .timeout:
            return "Request timed out. Check your connection and try again."
        case .unauthorized:
            return "Invalid API key. Go to Settings and update your OpenAI key."
        case .rateLimited:
            return "Too many requests. Wait a moment and try again."
        case .networkError(let e):
            return "Network error: \(e.localizedDescription)"
        case .apiError(let msg):
            return "API error: \(msg)"
        case .invalidResponse:
            return "Invalid API response."
        }
    }
}

// MARK: - Shared response types

struct WhisperResponse: Codable {
    let text: String
}

struct WhisperVerboseResponse: Codable {
    let text: String
    let language: String?
}

// Result returned to callers — text + detected language as a locale identifier (e.g. "pt", "en")
struct WhisperResult {
    let text: String
    let detectedLanguage: String?

    /// Maps Whisper's full language name to an AppSettings-compatible locale string
    static func localeIdentifier(from whisperLanguage: String?) -> String? {
        guard let lang = whisperLanguage?.lowercased() else { return nil }
        let map: [String: String] = [
            "portuguese": "pt",
            "english":    "en",
            "spanish":    "es",
            "french":     "fr",
            "german":     "de",
            "italian":    "it",
            "dutch":      "nl",
            "russian":    "ru",
            "chinese":    "zh",
            "japanese":   "ja",
            "korean":     "ko",
            "arabic":     "ar",
            "hindi":      "hi",
            "turkish":    "tr",
            "polish":     "pl",
            "swedish":    "sv",
            "norwegian":  "no",
            "danish":     "da",
            "finnish":    "fi",
        ]
        return map[lang]
    }
}

struct WhisperAPIError: Codable {
    struct ErrorDetail: Codable {
        let message: String
        let type: String?
    }
    let error: ErrorDetail
}

// MARK: - WhisperService
// Stub — open-source v2.0. Cloud/BYOK transcription removed.
// All transcription is handled by LocalWhisperService (on-device WhisperKit).

class WhisperService {
    func transcribe(audioURL: URL, language: String, apiKey: String, vocabularyHint: String,
                    endpoint: URL? = nil, model: String? = nil) async throws -> WhisperResult {
        throw WhisperError.noAPIKey
    }
}
