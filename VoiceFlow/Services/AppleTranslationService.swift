import Foundation
#if canImport(Translation)
import Translation
#endif

// On-device translation using Apple's Translation framework.
// TranslationSession(installedSource:target:) requires macOS 26 (Tahoe).
// On macOS 14–25 translation returns nil silently — callers handle this gracefully.
final class AppleTranslationService {
    static let shared = AppleTranslationService()
    private init() {}

    func translate(_ text: String, to targetLanguage: String) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if #available(macOS 26, *) {
            return await translateNative(text: trimmed, to: targetLanguage)
        }
        vfLog("AppleTranslationService — requires macOS 26+, skipping")
        return nil
    }

    @available(macOS 26, *)
    private func translateNative(text: String, to targetLanguage: String) async -> String? {
#if canImport(Translation)
        let target = Locale.Language(identifier: targetLanguage)
        let source = Locale.current.language
        let session = TranslationSession(installedSource: source, target: target)
        do {
            let response = try await session.translate(text)
            let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { return nil }
            vfLog("AppleTranslationService — OK (\(text.prefix(20))… → \(result.prefix(20))…)")
            return result
        } catch {
            vfLog("AppleTranslationService — error: \(error)")
            return nil
        }
#else
        return nil
#endif
    }
}
