import SwiftUI
import ApplicationServices

// MARK: - ReviewHUDView
// Floating card opened manually via the menu bar icon → "Rever".
// Three layouts, chosen from `result.outcome`:
//   .success → original/transcription box + final text (annotated) + translation picker + actions
//   .empty   → "no content" info row + close button
//   .error   → error message + close button
// No auto-dismiss — stays until the user closes it explicitly.

struct ReviewHUDView: View {

    let result: DictationResult
    var onDismiss: (() -> Void)?
    /// Closure that translates text — injected from the window controller.
    var translateAction: ((_ text: String, _ lang: String) async -> String?)?
    /// Closure that retries transcription using saved audio — injected only when pendingRetryURL != nil.
    var retryAction: (() -> Void)?

    @State private var editedText: String
    @State private var translateTarget: String   // "" = sem tradução
    @State private var isTranslating: Bool = false
    @State private var wordTokens: [WordToken] = []
    @State private var learnedMessage: String? = nil
    @State private var lastCopied: Bool = false

    private let cornerRadius: CGFloat = 18

    private static var translationLanguages: [(code: String, name: String)] = [
        ("",      String(localized: "Sem tradução")),
        ("pt",    "Português"),
        ("pt-BR", "Português (BR)"),
        ("en",    "English"),
        ("es",    "Español"),
        ("fr",    "Français"),
        ("de",    "Deutsch"),
        ("it",    "Italiano"),
        ("nl",    "Nederlands"),
        ("pl",    "Polski"),
        ("ru",    "Русский"),
        ("zh",    "中文"),
        ("ja",    "日本語"),
        ("ko",    "한국어"),
        ("ar",    "العربية"),
        ("tr",    "Türkçe"),
    ]

    init(result: DictationResult,
         onDismiss: (() -> Void)? = nil,
         translateAction: ((_ text: String, _ lang: String) async -> String?)? = nil) {
        self.result = result
        self.onDismiss = onDismiss
        self.translateAction = translateAction
        self._editedText = State(initialValue: result.correctedText)
        self._translateTarget = State(initialValue: result.translatedToLanguage)
    }

    // MARK: - Computed

    private var isSuccess: Bool {
        if case .success = result.outcome { return true }
        return false
    }
    private var emptyReason: String? {
        if case .empty(let reason) = result.outcome { return reason }
        return nil
    }
    private var errorMessage: String? {
        if case .error(let msg) = result.outcome { return msg }
        return nil
    }

    /// Text shown in the non-editable "Original" box.
    private var originalText: String {
        if result.wasTranslated, let pre = result.preTranslationText { return pre }
        if let raw = result.rawTranscriptionText { return raw }
        return result.correctedText
    }

    private var originalLabel: String {
        result.wasTranslated ? String(localized: "Original") : String(localized: "Transcrição")
    }

    /// Show the original box whenever the original differs meaningfully from the final text.
    private var showOriginalBox: Bool {
        // User has an active translation selected in the picker → always show source
        if !translateTarget.isEmpty { return true }
        // Dictation result already had a translation applied
        if result.wasTranslated && result.preTranslationText != nil { return true }
        // Raw Whisper output differs from final (LLM formatting changed it)
        if let raw = result.rawTranscriptionText, raw != editedText { return true }
        return false
    }

    /// Source to feed into translation (always the pre-processed text, never the translated one).
    private var sourceForTranslation: String {
        result.preTranslationText ?? result.rawTranscriptionText ?? result.correctedText
    }

