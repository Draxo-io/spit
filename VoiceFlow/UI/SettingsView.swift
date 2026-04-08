import SwiftUI
import Carbon

// MARK: - HotkeyDisplay helpers

/// Converts Carbon modifier flags → display symbols (e.g. "⌘⇧")
private func modifierSymbols(_ carbonMods: UInt32) -> String {
    var s = ""
    if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
    if carbonMods & UInt32(optionKey)  != 0 { s += "⌥" }
    if carbonMods & UInt32(shiftKey)   != 0 { s += "⇧" }
    if carbonMods & UInt32(cmdKey)     != 0 { s += "⌘" }
    return s
}

/// Maps a Carbon/NSEvent key code to a human-readable label.
/// Falls back to the character from the key event if available.
private func keyLabel(_ keyCode: UInt32) -> String {
    let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        63: "🌐",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
    return map[keyCode] ?? "?"
}

/// Keys that are safe to use without a modifier (won't intercept normal typing)
private func isSafeAloneKey(_ keyCode: UInt32) -> Bool {
    // § (10), Globe (63), F1–F12
    let safe: Set<UInt32> = [10, 63, 96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122]
    return safe.contains(keyCode)
}

/// Converts NSEvent.ModifierFlags → Carbon modifier flags
private func toCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var c: UInt32 = 0
    if flags.contains(.command) { c |= UInt32(cmdKey) }
    if flags.contains(.shift)   { c |= UInt32(shiftKey) }
    if flags.contains(.option)  { c |= UInt32(optionKey) }
    if flags.contains(.control) { c |= UInt32(controlKey) }
    return c
}

// MARK: - SettingsView

// MARK: - Tab enum

private enum SettingsTab: String, CaseIterable {
    case general    = "General"
    case license    = "License"
    case apiKey     = "API Key"
    case vocabulary = "Vocabulary"
    case history    = "History"
    case about      = "About"

