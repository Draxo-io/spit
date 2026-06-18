import SwiftUI
import Carbon
import ServiceManagement

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
    case general    = "Geral"
    case dictation  = "Ditado"
    case reading    = "Leitura"
    case vocabulary = "Vocabulário"
    case about      = "Sobre"

    var icon: String {
        switch self {
        case .general:    return "gear"
        case .dictation:  return "mic.fill"
        case .reading:    return "speaker.wave.2.fill"
        case .vocabulary: return "text.badge.plus"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {

    @EnvironmentObject var dictationController: DictationController
    @EnvironmentObject var creditsManager: CreditsManager
    @EnvironmentObject var vocabularyManager: VocabularyManager
    @ObservedObject private var licenseManager: LicenseManager = .shared
    @ObservedObject private var localWhisper: LocalWhisperService = .shared

    @State private var selectedTab: SettingsTab = .general
    @State private var settings: AppSettings = {
        guard let data = UserDefaults.standard.data(forKey: "appSettings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings.defaults
        }
        return s
    }()
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

    // (TTS uses the same hotkey as dictation — no separate recorder needed)
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

    // Restart banner strings shown in the *newly selected* language (before restart)
    private var restartBannerTitle: String {
        settings.interfaceLanguage == "en" ? "Restart required" : "Reinício necessário"
    }
    private var restartBannerBody: String {
        settings.interfaceLanguage == "en"
            ? "Restart Spit to apply the language change."
            : "Reinicia o Spit para aplicar a alteração de idioma."
    }
    private var restartBannerButton: String {
        settings.interfaceLanguage == "en" ? "Restart Now" : "Reiniciar agora"
    }

    private func relaunchApp() {
        let path = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        // Espera o processo actual morrer ANTES de abrir o novo, senão o guard
        // de instância-única (AppDelegate.applicationWillFinishLaunching) mata a
        // nova instância por detectar a antiga ainda viva.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top toolbar ───────────────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(visibleTabs, id: \.self) { tab in
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
                case .dictation:  dictationTab
                case .reading:    readingTab
                case .vocabulary: vocabularyTab
                case .about:      AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 520)
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
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())   // garante que todo o rectângulo responde ao clique
        }
        .buttonStyle(.plain)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section {
                shortcutRow
                actionKeyInfo
            } header: {
                Label("Teclas de ação", systemImage: "keyboard")
            }

            Section("Interface") {
                Picker("Idioma da interface", selection: $settings.interfaceLanguage) {
                    ForEach(interfaceLanguages, id: \.0) { code, name in
                        Text(name).tag(code)
                    }
                }
                .onChange(of: settings.interfaceLanguage) { newValue in
                    save()
                    // Escreve já a preferência de idioma para o domínio da app,
                    // para que UM único reinício seja suficiente. Se ficasse só
                    // para o applicationWillFinishLaunching, o Foundation já teria
                    // cacheado a localização do bundle e seriam precisos DOIS
                    // reinícios para a mudança "apanhar".
                    if newValue == "system" {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    }
                    UserDefaults.standard.synchronize()
                    showRestartBanner = true
                }
            }

            if showRestartBanner {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(restartBannerTitle)
                                .font(.subheadline).fontWeight(.medium)
                            Text(restartBannerBody)
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(restartBannerButton) {
                            relaunchApp()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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

            Section("Sistema") {
                Toggle("Iniciar com o Mac", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { enabled in
                        save()
                        applyLaunchAtLogin(enabled)
                    }

                Toggle("Som de feedback ao iniciar/terminar gravação", isOn: $settings.playSoundFeedback)
                    .onChange(of: settings.playSoundFeedback) { _ in save() }

                Toggle("Pausar reprodução ao ditar/ler", isOn: $settings.muteAudioOnActivity)
                    .onChange(of: settings.muteAudioOnActivity) { _ in save() }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { TelemetryService.shared.vocabularyConsentGiven },
                    set: { TelemetryService.shared.vocabularyConsentGiven = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Partilhar vocabulário")
                        Text("As tuas substituições são enviadas anonimamente para melhorar o reconhecimento de nomes e termos técnicos.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label("Contribuição", systemImage: "arrow.up.heart")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                vfLog("LaunchAtLogin error: \(error)")
            }
        }
    }

    // MARK: - Dictation Tab

    private var dictationTab: some View {
        Form {
            // MARK: Modelo local
            Section {
                localModelPicker
            } header: {
                Label("Modelo de reconhecimento", systemImage: "cpu.fill")
            }

            // MARK: Aprimoramento de Texto
            Section {
                Toggle(isOn: $settings.autoparagraphEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parágrafo automático")
                        Text("Estrutura o texto em parágrafos com saudação e fecho")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: settings.autoparagraphEnabled) { _ in save() }

            } header: {
                Label("Aprimoramento de texto", systemImage: "wand.and.stars")
            }

        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Reading Tab

    private var readingTab: some View {
        Form {
            Section("Leitura por voz") {
                Toggle("Ativar leitura por voz", isOn: $settings.ttsEnabled)
                    .onChange(of: settings.ttsEnabled) { _ in save() }
            }

            if settings.ttsEnabled {
                Section("Voz") {
                    ttsSection
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Privacy Tab

    // localAISection removed — model picker moved to APIs tab

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

    // MARK: - Vocabulary Tab

    private var vocabularyTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $vocabMode) {
                Text("Substituições").tag(VocabMode.substitution)
                Text("Dicas de reconhecimento").tag(VocabMode.hint)
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
        .onAppear { seedDefaultHintsIfNeeded() }
    }

    /// Pré-configura "Spit" como dica de reconhecimento no primeiro lançamento.
    private func seedDefaultHintsIfNeeded() {
        let hasSeeded = UserDefaults.standard.bool(forKey: "vocab_hints_seeded")
        guard !hasSeeded else { return }
        if !vocabularyManager.entries.contains(where: { $0.hintOnly && $0.correct == "Spit" }) {
            vocabularyManager.addHint("Spit")
        }
        UserDefaults.standard.set(true, forKey: "vocab_hints_seeded")
    }

    private var substitutionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Corrige palavras que a IA transcreve mal.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            HStack(spacing: 6) {
                // Campo "escreve" — aceita Cmd+V nativamente com NSTextField
                TextField("escreve…", text: $newVocabWrong)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSubstitutionIfValid() }

                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)

                TextField("deve ser…", text: $newVocabCorrect)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSubstitutionIfValid() }

                Button(action: addSubstitutionIfValid) {
                    Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newVocabWrong.isEmpty || newVocabCorrect.isEmpty)
            }
            .padding(.horizontal)

            let substitutions = vocabularyManager.entries.filter { !$0.hintOnly }
            if substitutions.isEmpty {
                emptyState(icon: "arrow.left.arrow.right",
                           message: "Sem substituições",
                           detail: "Adiciona acima, ou corrige texto no painel de revisão — o Spit aprende automaticamente.")
            } else {
                List {
                    ForEach(substitutions) { entry in
                        HStack(spacing: 6) {
                            Text(entry.wrong).strikethrough().foregroundColor(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                            Text(entry.correct).fontWeight(.medium)
                            Spacer()
                            Button { vocabularyManager.delete(entry) } label: {
                                Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Apagar")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func addSubstitutionIfValid() {
        guard !newVocabWrong.isEmpty && !newVocabCorrect.isEmpty else { return }
        vocabularyManager.add(wrong: newVocabWrong, correct: newVocabCorrect)
        newVocabWrong = ""
        newVocabCorrect = ""
    }

    private var hintSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Palavras enviadas como contexto à IA. Usa para nomes próprios, marcas ou termos técnicos que a IA confunde com palavras comuns.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            HStack {
                TextField("nome a reconhecer… (ex: Spit)", text: $newHintTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addHintIfValid() }
                Button(action: addHintIfValid) {
                    Image(systemName: "plus.circle.fill").foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newHintTerm.isEmpty)
            }
            .padding(.horizontal)

            let hints = vocabularyManager.entries.filter { $0.hintOnly }
            if hints.isEmpty {
                emptyState(icon: "waveform.badge.magnifyingglass",
                           message: "Sem dicas",
                           detail: "Adiciona nomes de produtos, projetos ou termos técnicos.")
            } else {
                List {
                    ForEach(hints) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: "waveform").font(.caption).foregroundColor(.accentColor)
                            Text(entry.correct).fontWeight(.medium)
                            Spacer()
                            Button { vocabularyManager.delete(entry) } label: {
                                Image(systemName: "trash").foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Apagar")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func addHintIfValid() {
        guard !newHintTerm.isEmpty else { return }
        vocabularyManager.addHint(newHintTerm)
        newHintTerm = ""
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

    // MARK: - Action Key Info

    /// Full explanation of the unified smart key behavior shown in Geral tab.
    private var actionKeyInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.vertical, 2)

            // ── Bloco Ditado ─────────────────────────────────────────────────
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ditado")
                        .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Text("Prima uma vez para iniciar — prima de novo para transcrever.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Ou mantém pressionada e solta para transcrever (push-to-talk).")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Requer que não haja texto selecionado.")
                        .font(.caption).foregroundColor(.secondary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "mic.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 13))
            }

            Divider().padding(.vertical, 2)

            // ── Bloco Leitura em voz alta ────────────────────────────────────
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Leitura em voz alta")
                        .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Text("Seleciona texto e prime a tecla para ler em voz alta.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Prima novamente para parar.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)

                    Text("Durante a leitura")
                        .font(.caption).fontWeight(.medium).foregroundColor(.secondary.opacity(0.8))
                    HStack(alignment: .top, spacing: 10) {
                        playbackShortcutBadge(key: "Space", label: String(localized: "pausa / retoma"))
                        playbackShortcutBadge(key: "ESC",   label: String(localized: "para"))
                        playbackShortcutBadge(key: "↑ →",   label: String(localized: "mais rápido"))
                        playbackShortcutBadge(key: "↓ ←",   label: String(localized: "mais devagar"))
                    }
                    .padding(.top, 1)
                }
            } icon: {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 13))
                    .frame(width: 16, alignment: .center)
            }
        }
    }

    private func playbackShortcutBadge(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .cornerRadius(4)
            Text(label)
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - TTS Voice Section (Reading tab — no hotkey config here)

    private var ttsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // System voice picker
            if !availableVoices.isEmpty {
                HStack(spacing: 10) {
                    Text("Voz do sistema")
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
                        Text("Padrão").tag("")
                        Divider()
                        ForEach(availableVoices) { voice in
                            Text("\(voice.name)  \(voice.languageTag)")
                                .tag(voice.identifier)
                        }
                    }
                    .frame(maxWidth: 180)
                    .labelsHidden()
                }
            }
        }
        .onAppear {
            if availableVoices.isEmpty { availableVoices = TTSVoiceOption.all() }
            TTSService.shared.voiceIdentifier = settings.ttsVoiceIdentifier
        }
    }


    // MARK: - Shortcut Row

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Tecla de ação")
                Spacer()

                if isRecordingShortcut {
                    // Recording mode
                    Text("Premir atalho…")
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

                    Button("Cancelar") { stopRecordingShortcut(save: false) }
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

                    Button("Alterar") { startRecordingShortcut() }
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

            // Globe tip — só mostra quando não está a gravar e a tecla actual não é Globe
            if !isRecordingShortcut && settings.hotkeyKeyCode != 63 {
                Label(String(localized: "Dica: a tecla 🌐 (Globe) é a mais ergonómica — prime-a aqui para usar."),
                      systemImage: "globe")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                shortcutConflict = String(localized: "Adicione um modificador (⌘ ⌥ ⌃ ⇧) ou use §, 🌐 ou uma tecla F")
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

    // MARK: - History tab (SPEC-AUTH §9)
    // Shows the last 50 local transcriptions. Users can copy or delete entries.
    // Storage is client-local (UserDefaults) — no server sync.

    @ViewBuilder
    private var historyTab: some View {
        let entries = HistoryManager.shared.entries
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Histórico de Ditados")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if !entries.isEmpty {
                        Button(role: .destructive) {
                            HistoryManager.shared.clear()
                        } label: {
                            Label(String(localized: "Limpar tudo"), systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("Ainda não há ditados guardados")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Os últimos 50 ditados aparecem aqui para recuperar texto se a injecção falhar.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(entries) { entry in
                        historyRow(entry: entry)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding()
        }
    }

    private func historyRow(entry: DictationHistoryEntry) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.callout)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: String(localized: "%d palavras · %.1fs"), entry.wordCount, entry.duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    } label: {
                        Label(String(localized: "Copiar"), systemImage: "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        HistoryManager.shared.delete(entry)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.red.opacity(0.7))
                }
            }
            .padding(.vertical, 2)
        }
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
