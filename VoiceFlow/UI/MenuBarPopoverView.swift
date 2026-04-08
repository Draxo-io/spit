import SwiftUI

// MARK: - MenuBarPopoverView
// Popover shown when clicking the menu bar icon.

struct MenuBarPopoverView: View {

    @EnvironmentObject var dictationController: DictationController
    @EnvironmentObject var creditsManager: CreditsManager
    @EnvironmentObject var vocabularyManager: VocabularyManager
    @ObservedObject private var licenseManager: LicenseManager = .shared
    @ObservedObject private var ttsService: TTSService = .shared
    @ObservedObject private var networkMonitor: NetworkMonitor = .shared

    @State private var lastResultCopied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            accessibilityWarningView   // banner vermelho quando AX não está concedida
            offlineBannerView          // banner laranja quando sem internet (e a precisar dela)
            byokMissingKeyBannerView   // banner vermelho quando chave STT está em falta (BYOK)
            retryBannerView            // banner laranja quando a última transcrição falhou
            creditsView
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
            Divider()
            languageQuickAccessView
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            Divider()
            freeTrialCTAView
            if let result = dictationController.lastResult {
                lastResultView(result: result)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            actionsView
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundColor(.accentColor)
            Text("Spit")
                .font(.headline)
            Spacer()
            // Dual LEDs: Ditado + Leitura
            HStack(spacing: 6) {
                statusLED(
                    icon: "mic.fill",
                    color: dictationStateColor,
                    tooltip: dictationStateTooltip
                )
                statusLED(
                    icon: "speaker.wave.2.fill",
                    color: ttsService.isSpeaking ? .blue : Color.secondary.opacity(0.35),
                    tooltip: ttsService.isSpeaking ? "A ler texto…" : "Leitura inativa"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Compact LED indicator with icon + colored dot
    private func statusLED(icon: String, color: Color, tooltip: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .help(tooltip)
        .animation(.easeInOut(duration: 0.2), value: color)
    }

    // MARK: - Credits

    private var creditsView: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: key status + monthly cost
            HStack {
                Image(systemName: creditsManager.mode == .userKey ? "key.fill" : "clock")
                    .font(.caption)
                    .foregroundColor(creditsManager.freeTrialExhausted ? .red : .secondary)
                Text(creditsManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(creditsManager.freeTrialExhausted ? .red : .secondary)
                Spacer()
                if creditsManager.mode == .userKey {
                    Text(creditsManager.estimatedMonthlyCostFormatted)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .help("Estimated Whisper API spend this month (USD · $0.006/min)")
                }
            }

            // Row 2: value summary — only shown when there's meaningful usage this month
            if creditsManager.mode == .userKey, monthlyWordCount >= 50 {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.accentColor.opacity(0.8))
                    Text(valueSummary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Value Summary helpers

    /// Word count from HistoryManager entries in the current calendar month
    private var monthlyWordCount: Int {
        let cal = Calendar.current
        let now = Date()
        return HistoryManager.shared.entries
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// "X words → ~Y min saved this month"  (assumes 40 WPM average typing speed)
    private var valueSummary: String {
        let words = monthlyWordCount
        let minutesSaved = max(1, Int(Double(words) / 40.0))
        let wordsFormatted = words >= 1000
            ? String(format: "%.1fk", Double(words) / 1000)
            : "\(words)"
        return String(
            format: String(localized: "%1$@ words → ~%2$d min saved this month"),
            wordsFormatted,
            minutesSaved
        )
    }

    // MARK: - Language Quick Access

    private let dictationLanguages: [(code: String, name: String, sub: String?)] = [
        ("auto",  "Auto",     nil),
        ("pt",    "PT",       "Português"),
        ("pt-BR", "PT-BR",    "Português (BR)"),
        ("en",    "EN",       "English"),
        ("es",    "ES",       "Español"),
        ("fr",    "FR",       "Français"),
        ("de",    "DE",       "Deutsch"),
        ("it",    "IT",       "Italiano"),
    ]

    private var languageQuickAccessView: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            // Dictation language picker
            Menu {
                ForEach(dictationLanguages, id: \.code) { lang in
                    Button {
                        var s = dictationController.loadSettings()
                        s.language = lang.code
                        dictationController.saveSettings(s)
                    } label: {
                        let current = dictationController.loadSettings().language
                        HStack {
                            Text(lang.name)
                            if let sub = lang.sub {
                                Text("· \(sub)").foregroundColor(.secondary)
                            }
                            if current == lang.code {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                let code = dictationController.loadSettings().language
                let label = dictationLanguages.first(where: { $0.code == code })?.name ?? code.uppercased()
                HStack(spacing: 3) {
                    Image(systemName: "mic.fill").font(.system(size: 9))
                    Text(label).font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Idioma de ditado")

            Spacer()

            // Auto-translate toggle + target language
            let settings = dictationController.loadSettings()
            if settings.autoTranslateEnabled {
                Text("→")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Menu {
                    ForEach(dictationLanguages.filter { $0.code != "auto" }, id: \.code) { lang in
                        Button {
                            var s = dictationController.loadSettings()
                            s.autoTranslateTargetLanguage = lang.code
                            dictationController.saveSettings(s)
                        } label: {
                            let cur = dictationController.loadSettings().autoTranslateTargetLanguage
                            HStack {
                                Text(lang.sub ?? lang.name)
                                if cur == lang.code {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    let code = settings.autoTranslateTargetLanguage
                    let label = dictationLanguages.first(where: { $0.code == code })?.name ?? code.uppercased()
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
                        Text(label).font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.08))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Idioma de destino para tradução")
            }

            // Auto-translate toggle button
            Button {
                var s = dictationController.loadSettings()
                s.autoTranslateEnabled.toggle()
                dictationController.saveSettings(s)
            } label: {
                Image(systemName: settings.autoTranslateEnabled
                      ? "arrow.triangle.2.circlepath.circle.fill"
                      : "arrow.triangle.2.circlepath.circle")
                    .font(.system(size: 14))
                    .foregroundColor(settings.autoTranslateEnabled ? .accentColor : .secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(settings.autoTranslateEnabled ? "Desativar tradução automática" : "Ativar tradução automática")
        }
    }

    // MARK: - Last Result

    private func lastResultView(result: DictationResult) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.correctedText, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { lastResultCopied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 0.2)) { lastResultCopied = false }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Last dictation")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if lastResultCopied {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else {
                        HStack(spacing: 4) {
                            Text("\(Int(result.duration))s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .transition(.opacity)
                    }
                }
                Text(result.correctedText)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(lastResultCopied
                          ? Color.green.opacity(0.08)
                          : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(lastResultCopied
                                  ? Color.green.opacity(0.3)
                                  : Color.clear, lineWidth: 1)
            )
            .animation(.easeInOut(duration: 0.2), value: lastResultCopied)
        }
        .buttonStyle(.plain)
        .help("Click to copy to clipboard")
    }

    // MARK: - Accessibility Warning

    @ViewBuilder
    private var accessibilityWarningView: some View {
        if !dictationController.isAccessibilityTrusted {
            alertBanner(
                color: .red,
                icon: "exclamationmark.lock.fill",
                title: "Accessibility permission required",
                message: "Text won't be typed automatically. Grant access in System Settings → Privacy → Accessibility.",
                actionLabel: "Open Settings"
            ) {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            Divider()
        }
    }

    // MARK: - Offline Banner

    @ViewBuilder
    private var offlineBannerView: some View {
        if networkMonitor.showOfflineWarning {
            alertBanner(
                color: .orange,
                icon: "wifi.slash",
                title: "Sem ligação à internet",
                message: "O ditado via nuvem não está disponível. Ativa o modo local em Definições.",
                actionLabel: "Definições"
            ) {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.openSettings()
                }
            }
            Divider()
        }
    }

    // MARK: - BYOK Missing Key Banner

    @ViewBuilder
    private var byokMissingKeyBannerView: some View {
        if licenseManager.plan == .byok {
            let settings = dictationController.loadSettings()
            let provider  = settings.byokProvider
            let hasSttKey = KeychainManager.shared.hasKey(for: provider)

            if !hasSttKey {
                alertBanner(
                    color: .red,
                    icon: "key.slash.fill",
                    title: "Chave \(provider.displayName) em falta",
                    message: "O ditado está desativado. Adiciona a tua chave API em Definições → APIs.",
                    actionLabel: "Abrir Definições"
                ) {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.openSettings()
                    }
                }
                Divider()
            }
        }
    }

    // MARK: - Retry Banner

    @ViewBuilder
    private var retryBannerView: some View {
        if dictationController.pendingRetryURL != nil {
            alertBanner(
                color: .orange,
                icon: "exclamationmark.triangle.fill",
                title: "Last transcription failed",
                message: "The audio is saved for 10 minutes.",
                actionLabel: "Retry"
            ) {
                dictationController.retryPendingDictation()
            }
            Divider()
        }
    }

    // MARK: - Free Trial CTA

    @ViewBuilder
    private var freeTrialCTAView: some View {
        if creditsManager.freeTrialExhausted {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Free trial exhausted")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
                Text("Add your OpenAI API key in Settings to continue.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings → API Key") {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.openSettings()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            Divider()
        }
    }

    // MARK: - Actions

    private var actionsView: some View {
        HStack {
            Button {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.openSettings()
                }
            } label: {
                Image(systemName: "gear")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit Spit")
        }
    }

    // MARK: - Reusable Alert Banner

    private func alertBanner(
        color: Color,
        icon: String,
        title: String,
        message: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Spacer()
            }
            HStack {
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(actionLabel) { action() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.9))
                    .cornerRadius(6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.85))
    }

    // MARK: - State colour helpers

    private var dictationStateColor: Color {
        switch dictationController.state {
        case .idle:       return .green
        case .recording:  return .red
        case .processing: return .orange
        case .injecting:  return .blue
        case .error:      return .red
        }
    }

    private var dictationStateTooltip: String {
        switch dictationController.state {
        case .idle:       return "Ditado pronto"
        case .recording:  return "A gravar…"
        case .processing: return "A transcrever…"
        case .injecting:  return "A inserir texto…"
        case .error(let m): return "Erro: \(m)"
        }
    }
}

// MARK: - AudioLevelView

struct AudioLevelView: View {
    let level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(index: i))
                    .frame(width: 4, height: barHeight(index: i))
                    .animation(.easeInOut(duration: 0.1), value: level)
            }
        }
    }

    private func normalizedLevel() -> Float {
        let clamped = max(-60, min(0, level))
        return (clamped + 60) / 60
    }

    private func barHeight(index: Int) -> CGFloat {
        let nl = normalizedLevel()
        let threshold = Float(index) / Float(barCount)
        return nl > threshold ? CGFloat(4 + index * 3) : 4
    }

    private func barColor(index: Int) -> Color {
        let nl = normalizedLevel()
        let threshold = Float(index) / Float(barCount)
        return nl > threshold ? .red : Color.secondary.opacity(0.3)
    }
}
