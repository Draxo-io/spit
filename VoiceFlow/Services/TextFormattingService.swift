import Foundation

// MARK: - TextFormattingService
// LLM post-processing: adds paragraph breaks, punctuation, and capitalisation
// to raw Whisper output based on semantic context.
//
// Resolution order:
//   1. BYOK key (OpenAI/Groq) → call directly
//   2. Local engine with spit-llm-key → call directly
//   3. Trial/Pro plan → route through Spit proxy (/format endpoint)
//
// Returns nil if formatting is unavailable (caller uses original text).

final class TextFormattingService {

    static let shared = TextFormattingService()
    private init() {}

    // MARK: - Format

    /// Reformats `text` with paragraph breaks and punctuation via LLM.
    /// Returns `nil` if the feature is unavailable (no key, network error, etc.).
    func format(_ text: String, settings: AppSettings) async -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Attempt direct LLM call first (BYOK / spit-llm-key)
        if let (apiKey, endpoint, model) = resolveKeyAndEndpoint(settings: settings) {
            return await formatViaLLM(text, apiKey: apiKey, endpoint: endpoint, model: model)
        }

        // Fallback: trial/pro users — route through Spit proxy
        let plan = await MainActor.run { LicenseManager.shared.plan }
        if plan == .trial || plan == .pro {
            return await formatViaProxy(text, language: settings.language)
        }

