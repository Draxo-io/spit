import SwiftUI
import AppKit
import NaturalLanguage

// MARK: - WordToken

struct WordToken: Identifiable {
    let id = UUID()
    let text: String         // display text (may include trailing punctuation)
    let clean: String        // text stripped of punctuation, for lookup
    let isSuspicious: Bool
    var isDiffAdded: Bool = false    // true = word is new/changed vs raw transcription (green tint)
    var isParagraphBreak: Bool = false  // sentinel — renders as a full-width spacer to force a new row
}

// MARK: - WordDiff
// LCS-based word-level diff between raw Whisper output and formatted text.
//
// Normalização: lowercase apenas (mantém pontuação).
// "word" == "word" → same; "word" vs "word." → different (pontuação adicionada visível).
// "Stop" vs "stop"  → same  (só capitalização, ignorada).

struct WordDiff {

    struct Entry: Identifiable {
        let id = UUID()
        let text: String
        let isChanged: Bool
    }

    let rawWords: [Entry]
    let formattedWords: [Entry]

    init(raw: String, formatted: String) {
        let rawTokens = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let fmtTokens = formatted.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        // Normalizar: lowercase + strip ALL punctuation.
        // "mesmo" e "mesmo." → ambos "mesmo" → matched → sem destaque (só pontuação mudou).
        // "bem" repetido em raw mas não em formatted → um "bem" sem match → vermelho.
        // Capitalização ("Vamos" vs "vamos") → matched → sem destaque.
        let normalize: (String) -> String = {
            $0.lowercased().trimmingCharacters(in: .punctuationCharacters)
        }
        let (aMatched, bMatched) = WordDiff.lcsMatches(
            a: rawTokens.map(normalize),
            b: fmtTokens.map(normalize)
        )
        self.rawWords       = zip(rawTokens, aMatched).map { Entry(text: $0, isChanged: !$1) }
        self.formattedWords = zip(fmtTokens, bMatched).map { Entry(text: $0, isChanged: !$1) }
    }

    var hasChanges: Bool {
        rawWords.contains { $0.isChanged } || formattedWords.contains { $0.isChanged }
    }

    private static func lcsMatches(a: [String], b: [String]) -> ([Bool], [Bool]) {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else {
            return ([Bool](repeating: false, count: m), [Bool](repeating: false, count: n))
        }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = a[i-1] == b[j-1]
                    ? dp[i-1][j-1] + 1
                    : max(dp[i-1][j], dp[i][j-1])
            }
        }
        var aMatched = [Bool](repeating: false, count: m)
        var bMatched = [Bool](repeating: false, count: n)
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i-1] == b[j-1] {
                aMatched[i-1] = true; bMatched[j-1] = true
                i -= 1; j -= 1
            } else if dp[i-1][j] >= dp[i][j-1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return (aMatched, bMatched)
    }
}

// MARK: - Suspicious Word Detection
// Flags words that Whisper commonly transcribes incorrectly.
// Rules (applied only after NLTagger and whitelist filters pass):
//  1. Mid-sentence capitalisation
//  2. All-caps acronyms not in the known-acronyms whitelist
//  3. CamelCase words
//  4. Words flagged by NSSpellChecker (catches non-existent words like "adim" → "admin")
// Words shorter than 3 chars are ignored to reduce false positives.
//
// Pre-filters (reduce false positives):
//  A. NLTagger named-entity recognition — persons, places, organisations
//     are correctly capitalised by definition and should never be flagged.
//  B. Hardcoded whitelist of common acronyms/brands that Whisper handles well.
//  C. User vocabulary (hints + substitutions) — already known to be correct.

/// Common tech/everyday acronyms and brand names that should never be flagged.
private let knownAcronymsLower: Set<String> = {
    let terms = [
        // Connectivity & tech
        "vpn", "api", "url", "http", "https", "ftp", "ssh", "dns", "ip",
        "wifi", "nfc", "ble", "usb", "hdmi", "qr",
        // Computing
        "cpu", "gpu", "ram", "ssd", "hdd", "ios", "macos", "pdf",
        "html", "css", "xml", "json", "sql", "ai", "ml", "ui", "ux",
        // Apple ecosystem
        "mac", "iphone", "ipad", "imac", "airpods", "appletv", "siri",
        // Common abbreviations
        "tv", "ok", "id", "pin", "otp", "sms", "gps", "ar", "vr",
        // Business
        "ceo", "cto", "cfo", "coo", "hr", "it", "pr",
    ]
    return Set(terms)
}()

