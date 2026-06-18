import Foundation
import AppKit

// MARK: - VocabularyManager
// Gere substituições de palavras personalizadas.
// Ex: "Rafael" → "Raphael", "RFID" → "RFID"
// Whisper recebe o vocabulário como "prompt" para melhorar reconhecimento.

class VocabularyManager: ObservableObject {

    static let shared = VocabularyManager()
    @Published private(set) var entries: [VocabularyEntry] = []

    private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Spit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("vocabulary.json")
    }()

    private init() {
        load()
    }

    // MARK: - CRUD

    func add(wrong: String, correct: String, caseSensitive: Bool = false) {
        let entry = VocabularyEntry(wrong: wrong, correct: correct, caseSensitive: caseSensitive)
        entries.append(entry)
        save()
    }

    /// Adds a term as a Whisper hint only — no substitution rule.
    /// Use for product names/proper nouns that sound like common words.
    func addHint(_ term: String) {
        guard !entries.contains(where: { $0.correct == term && $0.hintOnly }) else { return }
        let entry = VocabularyEntry(wrong: "", correct: term, hintOnly: true)
        entries.append(entry)
        save()
    }

    func update(_ entry: VocabularyEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            save()
        }
    }

    func delete(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        entries.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Aplicar Substituições ao Texto

    /// Aplica **apenas substituições inequívocas** (onde `wrong` não é palavra
    /// real em PT/EN). Entradas ambíguas — onde `wrong` é uma palavra válida
    /// (ex.: "mel", "casa", "para") — são reservadas para o LLM judge no
    /// `TextFormattingService`, que decide com contexto se substitui ou não.
    func apply(to text: String) -> String {
        var result = text
        for entry in unambiguousEntries() {
            result = Self.replaceWholeWord(
                in: result,
                wrong: entry.wrong,
                correct: entry.correct,
                caseSensitive: entry.caseSensitive
            )
        }
        return result
    }

    /// Substituições seguras para regex word-boundary: `wrong` não colide com
    /// vocabulário comum (proper nouns, marcas, siglas).
    func unambiguousEntries() -> [VocabularyEntry] {
        entries.filter { !$0.hintOnly && !Self.isAmbiguous(wrong: $0.wrong) }
    }

    /// Substituições que precisam de julgamento contextual via LLM:
    /// `wrong` é uma palavra real PT/EN. Substituir cegamente corrompe textos.
    func ambiguousEntries() -> [VocabularyEntry] {
        entries.filter { !$0.hintOnly && Self.isAmbiguous(wrong: $0.wrong) }
    }

    /// Determina se `wrong` é palavra real em PT ou EN (logo, ambígua).
    /// Multi-word substitutions ("Rafa Lopes" → "Rafael Lopes") nunca são ambíguas.
    static func isAmbiguous(wrong: String) -> Bool {
        let trimmed = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Multi-palavra → improvável colidir → tratar como inequívoca
        if trimmed.contains(where: { $0.isWhitespace }) { return false }
        // Palavras muito curtas (1 char) → considerar ambíguas por segurança
        if trimmed.count < 2 { return true }
        return Self.isRealWord(trimmed)
    }

    private static let ambiguityCheckLanguages = ["pt", "en"]
    private static var realWordCache: [String: Bool] = [:]

    /// Usa NSSpellChecker em PT e EN para detectar se `word` é vocabulário real.
    /// Cacheado em memória — chamadas para o spell-checker têm latência.
    private static func isRealWord(_ word: String) -> Bool {
        let key = word.lowercased()
        if let cached = realWordCache[key] { return cached }

        let checker = NSSpellChecker.shared
        let originalLang = checker.language()
        defer { _ = checker.setLanguage(originalLang) }

        var isReal = false
        for lang in ambiguityCheckLanguages {
            _ = checker.setLanguage(lang)
            let range = checker.checkSpelling(of: word, startingAt: 0)
            // checkSpelling retorna NSNotFound (location) quando NÃO encontra
            // erro — i.e., a palavra é reconhecida como válida nesse idioma.
            if range.location == NSNotFound || range.length == 0 {
                isReal = true
                break
            }
        }
        realWordCache[key] = isReal
        return isReal
    }

    /// Substitui `wrong` por `correct` apenas quando ocorrer como **palavra inteira**
    /// (rodeada por limites de palavra Unicode). Evita corromper palavras maiores
    /// — ex.: substituir "mel" → "MEO" não pode tocar em "melhora", "amêndoa", etc.
    ///
    /// Usa `\b` Unicode-aware (NSRegularExpression em Swift trata `\b` como limite
    /// entre `\w` e não-`\w`, e `\w` inclui letras acentuadas com option default).
    /// Para casos onde `wrong` começa/termina com não-letra (ex.: "C++"), o `\b`
    /// pode falhar — fallback para substituição literal nesse caso raro.
    static func replaceWholeWord(
        in text: String,
        wrong: String,
        correct: String,
        caseSensitive: Bool
    ) -> String {
        let trimmed = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Se o termo não começa nem termina com letra/dígito, \b não funciona —
        // usar substituição literal (case-sensitive only para evitar surpresas).
        let firstIsWord = trimmed.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } ?? false
        let lastIsWord  = trimmed.unicodeScalars.last.map  { CharacterSet.alphanumerics.contains($0) } ?? false
        guard firstIsWord && lastIsWord else {
            return text.replacingOccurrences(
                of: trimmed,
                with: correct,
                options: caseSensitive ? [] : .caseInsensitive
            )
        }

        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let pattern = "\\b\(escaped)\\b"
        var options: NSRegularExpression.Options = [.useUnicodeWordBoundaries]
        if !caseSensitive { options.insert(.caseInsensitive) }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        // Escapar `$` e `\` no template — `correct` é texto literal, não template.
        let template = NSRegularExpression.escapedTemplate(for: correct)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    // MARK: - Gerar Prompt para Whisper
    // O campo "prompt" da API Whisper ajuda o modelo a reconhecer termos específicos.
    // Passamos as formas correctas como contexto.

    func generateWhisperPrompt() -> String {
        guard !entries.isEmpty else { return "" }
        let correctForms = entries.map { $0.correct }.joined(separator: ", ")
        return correctForms
    }

    // MARK: - Aprender de Correcção Manual
    // Chamado quando o utilizador corrige o texto no ReviewHUD.
    // Usa diff LCS ao nível de palavra para encontrar substituições independentemente da posição.
    // Retorna os pares aprendidos para feedback visual.

    @discardableResult
    func learnFromCorrection(original: String, corrected: String) -> [(wrong: String, correct: String)] {
        guard original != corrected else { return [] }

        let origWords = tokenizeWords(original)
        let corrWords = tokenizeWords(corrected)

        let changes = wordDiff(from: origWords, to: corrWords)
        var learned: [(wrong: String, correct: String)] = []

        for (wrong, correct) in changes {
            guard !wrong.isEmpty, !correct.isEmpty else { continue }
            // Skip if it's just a case change of a common word (e.g. "The" → "the")
            // Only learn proper nouns, product names, etc.
            let alreadyExists = entries.contains {
                $0.wrong.lowercased() == wrong.lowercased() && $0.correct == correct
            }
            if !alreadyExists {
                add(wrong: wrong, correct: correct)
                learned.append((wrong: wrong, correct: correct))
                vfLog("VocabularyManager learned: '\(wrong)' → '\(correct)'")
            }
        }
        return learned
    }

    // MARK: - Word Diff (LCS-based)

    private func tokenizeWords(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Finds substitutions between two word arrays using LCS.
    /// Returns pairs (wrong, correct) where a word was replaced.
    private func wordDiff(from original: [String], to corrected: [String]) -> [(String, String)] {
        let n = original.count, m = corrected.count

        // Build LCS table (case-insensitive comparison)
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                if original[i-1].lowercased() == corrected[j-1].lowercased() {
                    lcs[i][j] = lcs[i-1][j-1] + 1
                } else {
                    lcs[i][j] = max(lcs[i-1][j], lcs[i][j-1])
                }
            }
        }

        // Backtrack to find deleted and inserted words
        var deletions: [String] = []
        var insertions: [String] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && original[i-1].lowercased() == corrected[j-1].lowercased() {
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || lcs[i][j-1] >= lcs[i-1][j]) {
                insertions.insert(corrected[j-1], at: 0)
                j -= 1
            } else {
                deletions.insert(original[i-1], at: 0)
                i -= 1
            }
        }

        // Pair deletions with insertions as substitutions (1:1 match)
        guard deletions.count == insertions.count, !deletions.isEmpty else { return [] }

        return zip(deletions, insertions).compactMap { (wrong, correct) in
            // Skip identical words (same spelling, different only in punctuation context)
            guard wrong.lowercased() != correct.lowercased() else { return nil }
            return (wrong, correct)
        }
    }

    // MARK: - Persistência

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL)
        } catch {
            print("[VocabularyManager] Erro ao guardar: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            entries = try JSONDecoder().decode([VocabularyEntry].self, from: data)
            print("[VocabularyManager] \(entries.count) entradas carregadas")
        } catch {
            print("[VocabularyManager] Erro ao carregar: \(error)")
            entries = []
        }
    }
}