    var icon: String {
        switch self {
        case .general:    return "gear"
        case .license:    return "checkmark.seal.fill"
        case .apiKey:     return "key.fill"
        case .vocabulary: return "text.badge.plus"
        case .history:    return "clock.arrow.circlepath"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    @EnvironmentObject var dictationController: DictationController
    @EnvironmentObject var creditsManager: CreditsManager
    @EnvironmentObject var vocabularyManager: VocabularyManager
    @ObservedObject private var historyManager: HistoryManager = .shared
    @ObservedObject private var licenseManager: LicenseManager = .shared
    @ObservedObject private var localWhisper: LocalWhisperService = .shared

    @State private var selectedTab: SettingsTab = .general
    @State private var settings: AppSettings = AppSettings.defaults
    @State private var apiKeyInput: String = ""
    @State private var apiKeyMasked: Bool = true
    @State private var showApiKeySavedAlert = false
    @State private var groqKeyInput: String = ""
    @State private var groqKeyMasked: Bool = true
    @State private var showGroqKeySavedAlert = false
    @State private var llmKeyInput: String = ""
    @State private var llmKeyMasked: Bool = true
    @State private var showLLMKeySavedAlert = false
    @State private var newVocabWrong = ""
    @State private var newVocabCorrect = ""
    @State private var newHintTerm = ""
    @State private var vocabMode: VocabMode = .substitution
    @State private var showRestartBanner = false
    @State private var editingEntryId: UUID? = nil
    @State private var editingText: String = ""

    // Toggle shortcut recorder state
    @State private var isRecordingShortcut = false
    @State private var shortcutEventMonitor: Any? = nil
    @State private var shortcutGlobeMonitor: Any? = nil   // flagsChanged para Globe
    @State private var shortcutConflict: String? = nil

    // TTS Read Selection shortcut recorder state
    @State private var isRecordingTTS = false
    @State private var ttsEventMonitor: Any? = nil
    @State private var ttsConflict: String? = nil
    @State private var availableVoices: [TTSVoiceOption] = []

    // Interface language options: (code, native name)
    private let interfaceLanguages: [(String, String)] = [
        ("system",   "System default"),
        ("en",       "English"),
        ("pt",       "Português (PT)"),
        ("pt-BR",    "Português (BR)"),
        ("es",       "Español"),
        ("fr",       "Français"),
        ("de",       "Deutsch"),
        ("it",       "Italiano"),
        ("ja",       "日本語"),
        ("zh-Hans",  "中文 (简体)"),
        ("ko",       "한국어"),
    ]

    enum VocabMode { case substitution, hint }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top toolbar ───────────────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 0)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // ── Content ───────────────────────────────────────────────────
            Group {
                switch selectedTab {
                case .general:    generalTab
                case .license:    licenseTab
                case .apiKey:     apiKeyTab
                case .vocabulary: vocabularyTab
                case .history:    historyTab
                case .about:      AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 500)
        .onAppear {
            settings = dictationController.loadSettings()
        }
    }

    // MARK: - Tab Button

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .regular))
                    .frame(width: 28, height: 28)
                Text(LocalizedStringKey(tab.rawValue))
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - License Tab

    @State private var activationToken: String = ""
    @State private var isActivating: Bool = false
    @State private var activationError: String? = nil
    @State private var activationSuccess: Bool = false

    private var licenseTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ── Local AI banner (shown when local engine is active) ────
                if settings.transcriptionEngine == .local {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu.fill")
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Using local AI — trial minutes are not consumed")
                                .font(.subheadline.weight(.medium))
                            Text("Switch to cloud in General → Local AI to use the trial or Pro plan.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.25)))
                    .cornerRadius(10)
                }

                // ── Current plan card ─────────────────────────────────────
                GroupBox {
                    HStack(spacing: 12) {
                        Image(systemName: planIcon)
                            .font(.system(size: 28))
                            .foregroundColor(planColor)
                            .frame(width: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(planTitle)
                                .font(.headline)
                            Text(planSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if licenseManager.plan == .trial {
                            Text("\(licenseManager.trialMinutesRemaining) min left")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(licenseManager.trialExhausted ? .red : .secondary)
                                .padding(6)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.vertical, 4)

                    // Trial progress bar
                    if licenseManager.plan == .trial {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(
                                value: licenseManager.trialSecondsUsed,
                                total: licenseManager.trialLimitSeconds
                            )
                            .tint(licenseManager.trialExhausted ? .red : .accentColor)
                            Text(String(format: "%.0f / 60 min used", licenseManager.trialSecondsUsed / 60))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 6)
                    }

                    // Pro monthly usage
                    if licenseManager.plan == .pro {
                        VStack(alignment: .leading, spacing: 4) {
                            let usedH = licenseManager.monthlySecondsUsed / 3600
                            let totalH = licenseManager.proLimitSeconds / 3600
                            ProgressView(value: licenseManager.monthlySecondsUsed, total: licenseManager.proLimitSeconds)
                                .tint(.accentColor)
                            Text(String(format: "%.1fh / %.0fh used this month", usedH, totalH))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 6)
                    }
                }

                // ── Upgrade CTA (trial only) ──────────────────────────────
                if licenseManager.plan == .trial {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Upgrade Spit")
                                .font(.subheadline.weight(.semibold))

                            HStack(spacing: 12) {
                                upgradeOption(
                                    title: "Pro",
                                    price: "$4.99/mês",
                                    detail: "~20h/mês · chave nossa",
                                    url: "https://getspit.app/buy/pro"
                                )
                                upgradeOption(
                                    title: "BYOK",
                                    price: "$49 único",
                                    detail: "Ilimitado · chave tua",
                                    url: "https://getspit.app/buy/byok"
                                )
                            }

                            Text("Após o pagamento recebes um email com o link de ativação.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // ── Activate license ──────────────────────────────────────
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ativar licença")
                            .font(.subheadline.weight(.semibold))

                        Text("O link de ativação no email abre a app automaticamente. Se preferires, cola o token aqui:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            TextField("Token de ativação", text: $activationToken)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isActivating)

                            Button {
                                if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                                    activationToken = str.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard").font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("Colar da área de transferência")
                        }

                        if let err = activationError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }

                        if activationSuccess {
                            Label("Licença ativada com sucesso!", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }

                        Button {
                            guard !activationToken.isEmpty else { return }
                            isActivating = true
                            activationError = nil
                            activationSuccess = false
                            Task {
                                do {
                                    try await LicenseManager.shared.activate(token: activationToken.trimmingCharacters(in: .whitespacesAndNewlines))
                                    await MainActor.run {
                                        activationSuccess = true
                                        activationToken = ""
                                        isActivating = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        activationError = error.localizedDescription
                                        isActivating = false
                                    }
                                }
                            }
                        } label: {
                            if isActivating {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("A ativar…")
                                }
                            } else {
                                Text("Ativar")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(activationToken.isEmpty || isActivating)
                    }
                    .padding(.vertical, 4)
                }

                // ── Deactivate (pro/byok only) ────────────────────────────
                if licenseManager.isActivated {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Desativar este dispositivo")
                                .font(.subheadline.weight(.semibold))
                            Text("Remove a licença deste Mac. Podes ativar noutro dispositivo sem perder o teu plano.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Desativar") {
                                Task { await LicenseManager.shared.deactivate() }
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    // MARK: - License helpers

    private var planIcon: String {
        switch licenseManager.plan {
        case .trial: return "clock.badge"
        case .pro:   return "star.circle.fill"
        case .byok:  return "key.horizontal.fill"
        }
    }

    private var planColor: Color {
        switch licenseManager.plan {
        case .trial: return .orange
        case .pro:   return .accentColor
        case .byok:  return .green
        }
    }

    private var planTitle: String {
        switch licenseManager.plan {
        case .trial: return String(localized: "Trial gratuito")
        case .pro:   return "Spit Pro"
        case .byok:  return "Spit BYOK"
        }
    }

    private var planSubtitle: String {
        switch licenseManager.plan {
        case .trial: return String(localized: "60 minutos grátis")
        case .pro:   return String(localized: "~20h/mês · $4.99/mês")
        case .byok:  return String(localized: "Ilimitado · chave própria")
        }
    }

    @ViewBuilder
    private func upgradeOption(title: String, price: String, detail: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(price).font(.title3.weight(.bold)).foregroundColor(.accentColor)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.06))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Voice Recognition") {
                Picker("Language", selection: $settings.language) {
                    Text("Portuguese (PT)").tag("pt")
                    Text("Portuguese (BR)").tag("pt-BR")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("Auto-detect").tag("auto")
                }
                .onChange(of: settings.language) { _ in save() }

                Picker("Interface Language", selection: $settings.interfaceLanguage) {
                    ForEach(interfaceLanguages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .onChange(of: settings.interfaceLanguage) { _ in
                    save()
                    showRestartBanner = true
                }
            }

            if showRestartBanner {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restart required")
                                .font(.subheadline).fontWeight(.medium)
                            Text("Restart Spit to apply the language change.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            showRestartBanner = false
                        } label: {
                            Image(systemName: "xmark").font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Behaviour") {
                Toggle("Show review panel after dictation", isOn: $settings.showReviewHUD)
                    .onChange(of: settings.showReviewHUD) { _ in save() }

                Toggle("Play sound feedback on start", isOn: $settings.playSoundFeedback)
                    .onChange(of: settings.playSoundFeedback) { _ in save() }

                Toggle("Warn when no active text field", isOn: $settings.autoDetectFocus)
                    .onChange(of: settings.autoDetectFocus) { _ in save() }

                Toggle(isOn: $settings.autoparagraphEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-format paragraphs")
                            .fontWeight(.medium)
                        let available = settings.transcriptionEngine == .cloud ||
                            !KeychainManager.shared.hasKey(for: settings.byokProvider) == false
                        Text(available
                             ? "LLM post-processing adds paragraphs and punctuation (uses STT key)."
                             : "Requires an OpenAI or Groq API key.")
                            .font(.caption)
                            .foregroundColor(available ? .secondary : .orange)
                    }
                }
                .onChange(of: settings.autoparagraphEnabled) { _ in save() }
                .disabled({
                    // Disabled if BYOK and no key present
                    if settings.transcriptionEngine == .cloud { return false }
                    return !KeychainManager.shared.hasKey(for: settings.byokProvider)
                }())
            }

            Section("Auto-stop on Silence") {
                Toggle("Stop recording automatically when silent", isOn: $settings.silenceAutoStopEnabled)
                    .onChange(of: settings.silenceAutoStopEnabled) { _ in save() }

                if settings.silenceAutoStopEnabled {
                    HStack {
                        Text("Silence duration")
                        Spacer()
                        Stepper(
                            value: $settings.silenceAutoStopSeconds,
                            in: 1.0...10.0,
                            step: 0.5
                        ) {
                            Text("\(settings.silenceAutoStopSeconds, specifier: "%.1f")s")
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        .onChange(of: settings.silenceAutoStopSeconds) { _ in save() }
                    }
                    Text("Recording stops automatically after this many seconds of silence.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Keyboard Shortcut") {
                shortcutRow
                smartHotkeyInfo
            }

            Section {
                ttsSection
            } header: {
                Label("Read Selection", systemImage: "speaker.wave.2")
            }

            Section {
                localAISection
            } header: {
                Label("Local AI", systemImage: "cpu")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Local AI Section

    private var localAISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { settings.transcriptionEngine == .local },
                set: { on in
                    settings.transcriptionEngine = on ? .local : .cloud
                    save()
                    if on {
                        Task { await LocalWhisperService.shared.load(model: settings.localModel) }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use on-device model")
                        .fontWeight(.medium)
                    Text("Free, unlimited, offline — processes audio entirely on your Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.transcriptionEngine == .local {
                Divider()
                localModelPicker
            }
        }
        .padding(.vertical, 4)
    }

    private var localModelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Axis label
            HStack {
                Label("Faster", systemImage: "bolt.fill")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Label("More accurate", systemImage: "star.fill")
                    .font(.caption2).foregroundColor(.secondary)
            }

            // Model cards
            HStack(spacing: 6) {
                ForEach(LocalWhisperModel.allCases, id: \.self) { model in
                    LocalModelCard(
                        model: model,
                        isSelected: settings.localModel == model,
                        onTap: {
                            settings.localModel = model
                            save()
                            Task { await LocalWhisperService.shared.load(model: model) }
                        }
                    )
                }
            }

            // Download / status row
            HStack(spacing: 8) {
                if localWhisper.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    Text("Loading model…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if localWhisper.isReady && localWhisper.loadedModel == settings.localModel {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Ready")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    if let err = localWhisper.errorMessage {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(2)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text("\(settings.localModel.sizeLabel) download")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await LocalWhisperService.shared.load(model: settings.localModel) }
                    } label: {
                        Text(localWhisper.errorMessage != nil ? "Retry" : "Load model")
                            .font(.caption)
                    }
                    .disabled(localWhisper.isLoading)
                }
                Spacer()
            }
        }
    }

    // MARK: - API Key Tab

    private var apiKeyTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Current Status") {
                HStack {
                    Image(systemName: creditsManager.mode == .userKey ? "checkmark.circle.fill" : "clock.circle.fill")
                        .foregroundColor(creditsManager.mode == .userKey ? .green : .orange)
                    Text(creditsManager.statusMessage)
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            if creditsManager.mode == .freeTrial {
                GroupBox("Free Trial") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Minutes used:")
                            Spacer()
                            Text("\(Int(creditsManager.minutesUsed)) / \(Int(creditsManager.freeTrialMinutesTotal)) min")
                                .font(.subheadline)
                        }
                        ProgressView(value: creditsManager.minutesUsed,
                                     total: creditsManager.freeTrialMinutesTotal)
                            .tint(creditsManager.freeTrialExhausted ? .red : .accentColor)
                    }
                    .padding(.vertical, 4)
                }
            }

            if creditsManager.mode == .userKey {
                GroupBox("Usage & Cost Estimate") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("This month:")
                            Spacer()
                            let mMins = Int(creditsManager.monthlySecondsTranscribed / 60)
                            let mSecs = Int(creditsManager.monthlySecondsTranscribed) % 60
                            Text(mMins > 0 ? "\(mMins) min \(mSecs)s" : "\(mSecs)s")
                                .font(.subheadline)
                        }
                        HStack {
                            Text("Estimated cost (USD):")
                            Spacer()
                            Text(creditsManager.estimatedMonthlyCostFormatted)
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        HStack {
                            Text("Lifetime transcribed:")
                            Spacer()
                            let tMins = Int(creditsManager.totalSecondsTranscribed / 60)
                            let tSecs = Int(creditsManager.totalSecondsTranscribed) % 60
                            Text(tMins > 0 ? "\(tMins) min \(tSecs)s" : "\(tSecs)s")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        Text("OpenAI charges $0.006 USD/min. Resets on the 1st of each month.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            GroupBox("BYOK — Bring Your Own Key") {
                VStack(alignment: .leading, spacing: 14) {

                    // Provider picker
                    Picker("Provider", selection: Binding(
                        get: { settings.byokProvider },
                        set: { settings.byokProvider = $0; save() }
                    )) {
                        ForEach([BYOKProvider.openai, .groq], id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    if settings.byokProvider == .openai {
                        byokKeySection(
                            label: "OpenAI key",
                            placeholder: "sk-...",
                            prefix: "sk-",
                            keyInput: $apiKeyInput,
                            masked: $apiKeyMasked,
                            hasSavedKey: creditsManager.hasUserAPIKey,
                            costLabel: BYOKProvider.openai.costLabel,
                            docsURL: BYOKProvider.openai.docsURL,
                            onSave: {
                                if creditsManager.activateUserKey(apiKeyInput) {
                                    showApiKeySavedAlert = true; apiKeyInput = ""
                                }
                            },
                            onRemove: { creditsManager.removeUserKey() }
                        )
                    } else {
                        byokKeySection(
                            label: "Groq key",
                            placeholder: "gsk_...",
                            prefix: "gsk_",
                            keyInput: $groqKeyInput,
                            masked: $groqKeyMasked,
                            hasSavedKey: KeychainManager.shared.hasGroqKey,
                            costLabel: BYOKProvider.groq.costLabel,
                            docsURL: BYOKProvider.groq.docsURL,
                            onSave: {
                                if KeychainManager.shared.saveGroqKey(groqKeyInput) {
                                    showGroqKeySavedAlert = true; groqKeyInput = ""
                                }
                            },
                            onRemove: { KeychainManager.shared.deleteGroqKey() }
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            // ── LLM key para formatação (só quando STT é local) ──────────
            if settings.transcriptionEngine == .local {
                llmKeySection
            }

            Spacer()
        }
        .padding()
        .alert("Key saved!", isPresented: $showApiKeySavedAlert) { Button("OK") {} }
        .alert("Groq key saved!", isPresented: $showGroqKeySavedAlert) { Button("OK") {} }
        .alert("LLM key saved!", isPresented: $showLLMKeySavedAlert) { Button("OK") {} }
    }

    @ViewBuilder
    private func byokKeySection(
        label: String, placeholder: String, prefix: String,
        keyInput: Binding<String>, masked: Binding<Bool>,
        hasSavedKey: Bool, costLabel: String, docsURL: URL,
        onSave: @escaping () -> Void, onRemove: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use your own \(label) for unlimited usage.")
                .font(.caption).foregroundColor(.secondary)

            HStack {
                Group {
                    if masked.wrappedValue {
                        SecureField(placeholder, text: keyInput)
                    } else {
                        TextField(placeholder, text: keyInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button { masked.wrappedValue.toggle() } label: {
                    Text(masked.wrappedValue ? "Show" : "Hide")
                }
                .buttonStyle(.plain).font(.caption).foregroundColor(.secondary)
            }

            HStack {
                Button("Save Key", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(keyInput.wrappedValue.isEmpty || !keyInput.wrappedValue.hasPrefix(prefix))

                if hasSavedKey {
                    Button("Remove Key", action: onRemove)
                        .buttonStyle(.bordered).foregroundColor(.red)
                }
            }

            Text(costLabel).font(.caption2).foregroundColor(.secondary)

            Link("Get your key →", destination: docsURL)
                .font(.caption)
        }
    }

    // MARK: - LLM Key Section (local STT only)

    private var llmKeySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "cpu.fill")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LLM para formatação de parágrafos")
                            .font(.subheadline.weight(.semibold))
                        Text("Necessário para a função \"Auto-format paragraphs\" quando usas IA local (sem chave STT).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                let hasKey = KeychainManager.shared.getString(account: "spit-llm-key") != nil
                byokKeySection(
                    label: "OpenAI ou Groq key",
                    placeholder: "sk-... ou gsk_...",
                    prefix: "sk-",   // Accept both prefixes — save unconditionally
                    keyInput: $llmKeyInput,
                    masked: $llmKeyMasked,
                    hasSavedKey: hasKey,
                    costLabel: "Aceita chaves OpenAI (sk-...) ou Groq (gsk_...). Utiliza GPT-4o-mini ou llama-3.1-8b-instant.",
                    docsURL: URL(string: "https://platform.openai.com/api-keys")!,
                    onSave: {
                        let trimmed = llmKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        KeychainManager.shared.saveString(trimmed, account: "spit-llm-key")
                        showLLMKeySavedAlert = true
                        llmKeyInput = ""
                    },
                    onRemove: {
                        KeychainManager.shared.deleteString(account: "spit-llm-key")
                    }
                )
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Vocabulary Tab

    private var vocabularyTab: some View {
        VStack(alignment: .leading, spacing: 10) {

            // Mode picker
            Picker("", selection: $vocabMode) {
                Text("Substitutions").tag(VocabMode.substitution)
                Text("Whisper Hints").tag(VocabMode.hint)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            if vocabMode == .substitution {
                substitutionSection
            } else {
                hintSection
            }
        }
    }

    private var substitutionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Replace words Whisper gets wrong with the correct form.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            HStack {
                TextField("Whisper writes…", text: $newVocabWrong)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                HStack(spacing: 2) {
                    TextField("Should be…", text: $newVocabCorrect)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                            newVocabCorrect = str.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Paste from clipboard")
                }
                Button {
                    guard !newVocabWrong.isEmpty && !newVocabCorrect.isEmpty else { return }
                    vocabularyManager.add(wrong: newVocabWrong, correct: newVocabCorrect)
                    newVocabWrong = ""
                    newVocabCorrect = ""
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newVocabWrong.isEmpty || newVocabCorrect.isEmpty)
            }
            .padding(.horizontal)

            let substitutions = vocabularyManager.entries.filter { !$0.hintOnly }
            if substitutions.isEmpty {
                emptyState(icon: "arrow.left.arrow.right",
                           message: "No substitutions yet",
                           detail: "Add one above, or edit text in the review panel — Spit learns automatically.")
            } else {
                List {
                    ForEach(substitutions) { entry in
                        HStack(spacing: 6) {
                            Text(entry.wrong).strikethrough().foregroundColor(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                            if editingEntryId == entry.id {
                                TextField("", text: $editingText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitSubstitutionEdit(entry: entry) }
                                Button { commitSubstitutionEdit(entry: entry) } label: {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    editingEntryId = nil
                                    editingText = ""
                                } label: {
                                    Image(systemName: "xmark.circle").foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(entry.correct).fontWeight(.medium)
                                Spacer()
                                Button {
                                    editingEntryId = entry.id
                                    editingText = entry.correct
                                } label: {
                                    Image(systemName: "pencil").foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Edit")
                                Button { vocabularyManager.delete(entry) } label: {
                                    Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .help("Delete")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func commitSubstitutionEdit(entry: VocabularyEntry) {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = entry
        updated.correct = trimmed
        vocabularyManager.update(updated)
        editingEntryId = nil
        editingText = ""
    }

    private var hintSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terms sent to Whisper as context — no automatic substitution. Use for product names that sound like common words (e.g. MEMSAGE sounds like \"mensagem\").")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            HStack {
                TextField("Term to recognise (e.g. MEMSAGE)", text: $newHintTerm)
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !newHintTerm.isEmpty else { return }
                    vocabularyManager.addHint(newHintTerm)
                    newHintTerm = ""
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newHintTerm.isEmpty)
            }
            .padding(.horizontal)

            let hints = vocabularyManager.entries.filter { $0.hintOnly }
            if hints.isEmpty {
                emptyState(icon: "waveform.badge.magnifyingglass",
                           message: "No hints yet",
                           detail: "Add product names, project names, or proper nouns that Whisper struggles with.")
            } else {
                List {
                    ForEach(hints) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").font(.caption).foregroundColor(.accentColor)
                            if editingEntryId == entry.id {
                                TextField("", text: $editingText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitHintEdit(entry: entry) }
                                Button { commitHintEdit(entry: entry) } label: {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                                Button {
                                    editingEntryId = nil
                                    editingText = ""
                                } label: {
                                    Image(systemName: "xmark.circle").foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(entry.correct).fontWeight(.medium)
                                Spacer()
                                Text("hint only").font(.caption2).foregroundColor(.secondary)
                                Button {
                                    editingEntryId = entry.id
                                    editingText = entry.correct
                                } label: {
                                    Image(systemName: "pencil").foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Edit")
                                Button { vocabularyManager.delete(entry) } label: {
                                    Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                                .help("Delete")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func commitHintEdit(entry: VocabularyEntry) {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = entry
        updated.correct = trimmed
        vocabularyManager.update(updated)
        editingEntryId = nil
        editingText = ""
    }

    private func emptyState(icon: String, message: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.largeTitle).foregroundColor(.secondary)
            Text(message).foregroundColor(.secondary)
            Text(detail).font(.caption).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(spacing: 0) {
            if historyManager.entries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No dictations yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Your last 50 transcriptions will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding()
            } else {
                HStack {
                    Text("\(historyManager.entries.count) transcription\(historyManager.entries.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Clear All") {
                        historyManager.clear()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

                List {
                    ForEach(historyManager.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.date, style: .relative)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(entry.wordCount) words")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("·")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(Int(entry.duration))s")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy to clipboard")
                            }
                            Text(entry.text)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        offsets.map { historyManager.entries[$0] }.forEach {
                            historyManager.delete($0)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Smart Hotkey Info

    /// Inline explanation of the unified PTT+Toggle behavior (replaces the old PTT toggle)
    private var smartHotkeyInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Smart tap + hold")
                        .fontWeight(.medium)
                    Text("Tap quickly → toggle recording on/off.\nHold ≥ 0.5s → push-to-talk: records while held, stops on release.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "hand.tap.fill")
                    .foregroundColor(.accentColor)
            }
        }
    }

    // MARK: - TTS Read Selection Section

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { settings.ttsHotkeyEnabled },
                set: { enabled in
                    settings.ttsHotkeyEnabled = enabled
                    save()
                    dictationController.updateTTSHotkey(
                        enabled: enabled,
                        keyCode: settings.ttsHotkeyKeyCode,
                        modifiers: settings.ttsHotkeyModifiers
                    )
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read selected text aloud")
                        .font(.body)
                    Text("Uses macOS system voice. Press the shortcut while text is selected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if settings.ttsHotkeyEnabled {
                // Shortcut row
                HStack(spacing: 10) {
                    Text("Shortcut")
                        .foregroundColor(.secondary)
                    Spacer()

                    if isRecordingTTS {
                        Text("Press shortcut…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                    .background(Color.accentColor.opacity(0.06).cornerRadius(6))
                            )
                        Button("Cancel") { stopRecordingTTS() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 3) {
                            let mods = modifierSymbols(settings.ttsHotkeyModifiers)
                            let key  = keyLabel(settings.ttsHotkeyKeyCode)
                            ForEach(Array(mods.enumerated()), id: \.offset) { _, ch in keyBadge(String(ch)) }
                            keyBadge(key)
                        }
                        Button("Change") { startRecordingTTS() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if let conflict = ttsConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // Voice picker
                if !availableVoices.isEmpty {
                    HStack(spacing: 10) {
                        Text("Voice")
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { settings.ttsVoiceIdentifier },
                            set: { id in
                                settings.ttsVoiceIdentifier = id
                                TTSService.shared.voiceIdentifier = id
                                save()
                            }
                        )) {
                            Text("System default").tag("")
                            Divider()
                            ForEach(availableVoices) { voice in
                                Text("\(voice.name)  \(voice.languageTag)")
                                    .tag(voice.identifier)
                            }
                        }
                        .frame(maxWidth: 220)
                        .labelsHidden()
                    }
                }
            }
        }
        .onAppear {
            if availableVoices.isEmpty { availableVoices = TTSVoiceOption.all() }
            TTSService.shared.voiceIdentifier = settings.ttsVoiceIdentifier
        }
        .onDisappear { stopRecordingTTS() }
    }

    private func startRecordingTTS() {
        ttsConflict = nil
        isRecordingTTS = true

        ttsEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [self] event in
            if event.keyCode == 53 { stopRecordingTTS(); return nil }

            let carbonKey = UInt32(event.keyCode)
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

            if mods.isEmpty && !isSafeAloneKey(carbonKey) {
                ttsConflict = "Add a modifier (⌘ ⌥ ⌃ ⇧) or use §, 🌐, or an F-key"
                return nil
            }

            applyNewTTSShortcut(keyCode: carbonKey, modifiers: toCarbonModifiers(mods))
            return nil
        }
    }

    private func applyNewTTSShortcut(keyCode: UInt32, modifiers: UInt32) {
        stopRecordingTTS()
        ttsConflict = nil
        settings.ttsHotkeyKeyCode = keyCode
        settings.ttsHotkeyModifiers = modifiers
        save()
        dictationController.updateTTSHotkey(
            enabled: settings.ttsHotkeyEnabled,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    private func stopRecordingTTS() {
        isRecordingTTS = false
        if let m = ttsEventMonitor { NSEvent.removeMonitor(m); ttsEventMonitor = nil }
    }

    // MARK: - Shortcut Row

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Dictation shortcut")
                Spacer()

                if isRecordingShortcut {
                    // Recording mode
                    Text("Press shortcut…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                .background(Color.accentColor.opacity(0.06)
                                    .cornerRadius(6))
                        )
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                   value: isRecordingShortcut)

                    Button("Cancel") { stopRecordingShortcut(save: false) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)

                } else {
                    // Display current shortcut as key badges
                    HStack(spacing: 3) {
                        let mods = modifierSymbols(settings.hotkeyModifiers)
                        let key  = keyLabel(settings.hotkeyKeyCode)
                        // show each modifier char as separate badge
                        ForEach(Array(mods.enumerated()), id: \.offset) { _, ch in
                            keyBadge(String(ch))
                        }
                        keyBadge(key)
                    }

                    Button("Change") { startRecordingShortcut() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            // Conflict warning
            if let conflict = shortcutConflict {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .onDisappear { stopRecordingShortcut(save: false) }
    }

    private func keyBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15))
            .cornerRadius(5)
    }

    // MARK: - Shortcut Recording

    private func startRecordingShortcut() {
        shortcutConflict = nil
        isRecordingShortcut = true

        // Globe key (keyCode 63) não gera .keyDown — usa .flagsChanged
        shortcutGlobeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [self] event in
            guard event.keyCode == 63 else { return event }
            // Só reagir ao press (flag .function a aparecer), não ao release
            if event.modifierFlags.contains(.function) {
                applyNewShortcut(keyCode: 63, modifiers: 0)
            }
            return nil
        }

        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [self] event in
            // Escape = cancelar
            if event.keyCode == 53 {
                stopRecordingShortcut(save: false)
                return nil
            }

            let carbonKey = UInt32(event.keyCode)
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Permitir sem modificador apenas para teclas "seguras" (§, F-keys)
            if mods.isEmpty && !isSafeAloneKey(carbonKey) {
                shortcutConflict = "Add a modifier (⌘ ⌥ ⌃ ⇧) or use §, 🌐, or an F-key"
                return nil
            }

            applyNewShortcut(keyCode: carbonKey, modifiers: toCarbonModifiers(mods))
            return nil
        }
    }

    private func applyNewShortcut(keyCode: UInt32, modifiers: UInt32) {
        stopRecordingShortcut(save: false)
        shortcutConflict = nil
        settings.hotkeyKeyCode = keyCode
        settings.hotkeyModifiers = modifiers
        save()
        dictationController.updateHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    private func stopRecordingShortcut(save _: Bool) {
        isRecordingShortcut = false
        if let m = shortcutEventMonitor { NSEvent.removeMonitor(m); shortcutEventMonitor = nil }
        if let m = shortcutGlobeMonitor { NSEvent.removeMonitor(m); shortcutGlobeMonitor = nil }
    }

    // MARK: - Save

    private func save() {
        dictationController.saveSettings(settings)
    }
}

// MARK: - LocalModelCard

private struct LocalModelCard: View {
    let model: LocalWhisperModel
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Text(model.displayName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)

            // Speed dots (bolt icons)
            HStack(spacing: 1) {
                ForEach(0..<4, id: \.self) { i in
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7))
                        .foregroundColor(i < model.speedRank ? .yellow : Color.secondary.opacity(0.2))
                }
            }

            // Quality dots (star icons)
            HStack(spacing: 1) {
                ForEach(0..<4, id: \.self) { i in
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                        .foregroundColor(i < model.qualityRank ? .accentColor : Color.secondary.opacity(0.2))
                }
            }

            Text(model.sizeLabel)
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Text(model.typicalLatency)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.12)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - TTSVoiceOption

struct TTSVoiceOption: Identifiable {
    let id: String
    let identifier: String   // e.g. "com.apple.voice.compact.pt-BR.Luciana"
    let name: String         // e.g. "Luciana"
    let languageTag: String  // e.g. "pt-BR"

    static func all() -> [TTSVoiceOption] {
        NSSpeechSynthesizer.availableVoices
            .compactMap { voice -> TTSVoiceOption? in
                let attrs = NSSpeechSynthesizer.attributes(forVoice: voice)
                guard
                    let name = attrs[NSSpeechSynthesizer.VoiceAttributeKey.name] as? String,
                    let locale = attrs[NSSpeechSynthesizer.VoiceAttributeKey.localeIdentifier] as? String
                else { return nil }
                return TTSVoiceOption(
                    id: voice.rawValue,
                    identifier: voice.rawValue,
                    name: name,
                    languageTag: locale.replacingOccurrences(of: "_", with: "-")
                )
            }
            .sorted { $0.languageTag < $1.languageTag }
    }
}