func detectSuspiciousWords(in text: String, excluding knownTerms: Set<String> = []) -> Set<String> {
    // ── A. Named-entity recognition via NLTagger ──────────────────────────
    // Persons, places and organisations are correctly capitalised by definition.
    var namedEntityWords = Set<String>()
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    tagger.enumerateTags(
        in: text.startIndex..<text.endIndex,
        unit: .word,
        scheme: .nameType,
        options: [.omitWhitespace, .omitPunctuation]
    ) { tag, range in
        if tag == .personalName || tag == .placeName || tag == .organizationName {
            let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
            namedEntityWords.insert(word.lowercased())
        }
        return true
    }

    // ── Spell-check (used by Rule 4) ──────────────────────────────────────
    // Run once over the ENTIRE text — gives the checker context to identify
    // language correctly. Per-word checking has no context and defaults to
    // English, flagging valid PT words like "Além" as misspelled.
    //
    // Words to ignore globally for this run: user vocabulary + acronyms +
    // detected named entities. setIgnoredWords expects the original casing.
    let spellChecker = NSSpellChecker.shared
    spellChecker.automaticallyIdentifiesLanguages = true
    let docTag = NSSpellChecker.uniqueSpellDocumentTag()
    var ignoreList = Array(knownTerms) + Array(knownAcronymsLower) + Array(namedEntityWords)
    // Also include capitalised versions so the checker matches both casings.
    ignoreList += ignoreList.map { $0.capitalized }
    spellChecker.setIgnoredWords(ignoreList, inSpellDocumentWithTag: docTag)

    var misspelledLowered = Set<String>()
    var cursor = 0
    while cursor < (text as NSString).length {
        let range = spellChecker.checkSpelling(
            of: text,
            startingAt: cursor,
            language: nil,
            wrap: false,
            inSpellDocumentWithTag: docTag,
            wordCount: nil
        )
        if range.location == NSNotFound || range.length == 0 { break }
        let word = (text as NSString).substring(with: range)
            .trimmingCharacters(in: .punctuationCharacters)
        if word.count >= 3 { misspelledLowered.insert(word.lowercased()) }
        cursor = range.location + range.length
    }

    // ── B–C. Syntactic rules with pre-filters ─────────────────────────────
    var suspicious = Set<String>()
    let rawWords = text.components(separatedBy: .whitespacesAndNewlines)
    let sentenceEnders = CharacterSet(charactersIn: ".!?…")
    var afterSentenceEnd = true

    for (i, raw) in rawWords.enumerated() {
        let clean = raw.trimmingCharacters(in: .punctuationCharacters)
        defer {
            if let last = raw.unicodeScalars.last, sentenceEnders.contains(last) {
                afterSentenceEnd = true
            } else {
                afterSentenceEnd = false
            }
        }

        guard clean.count >= 3, clean.rangeOfCharacter(from: .letters) != nil else { continue }

        let lower = clean.lowercased()

        // Pre-filter A: named entity recognised by NLTagger
        guard !namedEntityWords.contains(lower) else { continue }
        // Pre-filter B: known acronym / brand whitelist
        guard !knownAcronymsLower.contains(lower) else { continue }
        // Pre-filter C: user vocabulary (hints + substitutions)
        guard !knownTerms.contains(lower) else { continue }

        let letters = clean.filter { $0.isLetter }

        // Rule 1: mid-sentence capital first letter
        if i > 0 && !afterSentenceEnd && clean.first?.isUppercase == true {
            suspicious.insert(clean)
        }

        // Rule 2: all-caps (e.g. UUID, NATO — common ones already excluded above)
        if letters.count >= 2 && String(letters) == String(letters).uppercased() {
            suspicious.insert(clean)
        }

        // Rule 3: CamelCase — uppercase letter after the first character
        if clean.dropFirst().contains(where: { $0.isUppercase }) {
            suspicious.insert(clean)
        }

        // Rule 4: spell-check (computed once on the whole text above with
        // language auto-detected from full context).
        if misspelledLowered.contains(lower) {
            suspicious.insert(clean)
        }
    }
    return suspicious
}

// MARK: - Tokeniser
// Splits text into word tokens, inserting paragraph-break sentinels at each \n.
// The FlowLayout renders paragraph-break tokens as full-width transparent views,
// which forces subsequent words onto a new row — preserving paragraph structure.