    // Original (transcription) box scrolls internally if it exceeds this height.
    // Generous enough for 5-6 lines; very long transcriptions scroll independently.
    private let originalMaxHeight: CGFloat = 160

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────────
            headerRow
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)
                .opacity(0.4)

            // ── Content area (no outer scroll — each box manages its own) ─────
            VStack(alignment: .leading, spacing: 10) {

                // Banners
                if isSuccess && result.pastedViaClipboard {
                    warningBanner.padding(.horizontal, 16)
                }
                if isSuccess && result.usedKeyboardFallback {
                    noFieldBanner.padding(.horizontal, 16)
                }
                if let errMsg = result.translationErrorMessage {
                    translationFailedBanner(errMsg).padding(.horizontal, 16)
                }

                // Main content
                if let msg = errorMessage {
                    errorArea(msg).padding(.horizontal, 16)
                } else if let reason = emptyReason {
                    emptyArea(reason).padding(.horizontal, 16)
                } else {
                    // Original box — compact, scrolls internally if needed
                    if showOriginalBox {
                        originalBox
                            .padding(.horizontal, 16)
                    }

                    // Final text box — gets priority, scrolls internally if very long
                    finalTextBox
                        .padding(.horizontal, 16)

                    // "Spit vai aprender..." feedback
                    if let msg = learnedMessage {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                                .foregroundColor(.accentColor)
                            Text(msg)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)
                .opacity(0.4)

            // ── Action row ────────────────────────────────────────────────────
            if isSuccess {
                actionRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                dismissRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 440)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear {
            if isSuccess { rebuildTokens() }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(headerDotColor)
                .frame(width: 8, height: 8)
            Text("Revisão")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.85))
            Text("·")
                .font(.system(size: 13))
                .foregroundColor(.secondary.opacity(0.4))
            Text(String(format: "%.1fs", result.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary.opacity(0.6))

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
    }

    private var headerDotColor: Color {
        switch result.outcome {
        case .success: return Color.green.opacity(0.85)
        case .empty:   return Color.gray.opacity(0.6)
        case .error:   return Color.red.opacity(0.85)
        }
    }

    // MARK: - Original box (non-editable)

    private var originalBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: result.wasTranslated ? "mic.fill" : "waveform")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
                Text(originalLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.55))
            }
            // Internal scroll: caps original box at originalMaxHeight, scrolls if longer.
            // .fixedSize forces the ScrollView to claim its content's natural height;
            // frame(maxHeight:) then caps it — same pattern as finalTextBox.
            ScrollView(.vertical, showsIndicators: true) {
                Text(originalText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: originalMaxHeight)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
            )
        }
    }

    // MARK: - Final text box (annotated) + translation picker

    private var finalTextBox: some View {
        VStack(alignment: .leading, spacing: 6) {

            // Label row: "TEXTO FINAL" + translation picker
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Texto final")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.55))

                Spacer()

                if isTranslating {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }

                Picker("", selection: $translateTarget) {
                    ForEach(Self.translationLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 130)
                .onChange(of: translateTarget) { newLang in
                    Task {
                        isTranslating = true
                        // A action sincroniza a config global e re-processa o
                        // último resultado; devolve o texto final (traduzido ou
                        // o original, quando newLang == "" / "Sem tradução").
                        if let action = translateAction,
                           let finalText = await action(sourceForTranslation, newLang) {
                            editedText = finalText
                        } else {
                            editedText = sourceForTranslation
                        }
                        rebuildTokens()
                        isTranslating = false
                    }
                }
            }

            // Final text: fixedSize forces the ScrollView to take the content's natural
            // height — no internal scroll, the window itself grows to fit.
            // For very long texts the window is capped at 85 % of screen height
            // by the window controller; beyond that the bottom is clipped
            // (acceptable — "giant text" case is rare in dictation).
            ScrollView(.vertical, showsIndicators: false) {
                AnnotatedTextView(
                    tokens: wordTokens,
                    onWordTapped: { /* noop */ },
                    onCorrect: { original, corrected, addToVocab in
                        editedText = editedText.replacingOccurrences(of: original, with: corrected)
                        rebuildTokens()
                        if addToVocab {
                            VocabularyManager.shared.add(wrong: original, correct: corrected)
                        }
                        withAnimation {
                            learnedMessage = "Spit vai aprender com esta correção"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation { learnedMessage = nil }
                        }
                    },
                    onHint: { original in
                        VocabularyManager.shared.addHint(original)
                        withAnimation {
                            learnedMessage = "Dica adicionada — \u{201C}\(original)\u{201D} guardado como contexto"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            withAnimation { learnedMessage = nil }
                        }
                    }
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.28))
            )
            .overlay(alignment: .bottomTrailing) {
                if wordTokens.contains(where: { $0.isSuspicious }) {
                    HStack(spacing: 3) {
                        Circle().fill(Color.red.opacity(0.7)).frame(width: 4, height: 4)
                        Text("Clica para corrigir")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Action Row (success)

    private var actionRow: some View {
        HStack {
            Spacer()
            Button {
                copyToClipboard(editedText)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { lastCopied = true }
                // Feedback "Copiado" curto e depois fecha o HUD — o user já não vai
                // fazer mais nada aqui (o objetivo foi copiar). Se ainda houver
                // edições por copiar, ele reabre via menu bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    dismiss()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: lastCopied ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text(lastCopied ? "Copiado" : "Copiar")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(lastCopied
                              ? Color(red: 0.18, green: 0.72, blue: 0.42)   // green
                              : Color(red: 0.04, green: 0.52, blue: 1.00))  // vivid blue
                        .shadow(color: lastCopied
                                ? Color(red: 0.18, green: 0.72, blue: 0.42).opacity(0.35)
                                : Color(red: 0.04, green: 0.52, blue: 1.00).opacity(0.35),
                                radius: 6, x: 0, y: 3)
                )
                .scaleEffect(lastCopied ? 1.03 : 1.0)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Dismiss Row (empty / error)

    private var dismissRow: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Label("Fechar", systemImage: "xmark")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.secondary)
        }
    }

    // MARK: - Empty / Error areas

    private func emptyArea(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 1)
            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
        )
    }

    private func errorArea(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.red.opacity(0.85))
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Retry button — only shown when saved audio is available (pendingRetryURL != nil)
            if let retry = retryAction {
                HStack {
                    Spacer()
                    Button {
                        retry()
                    } label: {
                        Label("Tentar novamente", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.red.opacity(0.75))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.red.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Warning banners

    @ViewBuilder
    private var warningBanner: some View {
        let axTrusted = AXIsProcessTrusted()
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: axTrusted
                  ? "exclamationmark.triangle.fill"
                  : "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if axTrusted {
                    Text("Sem campo ativo — usa ⌘V para colar")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.8))
                } else {
                    Text("Permissão de acessibilidade necessária")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.9))
                    Text("Ativa o Spit em Definições do Sistema para colar automaticamente.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Abrir Definições → Acessibilidade") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(axTrusted ? 0.08 : 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var noFieldBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "keyboard.badge.eye")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .padding(.top, 1)
            Text("Sem campo ativo — usa ⌘V para colar se o texto não apareceu")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: .labelColor).opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private func translationFailedBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Tradução falhou — colado em idioma original")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(nsColor: .labelColor).opacity(0.9))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Helpers

    private func dismiss() { onDismiss?() }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func rebuildTokens() {
        let knownTerms = Set(VocabularyManager.shared.entries.map { $0.correct.lowercased() })
        let suspicious = detectSuspiciousWords(in: editedText, excluding: knownTerms)
        wordTokens = tokenise(editedText, suspicious: suspicious)
    }
}
