import Foundation

// MARK: - TranslationService
// Translates dictated text to a target language.
// Uses the same LLM API key as TextFormattingService:
//   - OpenAI key → GPT-4o-mini
//   - Groq key   → llama-3.1-8b-instant
//   - Local STT  → dedicated "spit-llm-key"
//
// Returns nil if no key is available (caller uses original text).

final class TranslationService {

    static let shared = TranslationService()
    private init() {}

    // MARK: - Translate

    /// Translates `text` to `targetLanguage` (BCP-47, e.g. "en", "pt", "es").
    /// Returns `nil` when the feature is unavailable (no key, network error, etc.).
    func translate(_ text: String,
                   to targetLanguage: String,
                   settings: AppSettings) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let (apiKey, endpoint, model) = resolveKeyAndEndpoint(settings: settings) else {
            vfLog("TranslationService — no key available, skipping")
            return nil
        }

        let languageName = Locale.current.localizedString(forIdentifier: targetLanguage)
            ?? targetLanguage

        let prompt = """
Translate the following text to \(languageName). Return ONLY the translated text, no explanation.

Text:
\(text)
"""

        do {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 20

            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "user", "content": prompt]
                ],
                "max_tokens": 2048,
                "temperature": 0
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                vfLog("TranslationService — HTTP error: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let json = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let translated = json.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            vfLog("TranslationService — translated to \(targetLanguage): \(translated?.count ?? 0) chars")
            return translated

        } catch {
            vfLog("TranslationService — error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Resolve credentials

    private func resolveKeyAndEndpoint(settings: AppSettings) -> (key: String, endpoint: URL, model: String)? {
        switch settings.transcriptionEngine {
        case .cloud:
            if settings.byokProvider == .openai,
               let key = KeychainManager.shared.getAPIKey(), !key.isEmpty {
                return (key,
                        URL(string: "https://api.openai.com/v1/chat/completions")!,
                        "gpt-4o-mini")
            } else if settings.byokProvider == .groq,
                      let key = KeychainManager.shared.getGroqKey(), !key.isEmpty {
                return (key,
                        URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                        "llama-3.1-8b-instant")
            }
            return nil

        case .local:
            if let key = KeychainManager.shared.getString(account: "spit-llm-key"), !key.isEmpty {
                if key.hasPrefix("sk-") {
                    return (key,
                            URL(string: "https://api.openai.com/v1/chat/completions")!,
                            "gpt-4o-mini")
                } else if key.hasPrefix("gsk_") {
                    return (key,
                            URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
                            "llama-3.1-8b-instant")
                }
            }
            return nil
        }
    }

    // MARK: - Response models

    private struct ChatCompletionResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String }
    }
}
