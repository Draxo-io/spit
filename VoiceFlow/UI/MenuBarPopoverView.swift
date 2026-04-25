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
    @State private var now: Date = Date()
    @State private var isRefreshingLicense: Bool = false
    @State private var pendingUpdate: UpdateInfo? = nil
    @State private var planChangeMessage: String? = nil
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var lastResultVisible: Bool {
        guard let result = dictationController.lastResult else { return false }
        return now.timeIntervalSince(result.timestamp) < 300  // 5 minutes (SPEC §3.7)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            planChangedBannerView      // banner verde quando o plano mudou server-side
            updateAvailableBannerView  // banner azul quando há nova versão
            accessibilityWarningView   // banner vermelho quando AX não está concedida
            offlineBannerView          // banner laranja quando sem internet (e a precisar dela)
            byokMissingKeyBannerView   // banner vermelho quando chave STT está em falta (BYOK)
            dictationBlockView
            Divider()
            ttsBlockView
            Divider()
            freeTrialCTAView
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
        .onReceive(timer) { now = $0 }
        .onAppear {
            now = Date()
            // Refresh forçado da conta cada vez que o popover abre — barato e
            // garante que mudanças server-side (admin change_plan, webhook Lemon)
            // se reflectem rapidamente.
            Task { await AuthManager.shared.refreshAccount() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.updateAvailableNotification)) { note in
            pendingUpdate = note.userInfo?["info"] as? UpdateInfo
        }
        .onReceive(NotificationCenter.default.publisher(for: AuthManager.planChangedNotification)) { note in
            guard let oldPlan = note.userInfo?["oldPlan"] as? SpitPlan,
                  let newPlan = note.userInfo?["newPlan"] as? SpitPlan else { return }
            planChangeMessage = "Plano actualizado: \(oldPlan.rawValue) → \(newPlan.rawValue)"
        }
    }

    // MARK: - Plan Changed Banner

    @ViewBuilder
    private var planChangedBannerView: some View {
        if let msg = planChangeMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(msg)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button {
                    planChangeMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.10))
            Divider()
        }
    }

    // MARK: - Update Available Banner

    @ViewBuilder
    private var updateAvailableBannerView: some View {
        if let update = pendingUpdate {
            Button {
                UpdateChecker.shared.openDownloadPage()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spit \(update.version) disponível")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                        Text("Clica para descarregar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.08))
            }
            .buttonStyle(.plain)
            Divider()
        }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Consumo (§3.6)
    // Four states: BYOK · Trial/Pro active · Trial expired · Trial not started.
    // See SPEC.md §3.6 for the label contracts. We keep SF Symbols (mic.fill /
    // speaker.wave.2.fill) instead of raw 🎙 / 🔊 emojis for macOS consistency —
    // SPEC.md notes this decision.

    private enum ConsumoState {
        case byok                 // Lifetime / BYOK key
        case trialActive          // trial started + minutes remaining
        case trialExpired         // trial started + minutes exhausted
        case trialNotStarted      // user has not activated a trial yet
        case proMonthly           // monthly paid plan
    }

    private var consumoState: ConsumoState {
        switch licenseManager.plan {
        case .byok, .lifetime: return .byok       // both = unlimited usage, no monthly cap
        case .pro:             return .proMonthly
        case .trial:
            if !licenseManager.isActivated      { return .trialNotStarted }
            if licenseManager.trialExhausted    { return .trialExpired }
            return .trialActive
        }
    }

    /// Lifetime word count (used in expired state).
    private var lifetimeWordCount: Int {
        HistoryManager.shared.entries.reduce(0) { $0 + $1.wordCount }
    }

    /// Word count from HistoryManager entries in the current calendar month.
    private var monthlyWordCount: Int {
        let cal = Calendar.current
        let now = Date()
        return HistoryManager.shared.entries
            .filter { cal.isDate($0.date, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.wordCount }
    }

    /// "X words → ~Y min saved this month" (40 WPM average typing speed).
    /// `monthly=false` drops the "this month" suffix — used in lifetime labels.
    private func valueSummary(words: Int, monthly: Bool) -> String {
        let minutesSaved = max(1, Int(Double(words) / 40.0))
        let wordsFormatted = words >= 1000
            ? String(format: "%.1fk", Double(words) / 1000)
            : "\(words)"
        let fmt = monthly
            ? String(localized: "%1$@ words → ~%2$d min saved this month")
            : String(localized: "%1$@ words → ~%2$d min saved")
        return "~" + String(format: fmt, wordsFormatted, minutesSaved)
    }

    /// TTS minutes used this month (rounded to integer).
    private var monthlyTTSMinutes: Int {
        max(0, Int(creditsManager.monthlySecondsRead / 60))
    }

    /// TTS minutes remaining (trial/pro) — uses the same cap as dictation until
    /// backend provides a dedicated TTS quota.
    private var ttsMinutesRemaining: Int {
        let cap: Double
        switch consumoState {
        case .trialActive:  cap = licenseManager.trialLimitSeconds
        case .proMonthly:   cap = licenseManager.proLimitSeconds
        default:            return 0
        }
        return max(0, Int((cap - creditsManager.monthlySecondsRead) / 60))
    }

    /// Lifetime TTS minutes (used in expired state).
    private var lifetimeTTSMinutes: Int {
        max(0, Int(creditsManager.totalSecondsRead / 60))
    }

    @ViewBuilder
    private var creditsView: some View {
        switch consumoState {
        case .byok:
            consumoRows(
                dictationLine: valueSummary(words: monthlyWordCount, monthly: true),
                ttsLine: String(format: String(localized: "~%d min"), monthlyTTSMinutes),
                trailing: {
                    Text(creditsManager.estimatedMonthlyCostFormatted)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                        .help("Estimated Whisper API spend this month (USD · $0.006/min)")
                }
            )

        case .trialActive, .proMonthly:
            consumoRows(
                dictationLine: valueSummary(words: monthlyWordCount, monthly: true),
                ttsLine: String(format: String(localized: "~%d minutos de leitura restantes"), ttsMinutesRemaining),
                trailing: { EmptyView() }
            )

        case .trialExpired:
            consumoRows(
                dictationLine: valueSummary(words: lifetimeWordCount, monthly: false),
                ttsLine: String(format: String(localized: "~%d minutos de leitura utilizados"), lifetimeTTSMinutes),
                trailing: { EmptyView() }
            )

        case .trialNotStarted:
            // No usage rows — CTA banner handles this state entirely.
            EmptyView()
        }
    }

    /// Renders the two 🎙 / 🔊 rows with optional trailing view (e.g. BYOK cost estimate).
    private func consumoRows<Trailing: View>(
        dictationLine: String,
        ttsLine: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
                Text(dictationLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing()
            }
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 12)
                Text(ttsLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Stats rows (used inside each block)

    @ViewBuilder
    private var dictationStatsRow: some View {
        switch consumoState {
        case .byok:
            HStack(spacing: 6) {
                Text(valueSummary(words: monthlyWordCount, monthly: true))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(creditsManager.estimatedMonthlyCostFormatted)
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    .help("Estimated Whisper API spend this month (USD · $0.006/min)")
            }
        case .trialActive, .proMonthly:
            consumoStatRow(icon: "mic.fill", text: valueSummary(words: monthlyWordCount, monthly: true))
        case .trialExpired:
            consumoStatRow(icon: "mic.fill", text: valueSummary(words: lifetimeWordCount, monthly: false))
        case .trialNotStarted:
            EmptyView()
        }
    }

    @ViewBuilder
    private var ttsStatsRow: some View {
        switch consumoState {
        case .byok:
            consumoStatRow(icon: "speaker.wave.2.fill",
                           text: String(format: String(localized: "~%d min"), monthlyTTSMinutes))
        case .trialActive, .proMonthly:
            consumoStatRow(icon: "speaker.wave.2.fill",
                           text: String(format: String(localized: "~%d min restantes"), ttsMinutesRemaining))
        case .trialExpired:
            consumoStatRow(icon: "speaker.wave.2.fill",
                           text: String(format: String(localized: "~%d min utilizados"), lifetimeTTSMinutes))
        case .trialNotStarted:
            EmptyView()
        }
    }

    private func consumoStatRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.caption).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Section label helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.secondary.opacity(0.6))
            .tracking(0.8)
    }

    private func statusSectionLabel(_ title: String, ledColor: Color, tooltip: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ledColor)
                .frame(width: 6, height: 6)
                .help(tooltip)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
                .tracking(0.8)
        }
    }

    // MARK: - Dictation block

    private var dictationBlockView: some View {
        let s = dictationController.currentSettings
        return VStack(alignment: .leading, spacing: 6) {
            statusSectionLabel("DIGITAÇÃO", ledColor: dictationStateColor, tooltip: dictationStateTooltip)

            HStack(spacing: 6) {
                languagePicker(icon: "mic.fill", current: s.language, languages: availableLanguages) { code in
                    var updated = dictationController.loadSettings()
                    updated.dictationLanguage = code
                    updated.language = code
                    dictationController.saveSettings(updated)
                }
                if !s.privacyModeEnabled && s.autoTranslateEnabled {
                    translateTargetPicker(
                        current: s.autoTranslateTargetLanguage,
                        languages: availableLanguages.filter { $0.code != "auto" }
                    ) { code in
                        var updated = dictationController.loadSettings()
                        updated.autoTranslateTargetLanguage = code
                        dictationController.saveSettings(updated)
                    }
                }
                Spacer(minLength: 0)
                if s.privacyModeEnabled {
                    privacyPill
                } else {
                    translateToggle(enabled: s.autoTranslateEnabled) {
                        var updated = dictationController.loadSettings()
                        updated.autoTranslateEnabled.toggle()
                        dictationController.saveSettings(updated)
                    }
                }
            }

            dictationStatsRow

            if lastResultVisible, let result = dictationController.lastResult {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel(String(localized: "Última digitação"))
                    lastResultView(result: result)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    // MARK: - TTS block

    private var ttsBlockView: some View {
        let s = dictationController.currentSettings
        return VStack(alignment: .leading, spacing: 6) {
            statusSectionLabel("LEITURA", ledColor: ttsLEDColor, tooltip: ttsLEDTooltip)

            HStack(spacing: 6) {
                languagePicker(icon: "speaker.wave.2.fill", current: s.ttsLanguage, languages: availableLanguages) { code in
                    var updated = dictationController.loadSettings()
                    updated.ttsLanguage = code
                    dictationController.saveSettings(updated)
                }
                if !s.privacyModeEnabled && s.ttsAutoTranslateEnabled {
                    translateTargetPicker(
                        current: s.ttsAutoTranslateTargetLanguage,
                        languages: availableLanguages.filter { $0.code != "auto" }
                    ) { code in
                        var updated = dictationController.loadSettings()
                        updated.ttsAutoTranslateTargetLanguage = code
                        dictationController.saveSettings(updated)
                    }
                }
                Spacer(minLength: 0)
                if s.privacyModeEnabled {
                    privacyPill
                } else {
                    translateToggle(enabled: s.ttsAutoTranslateEnabled) {
                        var updated = dictationController.loadSettings()
                        updated.ttsAutoTranslateEnabled.toggle()
                        dictationController.saveSettings(updated)
                    }
                }
            }

            ttsStatsRow
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    // MARK: - Language Quick Access (legacy — kept for reference, replaced by dictationBlockView/ttsBlockView)

    private let availableLanguages: [(code: String, name: String, sub: String?)] = [
        ("auto",  "Auto",     nil),
        ("pt",    "PT",       "Português"),
        ("pt-BR", "PT-BR",    "Português (BR)"),
        ("en",    "EN",       "English"),
        ("es",    "ES",       "Español"),
        ("fr",    "FR",       "Français"),
        ("de",    "DE",       "Deutsch"),
        ("it",    "IT",       "Italiano"),
    ]

    // Uses dictationController.currentSettings (@Published) so the view re-renders on changes.
    private var languageQuickAccessView: some View {
        let s = dictationController.currentSettings

        return VStack(spacing: 6) {
            // ── Row 1: Ditado 🎙 ──────────────────────────────────────────────
            HStack(spacing: 6) {
                // Status LED (mic state colour)
                Circle()
                    .fill(dictationStateColor)
                    .frame(width: 7, height: 7)
                    .help(dictationStateTooltip)

                // Language picker
                languagePicker(
                    icon: "mic.fill",
                    current: s.language,
                    languages: availableLanguages
                ) { code in
                    var updated = dictationController.loadSettings()
                    updated.dictationLanguage = code
                    updated.language = code
                    dictationController.saveSettings(updated)
                }

                if !s.privacyModeEnabled && s.autoTranslateEnabled {
                    translateTargetPicker(
                        current: s.autoTranslateTargetLanguage,
                        languages: availableLanguages.filter { $0.code != "auto" }
                    ) { code in
                        var updated = dictationController.loadSettings()
                        updated.autoTranslateTargetLanguage = code
                        dictationController.saveSettings(updated)
                    }
                }

                Spacer(minLength: 0)

                if s.privacyModeEnabled {
                    privacyPill
                } else {
                    translateToggle(enabled: s.autoTranslateEnabled) {
                        var updated = dictationController.loadSettings()
                        updated.autoTranslateEnabled.toggle()
                        dictationController.saveSettings(updated)
                    }
                }
            }

            Divider().opacity(0.5)

            // ── Row 2: Leitura 🔊 ─────────────────────────────────────────────
            HStack(spacing: 6) {
                // Status LED (TTS colour)
                Circle()
                    .fill(ttsLEDColor)
                    .frame(width: 7, height: 7)
                    .help(ttsLEDTooltip)

                // Language picker
                languagePicker(
                    icon: "speaker.wave.2.fill",
                    current: s.ttsLanguage,
                    languages: availableLanguages
                ) { code in
                    var updated = dictationController.loadSettings()
                    updated.ttsLanguage = code
                    dictationController.saveSettings(updated)
                }

                if !s.privacyModeEnabled && s.ttsAutoTranslateEnabled {
                    translateTargetPicker(
                        current: s.ttsAutoTranslateTargetLanguage,
                        languages: availableLanguages.filter { $0.code != "auto" }
                    ) { code in
                        var updated = dictationController.loadSettings()
                        updated.ttsAutoTranslateTargetLanguage = code
                        dictationController.saveSettings(updated)
                    }
                }

                Spacer(minLength: 0)

                if s.privacyModeEnabled {
                    privacyPill
                } else {
                    translateToggle(enabled: s.ttsAutoTranslateEnabled) {
                        var updated = dictationController.loadSettings()
                        updated.ttsAutoTranslateEnabled.toggle()
                        dictationController.saveSettings(updated)
                    }
                }
            }
        }
    }

    // MARK: - Language picker helper

    private func languagePicker(
        icon: String,
        current: String,
        languages: [(code: String, name: String, sub: String?)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let label = languages.first(where: { $0.code == current })?.name ?? current.uppercased()
        return Menu {
            ForEach(languages, id: \.code) { lang in
                Button {
                    onSelect(lang.code)
                } label: {
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
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
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
    }

    // MARK: - Translate target picker

    private func translateTargetPicker(
        current: String,
        languages: [(code: String, name: String, sub: String?)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let label = languages.first(where: { $0.code == current })?.name ?? current.uppercased()
        return Menu {
            ForEach(languages, id: \.code) { lang in
                Button {
                    onSelect(lang.code)
                } label: {
                    HStack {
                        Text(lang.sub ?? lang.name)
                        if current == lang.code {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                // Clear "translate to" label — no ambiguous recycle icon
                Text("→ \(label)")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Translate toggle

    /// Pill button: shows ON/OFF state clearly. Tapping always toggles.
    private func translateToggle(enabled: Bool, onToggle: @escaping () -> Void) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 3) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 9))
                Text(enabled ? "Tradução ON" : "Traduzir")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(enabled ? .accentColor : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(enabled ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(enabled ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(enabled ? "Desativar tradução automática" : "Ativar tradução automática")
    }

    // MARK: - Privacy Pill

    private var privacyPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text("Local").font(.system(size: 10, weight: .medium))
                Text("Tradução não disponível").font(.system(size: 8))
            }
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
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
            HStack(alignment: .top, spacing: 8) {
                Text(result.correctedText)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Copy indicator — always visible, reacts to copy state
                Group {
                    if lastResultCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.secondary.opacity(0.5))
                            .transition(.opacity)
                    }
                }
                .font(.caption)
                .animation(.easeInOut(duration: 0.2), value: lastResultCopied)
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
        }
        .buttonStyle(.plain)
        .help("Clica para copiar o último ditado")
    }

    // MARK: - Accessibility Warning

    @ViewBuilder
    private var accessibilityWarningView: some View {
        if !dictationController.isAccessibilityTrusted {
            alertBanner(
                color: .red,
                icon: "exclamationmark.lock.fill",
                title: String(localized: "Accessibility permission required"),
                message: String(localized: "Text won't be typed automatically. Grant access in System Settings → Privacy → Accessibility."),
                actionLabel: String(localized: "Open Settings")
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
            let settings  = dictationController.loadSettings()
            let provider  = settings.byokProvider
            let hasSttKey = KeychainManager.shared.hasKey(for: provider)
            // TTS key: check for a dedicated TTS key or reuse STT key
            let hasTtsKey = KeychainManager.shared.getString(account: "spit-openai-tts-key") != nil || hasSttKey

            if !hasSttKey {
                alertBanner(
                    color: .red,
                    icon: "key.slash.fill",
                    title: "Chave de ditado em falta",
                    message: "O ditado está desativado. Adiciona a tua chave \(provider.displayName) em Definições → APIs.",
                    actionLabel: "Abrir Definições"
                ) {
                    if let delegate = NSApp.delegate as? AppDelegate { delegate.openSettings() }
                }
                Divider()
            }

            if !hasTtsKey {
                alertBanner(
                    color: .red,
                    icon: "speaker.slash.fill",
                    title: "Chave de leitura (TTS) em falta",
                    message: "A leitura em voz AI está desativada. Adiciona a tua chave OpenAI em Definições → APIs.",
                    actionLabel: "Abrir Definições"
                ) {
                    if let delegate = NSApp.delegate as? AppDelegate { delegate.openSettings() }
                }
                Divider()
            }
        }
    }

    // MARK: - Free Trial CTA

    @ViewBuilder
    private var freeTrialCTAView: some View {
        switch consumoState {
        case .trialExpired:
            trialCTABanner(
                title: String(localized: "Trial terminado!"),
                buttonLabel: String(localized: "Conheça os planos"),
                tint: .orange
            ) {
                if let delegate = NSApp.delegate as? AppDelegate { delegate.openSettings() }
            }
            Divider()
        case .trialNotStarted:
            trialCTABanner(
                title: String(localized: "Trial não iniciado!"),
                buttonLabel: String(localized: "Ative agora"),
                tint: .accentColor
            ) {
                OnboardingWindowController.shared.show()
            }
            Divider()
        default:
            EmptyView()
        }
    }

    private func trialCTABanner(
        title: String,
        buttonLabel: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(tint)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(tint)
                Spacer()
                // Refresh — force-sync com o servidor
                Button {
                    guard !isRefreshingLicense else { return }
                    isRefreshingLicense = true
                    Task {
                        await LicenseManager.shared.refreshStatus()
                        await MainActor.run { isRefreshingLicense = false }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isRefreshingLicense ? 360 : 0))
                        .animation(isRefreshingLicense ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isRefreshingLicense)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Verificar estado da licença"))
            }
            Button(buttonLabel, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(tint)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
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
            .help(String(localized: "Settings"))

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Quit Spit"))
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

    /// Dictation LED:
    /// 🟢 Verde   — idle (pronto) + a gravar
    /// 🟠 Laranja — a transcrever + a inserir texto
    /// 🔴 Vermelho — erro, offline (cloud), trial esgotado, chave inválida/em falta
    private var dictationStateColor: Color {
        switch dictationController.state {
        case .recording:
            return .green
        case .processing, .injecting:
            return .orange
        case .error:
            return .red
        case .idle:
            // Blocked conditions → red
            if licenseManager.trialExhausted { return .red }
            let s = dictationController.currentSettings
            if s.transcriptionEngine == .cloud && !networkMonitor.isOnline { return .red }
            if licenseManager.plan == .byok && !KeychainManager.shared.hasKey(for: s.byokProvider) { return .red }
            return .green
        }
    }

    private var dictationStateTooltip: String {
        switch dictationController.state {
        case .idle:
            if licenseManager.trialExhausted { return "Trial esgotado — faz upgrade para continuar" }
            let s = dictationController.currentSettings
            if s.transcriptionEngine == .cloud && !networkMonitor.isOnline { return "Sem internet — o ditado em nuvem não está disponível" }
            if licenseManager.plan == .byok && !KeychainManager.shared.hasKey(for: s.byokProvider) { return "Chave API em falta — configura em Definições → APIs" }
            return "Ditado pronto"
        case .recording:  return "A gravar…"
        case .processing: return "A transcrever…"
        case .injecting:  return "A inserir texto…"
        case .error(let m): return "Erro: \(m)"
        }
    }

    /// TTS LED:
    /// 🟢 Verde   — pronto para ler (inclui enquanto está a ler)
    /// 🔴 Vermelho — offline, trial esgotado, sem chave configurada, subscrição expirada
    private var ttsLEDColor: Color {
        if !networkMonitor.isOnline { return .red }
        if licenseManager.trialExhausted { return .red }
        if licenseManager.plan == .pro && licenseManager.monthlySecondsUsed >= licenseManager.proLimitSeconds { return .red }
        if licenseManager.plan == .byok {
            let s = dictationController.currentSettings
            let hasKey = KeychainManager.shared.getString(account: "spit-openai-tts-key") != nil
                || KeychainManager.shared.hasKey(for: s.byokProvider)
            if !hasKey { return .red }
        }
        return .green
    }

    private var ttsLEDTooltip: String {
        if !networkMonitor.isOnline { return "Sem internet — leitura não disponível" }
        if licenseManager.trialExhausted { return "Trial esgotado — faz upgrade para continuar" }
        if licenseManager.plan == .pro && licenseManager.monthlySecondsUsed >= licenseManager.proLimitSeconds { return "Limite mensal atingido" }
        if licenseManager.plan == .byok {
            let s = dictationController.currentSettings
            let hasKey = KeychainManager.shared.getString(account: "spit-openai-tts-key") != nil
                || KeychainManager.shared.hasKey(for: s.byokProvider)
            if !hasKey { return "Chave TTS em falta — configura em Definições → APIs" }
        }
        return ttsService.isSpeaking ? "A ler texto…" : "Leitura pronta"
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
