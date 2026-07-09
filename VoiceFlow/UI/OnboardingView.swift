import SwiftUI
import AppKit
import AVFoundation

// MARK: - OnboardingView
// 5 passos: boas-vindas → microfone → acessibilidade → atalho → pronto

struct OnboardingView: View {

    @State private var step: Int = 0

    // Permissões
    @State private var micGranted: Bool = false
    @State private var axGranted: Bool = false

    @EnvironmentObject var dictationController: DictationController

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            progressDots
                .padding(.top, 28)
                .padding(.bottom, 4)

            Spacer()

            Group {
                switch step {
                case 0: stepWelcome
                case 1: stepMicrophone
                case 2: stepAccessibility
                case 3: stepHotkey
                default: stepReady
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal:   .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.28), value: step)

            Spacer()
            navigationButtons
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
        .frame(width: 520, height: 460)
        .onAppear { refreshPermissions() }
    }

    // MARK: - Progress dots

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: i == step ? 20 : 7, height: 7)
                    .animation(.spring(response: 0.3), value: step)
            }
        }
    }

    // MARK: - Navigation buttons

    private var navigationButtons: some View {
        HStack(spacing: 10) {
            Button(String(localized: "onboarding.quit", defaultValue: "Sair do Spit")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            Spacer()

            // Back (excepto step 0)
            if step > 0 {
                Button(String(localized: "onboarding.back")) { withAnimation { step -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }

            Button(step == totalSteps - 1 ? String(localized: "onboarding.start") : String(localized: "onboarding.continue")) {
                advanceStep()
            }
            .buttonStyle(.borderedProminent)
            .disabled(continueDisabled)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var continueDisabled: Bool {
        switch step {
        case 1: return !micGranted   // microfone obrigatório
        case 2: return !axGranted    // acessibilidade obrigatória
        default: return false
        }
    }

    // MARK: - Step 0: Boas-vindas

    private var stepWelcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text(String(localized: "onboarding.welcome.headline"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(String(localized: "onboarding.welcome.subtitle"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                featurePill(icon: "mic.fill",       text: String(localized: "onboarding.feature.dictation"))
                featurePill(icon: "speaker.wave.2", text: String(localized: "onboarding.feature.reading"))
                featurePill(icon: "waveform",       text: String(localized: "onboarding.feature.local_ai"))
                featurePill(icon: "globe",          text: String(localized: "onboarding.feature.privacy"))
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step 1: Microfone

    private var stepMicrophone: some View {
        VStack(spacing: 20) {
            Image(systemName: micGranted ? "checkmark.circle.fill" : "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(micGranted ? .green : .accentColor)
                .animation(.spring(), value: micGranted)

            Text(micGranted ? String(localized: "onboarding.mic.granted") : String(localized: "onboarding.mic.title"))
                .font(.title2.bold())

            Text(String(localized: "onboarding.mic.subtitle"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !micGranted {
                // Botão de fallback: aparece se o utilizador recusou anteriormente
                // ou se o diálogo automático não apareceu (já negado → abre Definições)
                let status = AVCaptureDevice.authorizationStatus(for: .audio)
                if status == .denied || status == .restricted {
                    Button(String(localized: "onboarding.mic.open_settings")) {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear {
            refreshPermissions()
            // Disparar o pedido de permissão automaticamente ao entrar no passo,
            // para o diálogo do sistema aparecer com o contexto da explicação visível.
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { micGranted = granted }
                }
            }
        }
    }

    // MARK: - Step 2: Acessibilidade

    private var stepAccessibility: some View {
        VStack(spacing: 20) {
            Image(systemName: axGranted ? "checkmark.shield.fill" : "hand.raised.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(axGranted ? .green : .accentColor)
                .animation(.spring(), value: axGranted)

            Text(axGranted ? String(localized: "onboarding.ax.granted") : String(localized: "onboarding.ax.title"))
                .font(.title2.bold())

            Text(String(localized: "onboarding.ax.subtitle"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !axGranted {
                VStack(spacing: 10) {
                    Button(String(localized: "onboarding.ax.open_settings")) {
                        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                        _ = AXIsProcessTrustedWithOptions(options)
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                            if AXIsProcessTrusted() {
                                DispatchQueue.main.async { axGranted = true }
                                timer.invalidate()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text(String(localized: "onboarding.ax.instruction"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { refreshPermissions() }
    }

    // MARK: - Step 3: Atalho

    private var stepHotkey: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text(String(localized: "onboarding.hotkey.title"))
                .font(.title2.bold())

            let settings = dictationController.loadSettings()
            HStack(spacing: 6) {
                ForEach(hotkeyLabels(settings), id: \.self) { label in
                    Text(label)
                        .font(.system(size: 18, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
                }
            }

            VStack(spacing: 6) {
                Label(String(localized: "onboarding.hotkey.tap_hint"),  systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label(String(localized: "onboarding.hotkey.hold_hint"), systemImage: "hand.point.up.left")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(String(localized: "onboarding.hotkey.hint"))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step 4: Pronto

    private var stepReady: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text(String(localized: "onboarding.ready.title"))
                .font(.largeTitle.bold())

            // Tecla do atalho em destaque — estilo keycap físico
            let settings = dictationController.loadSettings()
            let label = hotkeyLabels(settings).joined(separator: " ")
            keyCap(label)

            Text(String(localized: "onboarding.ready.subtitle.nokey"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text("Grátis para sempre — sem subscrição.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "gear",            text: String(localized: "onboarding.ready.tip.hotkey"))
                tipRow(icon: "text.badge.plus", text: String(localized: "onboarding.ready.tip.vocab"))
            }
            .padding(.top, 4)
        }
    }

    /// Componente visual estilo tecla física do teclado
    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundColor(.primary)
            .frame(minWidth: 52, minHeight: 52)
            .padding(.horizontal, 10)
            .background(
                ZStack {
                    // Sombra inferior — simula profundidade da tecla
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.separatorColor).opacity(0.6))
                        .offset(y: 3)
                    // Face da tecla
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                }
            )
    }

    // MARK: - Helpers

    private func featurePill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(20)
        .foregroundColor(.accentColor)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundColor(.accentColor).frame(width: 16)
            Text(text).font(.caption).foregroundColor(.secondary)
        }
    }

    private func hotkeyLabels(_ settings: AppSettings) -> [String] {
        let keyMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 40: "K", 45: "N", 46: "M",
            49: "Space", 63: "🌐",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 109: "F10", 111: "F12",
        ]
        var parts: [String] = []
        let m = settings.hotkeyModifiers
        if m & 4096 != 0 { parts.append("⌃") }
        if m & 2048 != 0 { parts.append("⌥") }
        if m & 512  != 0 { parts.append("⇧") }
        if m & 256  != 0 { parts.append("⌘") }
        parts.append(keyMap[settings.hotkeyKeyCode] ?? "?")
        return parts
    }

    private func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted  = AXIsProcessTrusted()
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")

        // Pré-carregar o modelo Whisper agora: o utilizador acabou de dar
        // permissões e está prestes a fazer o primeiro ditado, por isso o
        // modelo fica pronto e o primeiro Globe é instantâneo.
        //
        // IMPORTANTE: fazê-lo AQUI (fim do onboarding), e não em setup()/arranque.
        // O onboarding só corre uma vez, por isso os relançamentos automáticos do
        // LaunchAgent (ex.: após um Jetsam kill) NÃO recarregam o modelo — é o que
        // evita o death-loop de memória documentado na nota Kogno do Jetsam.
        if dictationController.loadSettings().transcriptionEngine == .local {
            Task { await LocalWhisperService.shared.load(model: .small) }
        }

        OnboardingWindowController.shared.close()
    }

    private func advanceStep() {
        if step == totalSteps - 1 {
            finishOnboarding()
        } else {
            withAnimation { step += 1 }
        }
    }
}
