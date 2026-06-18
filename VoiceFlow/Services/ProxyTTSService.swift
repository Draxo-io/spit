import Foundation

// ProxyTTSService removed in v2.0 (local-only app).
// File kept for Xcode project compatibility.
// TTSVoice and TTSError kept for build compatibility.

class ProxyTTSService {
    static let shared = ProxyTTSService()
    private init() {}
}

// MARK: - TTSVoice
// AI voices removed in v2.0. All voices now use native NSSpeechSynthesizer.
// Old AI voice names decode from UserDefaults but behave identically to .system.

enum TTSVoice: String, CaseIterable, Codable {
    case system   // native macOS NSSpeechSynthesizer (default)
    case alloy    // kept for UserDefaults decode compat — treated as system
    case echo
    case fable
    case onyx
    case nova
    case shimmer

    var displayName: String {
        NSLocalizedString("System Voice", comment: "")
    }

    // Always false in v2.0 — all voices route to native speech.
    var isAI: Bool { false }
}

// MARK: - TTSError

enum TTSError: LocalizedError {
    case invalidResponse
    case unauthorized
    case limitReached
    case apiError(String)
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:  return "Invalid TTS response."
        case .unauthorized:     return "TTS error."
        case .limitReached:     return "TTS usage limit."
        case .apiError(let m):  return m
        case .playbackFailed:   return "Could not play audio."
        }
    }
}
