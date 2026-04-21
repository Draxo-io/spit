import Foundation
import NaturalLanguage

// MARK: - TranslationService
// Translates text to a target language.
//
// Resolution order:
//   1. BYOK key (OpenAI/Groq) → call directly
//   2. Local engine with spit-llm-key → call directly
//   3. Trial/Pro plan → route through Spit proxy (/translate endpoint)
//
// Returns nil if translation is unavailable.
//
// ── HALLUCINATION GUARDS ──────────────────────────────────────────────────
// LLMs (especially via the proxy) sometimes misinterpret the transcribed
// text as a prompt and produce an ANSWER instead of a translation — e.g.
// user dictates "resuma as minhas acções" and gets back fabricated numbers.
// All translations pass through `isPlausibleTranslation()` which rejects:
//   • Output > 1.8× input length (legitimate translation rarely expands
//     this much; answers usually do).
//   • Output clearly NOT in the requested target language (NLLanguageRecognizer).
// When a guard fails, the translation is discarded and the controller
// pastes the original transcription instead.

final class TranslationService {

    static let shared = TranslationService()
    private init() {}

    /// Max acceptable ratio of translated.length / source.length.
    /// Translations between common Latin-script languages stay under 1.5×.
    /// We use 1.8× to give some margin (e.g. pt → de can expand words).
    private static let maxLengthRatio: Double = 1.8

    // MARK: - Translate

    /// Translates `text` to `targetLanguage` (BCP-47, e.g. "en", "pt", "es").
    /// Returns `nil` when the feature is unavailable (no key, network error, etc.)
    /// **or when the output fails plausibility guards** (hallucination detected).
    func translate(_ text: String,
                   to targetLanguage: String,
                   settings: AppSettings) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let plan = await MainActor.run { LicenseManager.shared.plan }

        // Attempt direct LLM call (BYOK / spit-llm-key)
        if let (apiKey, endpoint, model) = resolveKeyAndEndpoint(settings: settings) {
            if let result = await translateViaLLM(text, to: targetLanguage,
                                                  apiKey: apiKey, endpoint: endpoint, model: model),
               isPlausibleTranslation(source: text, translated: result, target: targetLanguage) {
                return result
            }
            // Direct call failed — for trial/pro users fall through to proxy as safety net
            if plan == .trial || plan == .pro {
                vfLog("TranslationService — direct LLM failed or implausible, trying proxy fallback")
            }
        }

        // Proxy path: always available for trial and pro (regardless of BYOK config)
        if plan == .trial || plan == .pro {
            if let result = await translateViaProxy(text, to: targetLanguage),
               isPlausibleTranslation(source: text, translated: result, target: targetLanguage) {
                return result
            }
            return nil
        }

