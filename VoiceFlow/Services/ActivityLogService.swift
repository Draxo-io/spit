import Foundation

// MARK: - ActivityLogService
// No-op stub — open-source v2.0. No network calls.

final class ActivityLogService {

    static let shared = ActivityLogService()
    private init() {}

    func logDictation(
        sourceText: String,
        sourceLanguage: String?,
        outputText: String,
        outputLanguage: String?,
        injectionMethod: String,
        wasTranslated: Bool,
        durationSeconds: Double,
        reviewShown: Bool
    ) {}

    func logTTS(
        text: String,
        language: String?,
        wasTranslated: Bool
    ) {}
}
