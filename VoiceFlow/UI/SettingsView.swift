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
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
    return map[keyCode] ?? "?"
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

struct SettingsView: View {

    @EnvironmentObject var dictationController: DictationController
    @EnvironmentObject var creditsManager: CreditsManager
    @EnvironmentObject var vocabularyManager: VocabularyManager

    @State private var settings: AppSettings = AppSettings.defaults
    @State private var apiKeyInput: String = ""
    @State private var apiKeyMasked: Bool = true
    @State private var showApiKeySavedAlert = false
    @State private var newVocabWrong = ""
    @State private var newVocabCorrect = ""
    @State private var newHintTerm = ""
    @State private var vocabMode: VocabMode = .substitution
    @State private var showRestartBanner = false

    // Toggle shortcut recorder state
    @State private var isRecordingShortcut = false
    @State private var shortcutEventMonitor: Any? = nil
    @State private var shortcutConflict: String? = nil

    // PTT shortcut recorder state
    @State private var isRecordingPTT = false
    @State private var pttEventMonitor: Any? = nil
    @State private var pttConflict: String? = nil

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
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            apiKeyTab
                .tabItem { Label("API Key", systemImage: "key") }

            vocabularyTab
                .tabItem { Label("Vocabulary", systemImage: "text.badge.plus") }
        }
        .frame(width: 480, height: 460)
        .onAppear {
            settings = dictationController.loadSettings()
        }
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
                pttSection
            }
        }
        .formStyle(.grouped)
        .padding()
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

            GroupBox("Your OpenAI Key (BYOK)") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Use your own OpenAI key for unlimited usage.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Group {
                            if apiKeyMasked {
                                SecureField("sk-...", text: $apiKeyInput)
                            } else {
                                TextField("sk-...", text: $apiKeyInput)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button {
                            apiKeyMasked.toggle()
                        } label: {
                            Text(apiKeyMasked ? "Show" : "Hide")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }

                    HStack {
                        Button("Save Key") {
                            if creditsManager.activateUserKey(apiKeyInput) {
                                showApiKeySavedAlert = true
                                apiKeyInput = ""
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKeyInput.isEmpty || !apiKeyInput.hasPrefix("sk-"))

                        if creditsManager.hasUserAPIKey {
                            Button("Remove Key") {
                                creditsManager.removeUserKey()
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                    }

                    Link("Get your key at platform.openai.com →",
                         destination: URL(string: "https://platform.openai.com/api-keys")!)
                        .font(.caption)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding()
        .alert("Key saved successfully!", isPresented: $showApiKeySavedAlert) {
            Button("OK") {}
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
                TextField("Should be…", text: $newVocabCorrect)
                    .textFieldStyle(.roundedBorder)
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
                        HStack {
                            Text(entry.wrong).strikethrough().foregroundColor(.secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundColor(.secondary)
                            Text(entry.correct).fontWeight(.medium)
                            Spacer()
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { substitutions[$0].id }
                        ids.forEach { id in
                            if let entry = vocabularyManager.entries.first(where: { $0.id == id }) {
                                vocabularyManager.delete(entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
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
                        HStack {
                            Image(systemName: "waveform").font(.caption).foregroundColor(.accentColor)
                            Text(entry.correct).fontWeight(.medium)
                            Spacer()
                            Text("hint only").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { hints[$0].id }
                        ids.forEach { id in
                            if let entry = vocabularyManager.entries.first(where: { $0.id == id }) {
                                vocabularyManager.delete(entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
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

    // MARK: - PTT Section

    private var pttSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 2)

            Toggle(isOn: $settings.pttEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Push-to-talk")
                        .fontWeight(.medium)
                    Text("Hold key → record. Release → transcribe.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: settings.pttEnabled) { enabled in
                save()
                dictationController.updatePTT(
                    enabled: enabled,
                    keyCode: settings.pttKeyCode,
                    modifiers: settings.pttModifiers
                )
                if !enabled {
                    isRecordingPTT = false
                    stopRecordingPTTShortcut()
                }
            }

            if settings.pttEnabled {
                Divider()
                pttShortcutRow
            }
        }
    }

    private var pttShortcutRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("PTT key")
                    .foregroundColor(.secondary)
                Spacer()

                if isRecordingPTT {
                    Text("Press any key…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                .background(Color.accentColor.opacity(0.06).cornerRadius(6))
                        )

                    Button("Cancel") { stopRecordingPTTShortcut() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 3) {
                        let mods = modifierSymbols(settings.pttModifiers)
                        let key  = keyLabel(settings.pttKeyCode)
                        ForEach(Array(mods.enumerated()), id: \.offset) { _, ch in
                            keyBadge(String(ch))
                        }
                        keyBadge(key)
                    }

                    Button("Change") { startRecordingPTTShortcut() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if let conflict = pttConflict {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Aviso quando sem modificador (captura TODAS as pressões)
            if settings.pttModifiers == 0 && !isRecordingPTT {
                Label(
                    "Single key intercepts all typing while held — prefer F-keys or add a modifier.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundColor(.orange)
            }
        }
        .onDisappear { stopRecordingPTTShortcut() }
    }

    // MARK: - PTT Recording

    private func startRecordingPTTShortcut() {
        pttConflict = nil
        isRecordingPTT = true

        pttEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [self] event in
            // Escape = cancelar
            if event.keyCode == 53 {
                stopRecordingPTTShortcut()
                return nil
            }

            let carbonKey = UInt32(event.keyCode)
            let carbonMods = toCarbonModifiers(
                event.modifierFlags.intersection([.command, .shift, .option, .control])
            )

            // Confirmar que não conflitua com o atalho principal
            if carbonKey == settings.hotkeyKeyCode && carbonMods == settings.hotkeyModifiers {
                pttConflict = "Conflicts with the dictation toggle shortcut."
                return nil
            }

            applyNewPTT(keyCode: carbonKey, modifiers: carbonMods)
            return nil
        }
    }

    private func applyNewPTT(keyCode: UInt32, modifiers: UInt32) {
        stopRecordingPTTShortcut()
        pttConflict = nil
        settings.pttKeyCode = keyCode
        settings.pttModifiers = modifiers
        save()
        dictationController.updatePTT(
            enabled: settings.pttEnabled,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    private func stopRecordingPTTShortcut() {
        isRecordingPTT = false
        if let monitor = pttEventMonitor {
            NSEvent.removeMonitor(monitor)
            pttEventMonitor = nil
        }
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

        shortcutEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [self] event in
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])

            // Escape = cancel
            if event.keyCode == 53 {
                stopRecordingShortcut(save: false)
                return nil
            }

            // Must have at least one modifier
            guard !mods.isEmpty else {
                shortcutConflict = "Shortcut must include at least one modifier (⌘ ⌥ ⌃ ⇧)"
                return nil
            }

            // Must not be modifier-only (no real key)
            let carbonKey = UInt32(event.keyCode)
            let carbonMods = toCarbonModifiers(mods)

            applyNewShortcut(keyCode: carbonKey, modifiers: carbonMods)
            return nil  // consume event
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
        if let monitor = shortcutEventMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutEventMonitor = nil
        }
    }

    // MARK: - Save

    private func save() {
        dictationController.saveSettings(settings)
    }
}