        vfLog("TextFormattingService — no key and no proxy available, skipping")
        return nil
    }

    // MARK: - Direct LLM call

    private func formatViaLLM(_ text: String,
                               apiKey: String,
                               endpoint: URL,
                               model: String) async -> String? {
        let prompt = """
You are a transcription formatter. You receive raw dictated text from a speech-to-text engine and must return it formatted and ready to send, preserving the speaker's exact words.

Rules:
- Preserve ALL words — do not add, remove, or paraphrase any content.
- Fix capitalisation and punctuation only.
- Structure the text naturally using paragraph breaks:
  • If the text opens with a greeting ("Olá João,", "Hi Maria,", "Dear…"), place it on its own line.
  • If short pleasantries follow the greeting ("bom dia, tudo bem?", "how are you?"), make them a brief separate paragraph.
  • Separate distinct topics or thoughts into their own paragraphs.
  • If the text ends with a sign-off ("Atenciosamente,", "Abraços,", "Best regards,", "Cheers,", etc.) optionally followed by a name, place it on its own line separated from the body by a blank line.
- Return ONLY the formatted text, no explanation or added commentary.

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
                vfLog("TextFormattingService — LLM HTTP error: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let json = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let formatted = json.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            vfLog("TextFormattingService — LLM formatted \(text.count) → \(formatted?.count ?? 0) chars")
            if let f = formatted, isSuspiciousOutput(f, input: text) { return nil }
            return formatted.map { applyEmailStructure($0) }

        } catch {
            vfLog("TextFormattingService — LLM error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Proxy-based formatting (trial/pro)

    private func formatViaProxy(_ text: String, language: String) async -> String? {
        let baseURL = LicenseManager.apiBase

        do {
            var req = URLRequest(url: URL(string: "\(baseURL)/format")!)
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
                "language": language
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                vfLog("TextFormattingService — proxy: invalid response")
                return nil
            }

            switch http.statusCode {
            case 200:
                let candidate: String?
                if let json = try? JSONDecoder().decode(ProxyFormatResponse.self, from: data) {
                    vfLog("TextFormattingService — proxy formatted: \(json.formatted.count) chars")
                    candidate = json.formatted
                } else if let json = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data),
                          let content = json.choices.first?.message.content {
                    let formatted = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    vfLog("TextFormattingService — proxy (chat) formatted: \(formatted.count) chars")
                    candidate = formatted
                } else {
                    vfLog("TextFormattingService — proxy: unexpected response format")
                    return nil
                }
                if let c = candidate, isSuspiciousOutput(c, input: text) { return nil }
                return candidate.map { applyEmailStructure($0) }

            case 404:
                vfLog("TextFormattingService — proxy /format not available (404)")
                return nil

            default:
                vfLog("TextFormattingService — proxy HTTP error: \(http.statusCode)")
                return nil
            }

        } catch {
            vfLog("TextFormattingService — proxy error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Resolve credentials (BYOK / spit-llm-key)

    // MARK: - Email structure

    /// Applies email-style paragraph structure to already-punctuated text.
    /// Runs client-side after LLM/proxy so it works for all plan types.
    ///
    /// Detects three zones — greeting / body / sign-off — and inserts `\n` breaks.
    /// Never adds or removes words.
    private func applyEmailStructure(_ text: String) -> String {
        // Split into sentences preserving the delimiter.
        // Pattern: split after ". " / "! " / "? " when followed by a capital letter or end-of-string.
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.contains(" ") else { return raw }   // single word — skip

        let sentences = splitSentences(raw)
        guard sentences.count >= 2 else { return raw } // one sentence — nothing to restructure

        // ── Sign-off detection ────────────────────────────────────────────────
        // Known sign-off openers (case-insensitive prefix match on first word of sentence).
        let signOffPrefixes = [
            "atenciosamente", "abraço", "abraços", "saudações", "saudação",
            "com os melhores", "com carinho", "até breve", "até logo",
            "um abraço", "muitos abraços", "beijos",
            "regards", "best regards", "kind regards", "warm regards",
            "best", "cheers", "thanks", "thank you", "yours sincerely",
            "sincerely", "att", "att.", "obrigado", "obrigada",
        ]

        var bodyEnd = sentences.endIndex
        var signOffStart = sentences.endIndex

        // Walk backwards from end looking for sign-off sentences + optional name line.
        var i = sentences.index(before: sentences.endIndex)
        while i >= sentences.startIndex {
            let s = sentences[i].trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = s.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let isSignOff = signOffPrefixes.contains(where: { lower.hasPrefix($0) })
            // A very short sentence (≤ 3 words) right after a sign-off = name line
            let wordCount = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            let isNameLine = (signOffStart < sentences.endIndex) && wordCount <= 3

            if isSignOff || isNameLine {
                signOffStart = i
                bodyEnd = i
            } else {
                break
            }
            if i == sentences.startIndex { break }
            i = sentences.index(before: i)
        }

        // ── Greeting detection ────────────────────────────────────────────────
        let greetingPrefixes = [
            "olá", "ola", "oi", "caro", "cara", "prezado", "prezada",
            "dear", "hi", "hello", "hey",
            "bom dia", "boa tarde", "boa noite",
        ]

        var greetingEnd = sentences.startIndex  // exclusive; 0 means no greeting found
        var pleasantriesEnd = sentences.startIndex

        if !sentences.isEmpty {
            let first = sentences[sentences.startIndex]
                .lowercased().trimmingCharacters(in: .punctuationCharacters)
            let isGreeting = greetingPrefixes.contains(where: { first.hasPrefix($0) })

            if isGreeting {
                greetingEnd = sentences.index(after: sentences.startIndex)

                // Check if sentence immediately after greeting is a pleasantry
                // (short ≤ 10 words, contains wellbeing/greeting words or is a question)
                let pleasantryWords = ["bom dia", "boa tarde", "boa noite", "tudo bem",
                                       "como vai", "como estás", "como está", "como estão",
                                       "espero que", "how are you", "hope you", "good morning",
                                       "good afternoon", "good evening"]
                if greetingEnd < bodyEnd {
                    let second = sentences[greetingEnd]
                    let secondLower = second.lowercased().trimmingCharacters(in: .punctuationCharacters)
                    let secondWordCount = second.components(separatedBy: .whitespaces)
                        .filter { !$0.isEmpty }.count
                    let isPleasantry = secondWordCount <= 10 &&
                        (pleasantryWords.contains(where: { secondLower.contains($0) })
                         || second.hasSuffix("?"))
                    if isPleasantry {
                        pleasantriesEnd = sentences.index(after: greetingEnd)
                    } else {
                        pleasantriesEnd = greetingEnd
                    }
                } else {
                    pleasantriesEnd = greetingEnd
                }
            }
        }

        // ── Reassemble ───────────────────────────────────────────────────────
        let hasGreeting     = greetingEnd > sentences.startIndex
        let hasPleasantries = pleasantriesEnd > greetingEnd
        let hasSignOff      = signOffStart < sentences.endIndex
        let bodyRange       = pleasantriesEnd..<bodyEnd

        // If nothing special detected, return unchanged.
        guard hasGreeting || hasSignOff else { return raw }

        var parts: [String] = []

        if hasGreeting {
            parts.append(sentences[sentences.startIndex..<greetingEnd].joined(separator: " "))
        }
        if hasPleasantries {
            parts.append(sentences[greetingEnd..<pleasantriesEnd].joined(separator: " "))
        }
        if !bodyRange.isEmpty {
            parts.append(sentences[bodyRange].joined(separator: " "))
        }
        if hasSignOff {
            // Sign-off name gets its own line if the sign-off sentence ends with a comma
            // ("Atenciosamente,") or there are two separate sign-off sentences.
            let signOffSentences = Array(sentences[signOffStart...])
            if signOffSentences.count >= 2 {
                parts.append(signOffSentences.joined(separator: "\n"))
            } else {
                // Single sentence: split on trailing comma ("Atenciosamente, Rafael")
                let single = signOffSentences[0]
                if let commaRange = single.range(of: ", "),
                   single.distance(from: commaRange.upperBound, to: single.endIndex) > 0 {
                    let before = String(single[..<commaRange.lowerBound]) + ","
                    let after  = String(single[commaRange.upperBound...])
                    parts.append("\(before)\n\(after)")
                } else {
                    parts.append(single)
                }
            }
        }

        let separator = (hasPleasantries || hasSignOff) ? "\n\n" : "\n"
        // Join: greeting+pleasantries use single \n, body→sign-off uses \n\n
        var result = ""
        for (idx, part) in parts.enumerated() {
            result += part
            if idx < parts.count - 1 {
                // Use double newline before body (after pleasantries/greeting)
                // and before sign-off. Single newline within sign-off block.
                let nextIsSignOff = hasSignOff && idx == parts.count - 2
                let currentIsGreeting = hasGreeting && idx == 0 && !hasPleasantries
                if nextIsSignOff || (hasPleasantries && idx == 1) || currentIsGreeting {
                    result += "\n\n"
                } else {
                    result += "\n"
                }
            }
        }

        vfLog("TextFormattingService — email structure applied (\(sentences.count) sentences → \(parts.count) blocks)")
        return result
    }

    /// Splits text into sentences, keeping the terminal punctuation attached.
    private func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]
            current.append(ch)

            if [".", "!", "?"].contains(ch) {
                // Peek ahead: if next non-space is uppercase or end → new sentence
                var j = text.index(after: i)
                while j < text.endIndex && text[j] == " " { j = text.index(after: j) }
                if j == text.endIndex || text[j].isUppercase {
                    sentences.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            i = text.index(after: i)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }
        return sentences.filter { !$0.isEmpty }
    }

    // MARK: - Sanity check

    /// Returns true if the LLM output looks hallucinated and should be discarded.
    ///
    /// Three independent checks:
    ///  1. Character ratio: output > 2.5× input (catches large hallucinations/expansions).
    ///  2. Max words:       formatting must never ADD words — only punctuation/capitalisation
    ///                      may change. Allow a tiny buffer of +3 words for edge cases
    ///                      (e.g. a contraction split into two tokens). If more words appear,
    ///                      the LLM continued/invented content.
    ///  3. Min words:       formatting must never REMOVE substantial content. If the LLM
    ///                      returns < 70% of input word count, it likely interpreted the
    ///                      text as an instruction to itself ("ajude-me a montar…") instead
    ///                      of formatting it. Threshold is conservative — legitimate
    ///                      formatting never drops more than ~10% of words.
    private func isSuspiciousOutput(_ output: String, input: String) -> Bool {
        // Check 1: char ratio (too long)
        if output.count > Int(Double(input.count) * 2.5) + 80 {
            vfLog("⚠️ TextFormattingService — output too long (\(output.count) chars vs \(input.count)), discarding")
            return true
        }
        let inputWords  = input.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let outputWords = output.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count

        // Check 2: word count (too many — LLM invented content)
        let maxAllowed  = inputWords + 3
        if outputWords > maxAllowed {
            vfLog("⚠️ TextFormattingService — LLM added words (\(outputWords) vs \(inputWords) input), discarding")
            return true
        }

        // Check 3: word count (too few — LLM interpreted input as instruction and truncated)
        // Only apply when input is long enough that truncation is meaningful (≥ 10 words).
        // Short inputs legitimately produce same-length outputs; gate would misfire.
        if inputWords >= 10 {
            let minAllowed = Int(Double(inputWords) * 0.70)
            if outputWords < minAllowed {
                vfLog("⚠️ TextFormattingService — LLM dropped words (\(outputWords) vs \(inputWords) input, <70%), discarding — likely interpreted input as instruction")
                return true
            }
        }
        return false
    }

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

    private struct ProxyFormatResponse: Decodable {
        let formatted: String
    }
}
