import Foundation

// TranslationService replaced by AppleTranslationService in v2.0 (local-only app).
// File kept for Xcode project compatibility. All logic moved to AppleTranslationService.swift.

class TranslationService {
    static let shared = TranslationService()
    private init() {}

    func translate(_ text: String, to targetLanguage: String, settings: AppSettings) async -> String? {
        await AppleTranslationService.shared.translate(text, to: targetLanguage)
    }
}
