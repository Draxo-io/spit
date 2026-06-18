import Foundation

// MARK: - TextFormattingService
// Local post-processing: applies email paragraph structure (greeting / body / sign-off)
// to raw transcription output. Pure string manipulation — no network calls.

final class TextFormattingService {

    static let shared = TextFormattingService()
    private init() {}

    // MARK: - Local formatting (entry point)

    /// Applies local email structure formatting to `text`.
    /// Pure string manipulation — no network calls.
    func applyLocal(_ text: String) -> String {
        applyEmailStructure(text)
    }

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
            // Uma linha de nome (≤ 2 palavras) imediatamente a seguir ao fecho.
            // Threshold reduzido de 3 para 2: evita que frases curtas do corpo
            // como "Pois não veio." (3 palavras) sejam incorretamente absorvidas.
            let wordCount = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
            let isNameLine = (signOffStart < sentences.endIndex) && wordCount <= 2

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
                    // Pleasantry = frase social curta. Threshold de "?" reduzido de 10 para 5
                    // palavras: perguntas de corpo ("Era pra ter vindo algum documento?")
                    // não são pleasantries mesmo que terminem em "?".
                    let isPleasantry = (secondWordCount <= 10 && pleasantryWords.contains(where: { secondLower.contains($0) }))
                        || (secondWordCount <= 5 && second.hasSuffix("?"))
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
            let greetingText = sentences[sentences.startIndex..<greetingEnd].joined(separator: "\n")
            parts.append(splitGreetingLine(greetingText))
        }
        if hasPleasantries {
            parts.append(sentences[greetingEnd..<pleasantriesEnd].joined(separator: " "))
        }
        if !bodyRange.isEmpty {
            // Frases do corpo em linhas consecutivas (sem linha em branco entre elas).
            // Linhas em branco ficam reservadas para separar blocos (saudação↔corpo, corpo↔fecho).
            parts.append(sentences[bodyRange].joined(separator: "\n"))
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
                    // Linha em branco entre "Atenciosamente," e o nome.
                    parts.append("\(before)\n\n\(after)")
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
                if nextIsSignOff {
                    // Duas linhas em branco antes do fecho (separação visual forte).
                    result += "\n\n\n"
                } else if (hasPleasantries && idx == 1) || currentIsGreeting {
                    result += "\n\n"
                } else {
                    result += "\n"
                }
            }
        }

        vfLog("TextFormattingService — email structure applied (\(sentences.count) sentences → \(parts.count) blocks)")
        return result
    }

    /// Quebra uma linha de saudação composta em duas linhas quando contém
    /// "[Nome], [saudação curta]" — ex.: "Olá Gustavo, bom dia."
    /// → "Olá Gustavo\nBom dia!"
    ///
    /// Só actua quando a parte após a vírgula tem ≤ 5 palavras E termina com
    /// pontuação (evita partir "Olá Gustavo, Maria e João" ou frases sem terminal).
    private func splitGreetingLine(_ greeting: String) -> String {
        guard let commaIdx = greeting.firstIndex(of: ",") else { return greeting }

        let before = String(greeting[..<commaIdx])
        var after  = String(greeting[greeting.index(after: commaIdx)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !after.isEmpty,
              [".", "!", "?"].contains(after.last ?? " "),
              after.components(separatedBy: .whitespaces).filter({ !$0.isEmpty }).count <= 5
        else { return greeting }

        // Capitalizar e trocar "." final por "!" (tom de saudação).
        after = after.prefix(1).uppercased() + after.dropFirst()
        if after.hasSuffix(".") { after = String(after.dropLast()) + "!" }

        return "\(before)\n\(after)"
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
                // Peek ahead: skip spaces AND newlines — the LLM may already have
                // inserted \n between sentences, and we must not confuse them with
                // intra-sentence content.
                var j = text.index(after: i)
                while j < text.endIndex && (text[j] == " " || text[j] == "\n") {
                    j = text.index(after: j)
                }
                if j == text.endIndex || text[j].isUppercase {
                    sentences.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            }
            i = text.index(after: i)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return sentences.filter { !$0.isEmpty }
    }

}
