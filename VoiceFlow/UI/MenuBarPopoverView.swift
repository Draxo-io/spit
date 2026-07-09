import SwiftUI

// MARK: - MenuBarPopoverView
// Popover shown when clicking the menu bar icon.

struct MenuBarPopoverView: View {

    @EnvironmentObject var dictationController: DictationController
    @EnvironmentObject var creditsManager: CreditsManager
    @EnvironmentObject var vocabularyManager: VocabularyManager
    @ObservedObject private var ttsService: TTSService = .shared
    @ObservedObject private var localWhisper: LocalWhisperService = .shared
    @ObservedObject private var mlxTTS: MLXTTSService = .shared


    @State private var now: Date = Date()
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()


    private var lastResultVisible: Bool {
        guard let result = dictationController.lastResult else { return false }
        return now.timeIntervalSince(result.timestamp) < 300  // 5 minutes (SPEC §3.7)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            accessibilityWarningView   // banner vermelho quando AX não está concedida
            dictationBlockView
            Divider()
            ttsBlockView
            Divider()
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
            dictationController.recheckAccessibility()
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
        return VStack(alignment: .leading, spacing: 8) {

            // ── Cabeçalho: ícone + título + LED ──────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Digitação")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Circle()
                    .fill(dictationStateColor)
                    .frame(width: 6, height: 6)
                    .help(dictationStateTooltip)
                Spacer()
            }

            // ── Dicas de atalho ─────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text("Pressione a tecla de ação para iniciar · e novamente para parar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("ou mantenha pressionado (PTT)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── Status do modelo Whisper (só visível quando não está pronto) ──
            if localWhisper.isLoading {
                modelStatusRow(icon: "hourglass", text: "A carregar modelo IA…", color: .orange)
            } else if !localWhisper.isReady {
                modelStatusRow(icon: "cpu", text: "Modelo não carregado · será carregado ao usar", color: .secondary)
            }

            // ── Linha de tradução ───────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.7))
                Text("Tradução")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                Spacer(minLength: 0)
                if s.privacyModeEnabled {
                    privacyPill
                } else {
                    if s.autoTranslateEnabled {
                        translateTargetPicker(
                            current: s.autoTranslateTargetLanguage,
                            languages: availableLanguages.filter { $0.code != "auto" }
                        ) { code in
                            Task { await dictationController.setDictationTranslation(enabled: true, target: code) }
                        }
                    }
                    translateToggle(enabled: s.autoTranslateEnabled) {
                        let cur = dictationController.loadSettings()
                        Task {
                            await dictationController.setDictationTranslation(
                                enabled: !cur.autoTranslateEnabled,
                                target: cur.autoTranslateTargetLanguage
                            )
                        }
                    }
                }
            }

            // ── Último resultado ────────────────────────────────────────
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
        return VStack(alignment: .leading, spacing: 8) {

            // ── Cabeçalho: ícone + título + LED ──────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Leitura")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Circle()
                    .fill(ttsLEDColor)
                    .frame(width: 6, height: 6)
                    .help(ttsLEDTooltip)
                Spacer()
            }

            // ── Dica de atalho ──────────────────────────────────────────
            Text("Selecione texto e pressione a tecla de ação")
                .font(.caption)
                .foregroundColor(.secondary)

            // ── Status do modelo TTS (só visível quando carregando) ──────
            if mlxTTS.state == .loading {
                modelStatusRow(icon: "hourglass", text: "A carregar modelo de voz…", color: .orange)
            }

            // ── Linha de tradução ───────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.7))
                Text("Tradução")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary.opacity(0.85))
                Spacer(minLength: 0)
                if s.privacyModeEnabled {
                    privacyPill
                } else {
                    if s.ttsAutoTranslateEnabled {
                        translateTargetPicker(
                            current: s.ttsAutoTranslateTargetLanguage,
                            languages: availableLanguages.filter { $0.code != "auto" }
                        ) { code in
                            var updated = dictationController.loadSettings()
                            updated.ttsAutoTranslateTargetLanguage = code
                            dictationController.saveSettings(updated)
                        }
                    }
                    translateToggle(enabled: s.ttsAutoTranslateEnabled) {
                        var updated = dictationController.loadSettings()
                        updated.ttsAutoTranslateEnabled.toggle()
                        dictationController.saveSettings(updated)
                    }
                }
            }
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
                Text(enabled ? String(localized: "Ativada") : String(localized: "Desativada"))
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
            // Abre o Review HUD completo e fecha o painel do menu bar
            // (o user já decidiu — não fica nada útil para ele aqui).
            ReviewHUDWindowController.shared.showForLastResult(result)
            (NSApp.delegate as? AppDelegate)?.menuBarController?.closePanel()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(result.correctedText)
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Ícone "expandir para rever"
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .help("Rever — abre painel completo com original, tradução e edição")
    }

    // MARK: - Accessibility Warning

    @ViewBuilder
    private var accessibilityWarningView: some View {
        if !dictationController.isAccessibilityTrusted {
            alertBanner(
                color: .red,
                icon: "exclamationmark.lock.fill",
                title: String(localized: "menu.ax.banner.title", defaultValue: "Accessibility permission required"),
                message: String(localized: "menu.ax.banner.message", defaultValue: "Text won't be typed automatically. Grant access in System Settings → Privacy → Accessibility."),
                actionLabel: String(localized: "menu.ax.banner.action", defaultValue: "Open Settings")
            ) {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
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
    /// 🟢 Verde   — idle (modelo pronto) + a gravar
    /// 🟠 Laranja — a transcrever / a inserir / modelo a carregar
    /// ⚫ Cinzento — modelo descarregado (inativo, carrega ao usar)
    /// 🔴 Vermelho — erro
    private var dictationStateColor: Color {
        switch dictationController.state {
        case .recording:               return .green
        case .processing, .injecting:  return .orange
        case .error:                   return .red
        case .idle:
            if localWhisper.isLoading  { return .orange }
            if !localWhisper.isReady   { return .secondary.opacity(0.5) }
            return .green
        }
    }

    private var dictationStateTooltip: String {
        switch dictationController.state {
        case .idle:
            if localWhisper.isLoading  { return "A carregar modelo IA…" }
            if !localWhisper.isReady   { return "Modelo não carregado — será carregado ao usar" }
            return "Ditado pronto"
        case .recording:               return "A gravar…"
        case .processing:              return "A transcrever…"
        case .injecting:               return "A inserir texto…"
        case .error(let m):            return "Erro: \(m)"
        }
    }

    /// TTS LED:
    /// 🟢 Verde   — pronto (modelo em memória ou a falar)
    /// 🟠 Laranja — modelo a carregar
    /// ⚫ Cinzento — modelo em standby (carrega ao usar, ~2s)
    private var ttsLEDColor: Color {
        switch mlxTTS.state {
        case .loading:  return .orange
        case .ready:    return .green
        default:        return .secondary.opacity(0.4)
        }
    }

    private var ttsLEDTooltip: String {
        if ttsService.isSpeaking       { return "A ler texto…" }
        switch mlxTTS.state {
        case .loading:  return "A carregar modelo de voz…"
        case .ready:    return "Leitura pronta"
        default:        return "Modelo em standby — carrega ao usar (~2s)"
        }
    }

    // MARK: - Model status row

    private func modelStatusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(color)
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
