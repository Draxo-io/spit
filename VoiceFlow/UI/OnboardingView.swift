import SwiftUI
import AppKit
import AVFoundation

// MARK: - OnboardingView
// 7 passos: boas-vindas → microfone → acessibilidade → trial (magic link) → atalho → primeiro ditado → pronto

struct OnboardingView: View {

    @State private var step: Int = 0
    @State private var emailInput: String = ""
    @State private var emailSent: Bool = false
    @State private var emailSending: Bool = false
    @State private var emailError: String? = nil
    @State private var micGranted: Bool = false
    @State private var axGranted: Bool = false
    @State private var trialActivated: Bool = false
    @EnvironmentObject var dictationController: DictationController
    @ObservedObject private var licenseManager: LicenseManager = .shared

    private let totalSteps = 7

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
                case 3: stepTrial
                case 4: stepHotkey
                case 5: stepFirstDictation
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
        .frame(width: 520, height: 440)
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
        HStack {
            if step > 0 {
                Button("Voltar") { withAnimation { step -= 1 } }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(step == totalSteps - 1 ? "Começar" : "Continuar") {
                advanceStep()
            }
            .buttonStyle(.borderedProminent)
            .disabled(continueDisabled)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var continueDisabled: Bool {
        switch step {
        case 3: return !trialActivated && !licenseManager.isActivated && licenseManager.plan == .trial && licenseManager.trialExhausted
        default: return false
        }
    }

    // MARK: - Step 0: Boas-vindas

    private var stepWelcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("O ditado mais rápido do Mac.")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text("Dita em qualquer campo de texto.\nSó precisas de uma tecla.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                featurePill(icon: "mic.fill",      text: "Ditado")
                featurePill(icon: "speaker.wave.2", text: "Leitura")
                featurePill(icon: "lock.fill",      text: "Privacidade")
                featurePill(icon: "cpu",            text: "IA local")
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

            Text(micGranted ? "Microfone autorizado ✓" : "Acesso ao microfone")
                .font(.title2.bold())

            Text("O Spit precisa do microfone para ouvir a tua voz.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !micGranted {
                Button("Conceder acesso") {
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { micGranted = granted }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { refreshPermissions() }
    }

    // MARK: - Step 2: Acessibilidade

    private var stepAccessibility: some View {
        VStack(spacing: 20) {
            Image(systemName: axGranted ? "checkmark.shield.fill" : "hand.raised.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(axGranted ? .green : .accentColor)
                .animation(.spring(), value: axGranted)

            Text(axGranted ? "Acessibilidade autorizada ✓" : "Acesso de acessibilidade")
                .font(.title2.bold())

            Text("Para inserir texto onde quer que estejas a escrever.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if !axGranted {
                VStack(spacing: 10) {
                    Button("Abrir Definições do Sistema") {
                        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                        _ = AXIsProcessTrustedWithOptions(options)
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                        // Poll for permission
                        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                            if AXIsProcessTrusted() {
                                DispatchQueue.main.async { axGranted = true }
                                timer.invalidate()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Ativa o Spit na lista de apps de acessibilidade.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { refreshPermissions() }
    }

    // MARK: - Step 3: Ativar Trial

    private var stepTrial: some View {
        VStack(spacing: 20) {
            // Icon: shows success when activated
            let isActive = trialActivated || licenseManager.isActivated ||
                           (licenseManager.plan == .trial && !licenseManager.trialExhausted)
            Image(systemName: isActive ? "checkmark.circle.fill" : "envelope.badge.fill")
                .font(.system(size: 64))
                .foregroundColor(isActive ? .green : .accentColor)
                .animation(.spring(), value: isActive)

            if isActive {
                VStack(spacing: 8) {
                    Text("Trial ativado ✓")
                        .font(.title2.bold())
                    Text("\(licenseManager.trialMinutesRemaining) minutos de ditado gratuito")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Ativar o teu trial gratuito")
                    .font(.title2.bold())

                Text("60 minutos grátis, sem cartão de crédito.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("O teu email", text: $emailInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(emailSent || emailSending)

                        Button {
                            sendMagicLink()
                        } label: {
                            if emailSending {
                                ProgressView().scaleEffect(0.75).frame(width: 60)
                            } else {
                                Text(emailSent ? "Enviado ✓" : "Enviar link")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(emailInput.isEmpty || emailSent || emailSending)
                    }

                    if emailSent {
                        Label("Verifica a tua caixa de entrada — clica no link para ativar.", systemImage: "tray.and.arrow.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let err = emailError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .frame(maxWidth: 380)

                // Skip option
                Button("Continuar sem trial") { withAnimation { step += 1 } }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SpitTrialActivated"))) { _ in
            trialActivated = true
        }
    }

    // MARK: - Step 4: Atalho

    private var stepHotkey: some View {
        VStack(spacing: 20) {
            Image(systemName: "keyboard")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("O teu atalho de ditado")
                .font(.title2.bold())

            // Hotkey display
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
                Label("Toque rápido — inicia/para a gravação", systemImage: "hand.tap")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Label("Mantém pressionado — grava enquanto seguras (PTT)", systemImage: "hand.point.up.left")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Podes alterar o atalho em Preferências.")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step 5: Primeiro ditado

    private var stepFirstDictation: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)

            Text("Experimenta agora")
                .font(.title2.bold())

            Text("Clica numa caixa de texto qualquer\ne dita algo com o teu atalho.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Demo text field
            TextField("Clica aqui e usa o atalho para ditar…", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .disabled(true)
                .opacity(0.7)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step 6: Pronto

    private var stepReady: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)

            Text("Estás pronto!")
                .font(.largeTitle.bold())

            let settings = dictationController.loadSettings()
            let label = hotkeyLabels(settings).joined(separator: " ")
            Text("Usa **\(label)** para ditar em qualquer app.\nO Spit fica na barra de menus.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "gear",           text: "Altera o atalho em Preferências")
                tipRow(icon: "cpu",            text: "Usa IA local para ditar offline, grátis")
                tipRow(icon: "text.badge.plus", text: "Ensina o teu vocabulário em Preferências")
            }
            .padding(.top, 4)
        }
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

    private func sendMagicLink() {
        guard !emailInput.isEmpty else { return }
        emailSending = true
        emailError = nil

        Task {
            do {
                var req = URLRequest(url: URL(string: "\(LicenseManager.apiBase)/trial/send-link")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "email": emailInput,
                    "device_id": LicenseManager.shared.deviceIdentifier()
                ])
                req.timeoutInterval = 15

                let (_, resp) = try await URLSession.shared.data(for: req)
                await MainActor.run {
                    emailSending = false
                    if (resp as? HTTPURLResponse)?.statusCode == 200 {
                        emailSent = true
                    } else {
                        emailError = "Não foi possível enviar. Tenta novamente."
                    }
                }
            } catch {
                await MainActor.run {
                    emailSending = false
                    emailError = "Erro de rede. Verifica a tua ligação."
                }
            }
        }
    }

    private func advanceStep() {
        if step == totalSteps - 1 {
            OnboardingWindowController.shared.close()
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        } else {
            withAnimation { step += 1 }
        }
    }
}
