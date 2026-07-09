import SwiftUI

// MARK: - ReadingHUDView
// Compact pill shown while TTS is reading text aloud.
// Shows processing/translating state immediately, transitions to playing controls.

struct ReadingHUDView: View {

    @ObservedObject private var tts: TTSService = .shared

    @State private var pulse = false

    private let speedSteps: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 10) {
            phaseIndicator
            VStack(alignment: .leading, spacing: 2) {
                phaseLabel
                if let note = tts.truncationNote, tts.readingPhase == .playing || tts.readingPhase == .paused {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(.orange.opacity(0.8))
                        .lineLimit(1)
                        .help(note)
                }
            }
            Spacer(minLength: 4)
            if tts.readingPhase == .playing || tts.readingPhase == .paused {
                speedPicker
                pauseButton
            }
            // Standby é automático — sem botão de parar (utilizador não iniciou nada).
            if tts.readingPhase != .standingBy {
                stopButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.regularMaterial)
        )
        .onChange(of: tts.readingPhase) { phase in
            withAnimation { pulse = (phase == .playing) }
        }
        .onAppear {
            pulse = (tts.readingPhase == .playing)
        }
    }

    // MARK: - Phase indicator (left icon)

    private var phaseIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.18))
                .frame(width: 28, height: 28)
                .scaleEffect(pulse ? 1.28 : 1.0)
                .animation(
                    pulse
                        ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: pulse
                )

            switch tts.readingPhase {
            case .warmingUp, .reloading, .processing, .translating:
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.accentColor)
            case .standingBy:
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            case .playing:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
            case .paused:
                Image(systemName: "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            case .idle:
                EmptyView()
            }
        }
    }

    private var indicatorColor: Color {
        switch tts.readingPhase {
        case .warmingUp, .reloading, .processing, .translating: return .accentColor
        case .standingBy: return .secondary
        case .playing: return .accentColor
        case .paused: return .secondary
        case .failed: return .orange
        case .idle: return .clear
        }
    }

    // MARK: - Phase label

    private var phaseLabel: some View {
        Text(phaseLabelText)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .frame(minWidth: 80, alignment: .leading)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: tts.readingPhase)
    }

    private var phaseLabelText: String {
        switch tts.readingPhase {
        case .warmingUp:           return "A inicializar motor de voz…"
        case .reloading:           return "A recarregar motor de voz…"
        case .processing:          return "A processar…"
        case .translating:         return "A traduzir…"
        case .standingBy:          return "A colocar motor em standby…"
        case .playing:             return "A ler…"
        case .paused:              return "Em pausa"
        case .failed(let msg):     return msg
        case .idle:                return ""
        }
    }

    // MARK: - Speed picker

    private var speedPicker: some View {
        Menu {
            ForEach(speedSteps, id: \.self) { speed in
                Button {
                    tts.setSpeed(speed)
                } label: {
                    HStack {
                        Text(speedLabel(speed))
                        if tts.speedMultiplier == speed {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speedLabel(tts.speedMultiplier))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Velocidade de leitura")
    }

    // MARK: - Pause / Resume

    private var pauseButton: some View {
        Button {
            tts.isPaused ? tts.resume() : tts.pause()
        } label: {
            Image(systemName: tts.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tts.isPaused ? "Retomar" : "Pausar")
    }

    // MARK: - Stop

    private var stopButton: some View {
        Button {
            tts.stop()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.secondary.opacity(0.1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Cancelar")
    }

    // MARK: - Helper

    private func speedLabel(_ speed: Float) -> String {
        speed == Float(Int(speed))
            ? "\(Int(speed))×"
            : String(format: "%.2g×", speed)
    }
}