        vfLog("TranslationService — no translation path available (plan: \(plan.rawValue))")
        return nil
    }

    // MARK: - Hallucination guards

    /// Rejects outputs that are clearly not a faithful translation.
    /// Two checks:
    ///   1. Length — translated text > `maxLengthRatio` × source length means the
    ///      LLM probably answered a question instead of translating.
    ///   2. Language — if `NLLanguageRecognizer` doesn't agree the output is in
    ///      the requested target language (high confidence), reject.
    private func isPlausibleTranslation(source: String, translated: String, target: String) -> Bool {
        let srcLen = source.trimmingCharacters(in: .whitespacesAndNewlines).count
        let outLen = translated.trimmingCharacters(in: .whitespacesAndNewlines).count

        // ── Length guard ───────────────────────────────────────────────────
        if srcLen > 0 {
            let ratio = Double(outLen) / Double(srcLen)
            if ratio > Self.maxLengthRatio {
                vfLog("⚠️ TranslationService — output too long (\(outLen) vs \(srcLen), ratio \(String(format: "%.2f", ratio))×), discarding as hallucination")
                return false
            }
        }

        // ── Language guard ─────────────────────────────────────────────────
        // Only check when target is a single base language code we can verify.
        // Use first 500 chars of output as sample — enough for high-confidence detection.
        let targetBase = target.components(separatedBy: "-").first?.lowercased() ?? target.lowercased()
        let sample = String(translated.prefix(500))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let detected = recognizer.dominantLanguage?.rawValue {
            let detectedBase = detected.components(separatedBy: "-").first?.lowercased() ?? detected.lowercased()
            // Confidence check: only reject if the recognizer is confident AND
            // the language differs. Short or mixed-script texts can confuse it.
            let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
            let confidence = hypotheses[NLLanguage(rawValue: detected)] ?? 0
            if confidence >= 0.75 && detectedBase != targetBase {
                vfLog("⚠️ TranslationService — output language '\(detectedBase)' ≠ target '\(targetBase)' (confidence \(String(format: "%.2f", confidence))), discarding as hallucination")
                return false
            }
        }

        return true
    }

    // MARK: - Direct LLM call

    private func translateViaLLM(_ text: String,
                                  to targetLanguage: String,
                                  apiKey: String,
                                  endpoint: URL,
                                  model: String) async -> String? {
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
                vfLog("TranslationService — LLM HTTP error: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let json = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let translated = json.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            vfLog("TranslationService — LLM translated to \(targetLanguage): \(translated?.count ?? 0) chars")
            return translated

        } catch {
            vfLog("TranslationService — LLM error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Proxy-based translation (trial/pro)

    private func translateViaProxy(_ text: String, to targetLanguage: String) async -> String? {
        // Retry once on transient 5xx errors (502/503/504 from overloaded upstream).
        for attempt in 1...2 {
            if let result = await translateViaProxyOnce(text, to: targetLanguage, attempt: attempt) {
                return result
            }
            // Only retry on first attempt; brief back-off before retry.
            if attempt == 1 {
                vfLog("TranslationService — retrying after transient failure (attempt \(attempt))")
                try? await Task.sleep(nanoseconds: 600_000_000)  // 600ms
            }
        }
        return nil
    }

    private func translateViaProxyOnce(_ text: String, to targetLanguage: String, attempt: Int) async -> String? {
        let baseURL = LicenseManager.apiBase

        do {
            var req = URLRequest(url: URL(string: "\(baseURL)/translate")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 20

            // Auth: JWT for pro, device_id header for trial
            if let jwt = await MainActor.run(body: { LicenseManager.shared.getJWT() }) {
                req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            } else {
                let deviceID = await MainActor.run(body: { LicenseManager.shared.deviceIdentifier() })
                req.setValue(deviceID, forHTTPHeaderField: "X-Device-ID")
            }

            let body: [String: Any] = [
                "text": text,
                "target_language": targetLanguage
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                vfLog("TranslationService — proxy: invalid response (attempt \(attempt))")
                return nil
            }

            switch http.statusCode {
            case 200:
                // Try to parse as {"translated": "..."} or as chat completion
                if let json = try? JSONDecoder().decode(ProxyTranslateResponse.self, from: data) {
                    vfLog("TranslationService — proxy translated to \(targetLanguage): \(json.translated.count) chars")
                    return json.translated
                }
                // Fallback: try chat-completion format
                if let json = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
                   let content = json.choices.first?.message.content {
                    let translated = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    vfLog("TranslationService — proxy (chat) translated to \(targetLanguage): \(translated.count) chars")
                    return translated
                }
                vfLog("TranslationService — proxy: unexpected response format (attempt \(attempt))")
                return nil

            case 404:
                // Proxy doesn't support /translate yet — not available (permanent, don't retry)
                vfLog("TranslationService — proxy /translate not available (404)")
                return nil

            case 500, 502, 503, 504:
                // Transient server error — caller will retry
                vfLog("TranslationService — proxy HTTP \(http.statusCode) (attempt \(attempt), will retry)")
                return nil

            default:
                // Permanent error (401, 403, 429, etc.) — don't retry
                vfLog("TranslationService — proxy HTTP error: \(http.statusCode) (attempt \(attempt), no retry)")
                return nil
            }

        } catch {
            vfLog("TranslationService — proxy error: \(error.localizedDescription) (attempt \(attempt))")
            return nil
        }
    }

    // MARK: - Resolve credentials (BYOK / spit-llm-key)

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

    private struct ProxyTranslateResponse: Decodable {
        let translated: String
    }
}