func tokenise(_ text: String, suspicious: Set<String>) -> [WordToken] {
    // Split into lines first to preserve \n structure.
    let lines = text.components(separatedBy: "\n")
    var tokens: [WordToken] = []

    for (lineIdx, line) in lines.enumerated() {
        let words = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for raw in words {
            let clean = raw.trimmingCharacters(in: .punctuationCharacters)
            let isSusp = clean.count >= 3 && suspicious.contains(clean)
            tokens.append(WordToken(text: raw, clean: clean, isSuspicious: isSusp))
        }
        // Insert a paragraph-break sentinel between lines (not after the last one).
        // A double \n (\n\n) produces two consecutive sentinels → extra vertical gap.
        if lineIdx < lines.count - 1 {
            var br = WordToken(text: "", clean: "", isSuspicious: false)
            br.isParagraphBreak = true
            tokens.append(br)
        }
    }
    return tokens
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var hSpacing: CGFloat = 4
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(0.0) { sum, row in
            sum + (row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0) + vSpacing
        }
        return CGSize(
            width: proposal.width ?? 0,
            height: max(0, height - vSpacing)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = makeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + hSpacing
            }
            y += rowHeight + vSpacing
        }
    }

    private func makeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubview]] = []
        var current: [LayoutSubview] = []
        var rowWidth: CGFloat = 0

        for subview in subviews {
            let w = subview.sizeThatFits(.unspecified).width
            if rowWidth + w + hSpacing > maxWidth + 1 && !current.isEmpty {
                rows.append(current)
                current = [subview]
                rowWidth = w + hSpacing
            } else {
                current.append(subview)
                rowWidth += w + hSpacing
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - AnnotatedTextView

struct AnnotatedTextView: View {

    let tokens: [WordToken]
    /// Called when any word is tapped (even before correction is applied) — use to cancel auto-dismiss
    var onWordTapped: (() -> Void)?
    /// Called when user applies a correction: (original clean word, replacement text, addToVocabulary)
    var onCorrect: ((String, String, Bool) -> Void)?
    /// Called when user taps "Dica" with empty field — adds word as vocabulary hint
    var onHint: ((String) -> Void)?

    @State private var selectedToken: WordToken? = nil
    @State private var replacement: String = ""

    var body: some View {
        FlowLayout(hSpacing: 4, vSpacing: 6) {
            ForEach(tokens) { token in
                wordView(token)
            }
        }
    }

    // MARK: - Word View

    @ViewBuilder
    private func wordView(_ token: WordToken) -> some View {
        if token.isParagraphBreak {
            // Full-width invisible view — forces FlowLayout to start a new row.
            Color.clear.frame(width: 10_000, height: 4)
        } else {
        let isSelected = selectedToken?.id == token.id

        Group {
            if token.isSuspicious {
                // Red dotted underline via AttributedString
                Text(suspiciousAttr(token.text))
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .labelColor))
            } else {
                Text(token.text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .labelColor))
            }
        }
        .padding(.vertical, 1)
        .padding(.horizontal, token.isDiffAdded ? 2 : 0)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(
                    isSelected         ? Color.accentColor.opacity(0.12) :
                    token.isDiffAdded  ? Color.green.opacity(0.18)       :
                    Color.clear
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            replacement = token.clean.isEmpty ? token.text : token.clean
            selectedToken = token
            onWordTapped?()
        }
        .popover(isPresented: Binding(
            get: { selectedToken?.id == token.id },
            set: { if !$0 { selectedToken = nil } }
        ), arrowEdge: .bottom) {
            correctionPopover(for: token)
        }
        } // end else (not isParagraphBreak)
    }

    // MARK: - Correction Popover

    private func correctionPopover(for token: WordToken) -> some View {
        let original = token.clean.isEmpty ? token.text : token.clean
        let trimmed = replacement.trimmingCharacters(in: .whitespaces)
        let hasReplacement = !trimmed.isEmpty && trimmed != original

        return VStack(alignment: .leading, spacing: 12) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Corrigir palavra")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 5) {
                    Text("Reconhecido como")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(original)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }

            // Optional replacement field
            TextField("Como deve ser escrito", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .frame(width: 210)
                .onSubmit { if hasReplacement { applyCorrection(for: token) } }

            // Buttons
            HStack(spacing: 8) {
                Button("Cancelar") { selectedToken = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                // "Adicionar dica" — always enabled
                // Use o que o utilizador escreveu no campo (trimmed), não o original reconhecido.
                // Se o campo estiver vazio, usa o original (reforça a palavra já reconhecida).
                Button {
                    let hintTerm = trimmed.isEmpty ? original : trimmed
                    onHint?(hintTerm)
                    selectedToken = nil
                } label: {
                    Label("Adicionar dica", systemImage: "lightbulb")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)

                // "Substituir" — only enabled when field has content
                Button {
                    applyCorrection(for: token)
                } label: {
                    Label("Substituir", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!hasReplacement)
            }
        }
        .padding(14)
    }

    // MARK: - Helpers

    private func applyCorrection(for token: WordToken) {
        let trimmed = replacement.trimmingCharacters(in: .whitespaces)
        let original = token.clean.isEmpty ? token.text : token.clean
        guard !trimmed.isEmpty, trimmed != original else { return }
        onCorrect?(original, trimmed, true)
        selectedToken = nil
    }

    private func suspiciousAttr(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        attr.underlineStyle = Text.LineStyle(pattern: .dot, color: .red)
        return attr
    }
}
