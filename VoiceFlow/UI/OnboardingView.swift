import SwiftUI
import AppKit

// MARK: - OnboardingView
// Mostrado na primeira execução — guia o utilizador pelo setup:
// 1. Boas-vindas
// 2. Configurar API Key OpenAI
// 3. Conceder permissões (Microfone + Acessibilidade)
// 4. Pronto

struct OnboardingView: View {

    @State private var currentStep: Int = 0
    @State private var apiKeyInput: String = ""
    @State private var apiKeySaved: Bool = false
    @State private var apiKeyError: Bool = false
    @State private var hasExistingKey: Bool = false   // chave já guardada no Keychain
    @EnvironmentObject var creditsManager: CreditsManager

    private let totalSteps = 4

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 8) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    Circle()
                        .fill(i <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut, value: currentStep)
                }
            }
            .padding(.top, 28)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0: stepWelcome
                case 1: stepAPIKey
                case 2: stepPermissions
                case 3: stepReady
                default: stepWelcome
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.3), value: currentStep)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation { currentStep -= 1 }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                Spacer()

                Button(currentStep == totalSteps - 1 ? "Let's go!" : "Continue") {
                    advanceStep()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentStep == 1 && !apiKeySaved)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .frame(width: 520, height: 420)
        .onAppear {
            // Se já existe chave no Keychain (reinstalação / upgrade), pré-validar
            if creditsManager.hasUserAPIKey {
                hasExistingKey = true
                apiKeySaved = true
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var stepWelcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Welcome to Spit")
                .font(.largeTitle.bold())

            Text("Dictate anywhere on your Mac.\nJust press a shortcut, speak, and the text appears.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            HStack(spacing: 24) {
                featurePill(icon: "globe", text: "10 languages")
                featurePill(icon: "bolt.fill", text: "Whisper AI")
                featurePill(icon: "lock.fill", text: "BYOK — private")
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Step 1: API Key

    private var stepAPIKey: some View {
        VStack(spacing: 16) {
            Image(systemName: hasExistingKey && apiKeySaved && apiKeyInput.isEmpty ? "checkmark.shield.fill" : "key.fill")
                .font(.system(size: 48))
                .foregroundColor(hasExistingKey && apiKeySaved && apiKeyInput.isEmpty ? .green : .accentColor)

            Text("Your OpenAI API Key")
                .font(.title2.bold())

            if hasExistingKey && apiKeySaved && apiKeyInput.isEmpty {
                // Chave existente encontrada — não forçar nova entrada
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("API key already configured")
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    }
                    Text("Your existing key was found securely stored in the Keychain.\nYou can continue or replace it with a new one.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // Opção de substituir a chave
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("Replace with new key (optional)", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: apiKeyInput) { _ in
                                    apiKeyError = false
                                    // Se começou a escrever, a chave "guardada" é a nova
                                    if !apiKeyInput.isEmpty { apiKeySaved = false }
                                }

                            Button("Save") {
                                if creditsManager.activateUserKey(apiKeyInput) {
                                    apiKeySaved = true
                                    apiKeyInput = ""
                                } else {
                                    apiKeyError = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKeyInput.count < 10)
                        }

                        if apiKeyError {
                            Label("Could not save key. Please try again.", systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .frame(maxWidth: 380)
                }
            } else {
                // Sem chave — fluxo normal de configuração
                Text("Spit uses OpenAI's Whisper to transcribe your voice.\nYou'll need a free API key — your audio never goes through our servers.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SecureField("sk-proj-...", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: apiKeyInput) { _ in
                                apiKeyError = false
                                apiKeySaved = false
                            }

                        Button("Save") {
                            if creditsManager.activateUserKey(apiKeyInput) {
                                apiKeySaved = true
                                apiKeyInput = ""
                            } else {
                                apiKeyError = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKeyInput.count < 10)
                    }

                    if apiKeySaved {
                        Label("Key saved securely in Keychain ✓", systemImage: "checkmark.shield.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if apiKeyError {
                        Label("Could not save key. Please try again.", systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .frame(maxWidth: 380)

                Link("Get your free key at platform.openai.com →",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }
        }
    }

    // MARK: - Step 2: Permissions

    private var stepPermissions: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Two permissions needed")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To capture your voice while recording.",
                    action: {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    }
                )

                permissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "To type text automatically in any app.",
                    action: {
                        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
                        _ = AXIsProcessTrustedWithOptions(options)
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                )
            }
            .frame(maxWidth: 400)

            Text("Both can be granted on the next screen — macOS will prompt you.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Step 3: Ready

    private var stepReady: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're all set!")
                .font(.largeTitle.bold())

            Text("Press **⌘⇧D** to start dictating.\nSpit will appear in your menu bar — click to check status.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                tipRow(icon: "keyboard", text: "Change the shortcut in Settings")
                tipRow(icon: "speaker.wave.2", text: "Hold shortcut for push-to-talk")
                tipRow(icon: "text.badge.plus", text: "Teach Spit your vocabulary in Settings")
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func featurePill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(20)
        .foregroundColor(.accentColor)
    }

    private func permissionRow(icon: String, title: String, description: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(description).font(.caption).foregroundColor(.secondary)
            }

            Spacer()

            Button("Grant") { action() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(10)
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            Text(text).font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Navigation

    private func advanceStep() {
        if currentStep == totalSteps - 1 {
            // Fechar onboarding
            OnboardingWindowController.shared.close()
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        } else {
            withAnimation { currentStep += 1 }
        }
    }
}
