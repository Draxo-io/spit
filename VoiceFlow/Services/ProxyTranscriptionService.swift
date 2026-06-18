import Foundation

// ProxyTranscriptionService removed in v2.0 (local-only app).
// File kept for Xcode project compatibility.
// ProxyResult struct kept for build compatibility.

struct ProxyResult {
    let text: String
    let detectedLanguage: String?
    let seconds: Double
}

class ProxyTranscriptionService {
    func transcribe(
        audioURL: URL,
        language: String,
        vocabularyHint: String,
        qualitySettings: TextQualitySettings = TextQualitySettings()
    ) async throws -> ProxyResult {
        throw WhisperError.noInternet
    }
}
