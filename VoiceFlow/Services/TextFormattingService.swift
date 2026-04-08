import Foundation

// MARK: - TextFormattingService
// LLM post-processing: adds paragraph breaks, punctuation, and capitalisation
// to raw Whisper output based on semantic context.
//
// Key: reuses the STT API key (OpenAI → GPT-4o-mini, Groq → llama-3.1-8b-instant).
// If STT is local (WhisperKit) a separate LLM key is required — stored under "spit-llm-key".
// If no key is available, returns nil (caller uses original text).

final class TextFormattingService {

    static let shared = TextFormattingService()
    private init() {}

    // MARK: - Format

    /// Reformats `text` with paragraph breaks and punctuation via LLM.
    /// Returns `nil` if the feature is unavailable (no key, network error, etc.).
    func format(_ text: String, settings: AppSettings) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let (apiKey, endpoint, model) = resolveKeyAndEndpoint(settings: settings) else {
            vfLog("TextFormattingService — no key available, skipping")
            return nil
        }

        let prompt = """
You are a transcription formatter. You receive raw dictated text from a speech-to-text engine and must return it with proper paragraph breaks, capitalisation, and punctuation.

Rules:
- Preserve ALL words — do not add, remove, or paraphrase.
- Add paragraph breaks where the speaker changes topic or pauses naturally.
- Fix capitalisation and punctuation.
- Return ONLY the formatted text, no explanation.

Raw transcription:
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
                vfLog("TextFormattingService — HTTP error: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let json = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let formatted = json.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            vfLog("TextFormattingService — formatted \(text.count) → \(formatted?.count ?? 0) chars")
            return formatted

        } catch {
            vfLog("TextFormattingService — error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Resolve credentials

    private func resolveKeyAndEndpoint(settings: AppSettings) -> (key: String, endpoint: URL, model: String)? {
        switch settings.transcriptionEngine {
        case .cloud:
            // Reuse the STT provider key
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
            // Pro/trial plan: no BYOK key present — we can't call LLM without a key
            return nil

        case .local:
            // Local STT: requires a separate LLM key stored as "spit-llm-key"
            if let key = KeychainManager.shared.getString(account: "spit-llm-key"), !key.isEmpty {
                // Determine endpoint by key prefix
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

        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: String
        }
    }
}
