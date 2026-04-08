import SwiftUI

// MARK: - ReadingHUDView
// Floating pill shown while TTS is reading text aloud.
// Controls: pause/resume, stop, and playback speed (0.75x–2x).

struct ReadingHUDView: View {

    @ObservedObject private var ttsService: TTSService = .shared

    @State private var pulse = false

    private let speedSteps: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing speaker indicator
            speakerIndicator

            // Label
            Text(ttsService.isPaused ? "Em pausa" : "A ler…")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(minWidth: 52, alignment: .leading)

            Spacer(minLength: 4)

            // Speed picker
            speedControl

            // Pause / Resume
            Button {
                if ttsService.isPaused {
                    ttsService.resume()
                } else {
                    ttsService.pause()
                }
            } label: {
                Image(systemName: ttsService.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(ttsService.isPaused ? "Retomar" : "Pausar")

            // Stop
            Button {
                ttsService.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 22, height: 22)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Parar leitura")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.regularMaterial)
        )
        .onAppear {
            pulse = !ttsService.isPaused
        }
        .onChange(of: ttsService.isPaused) { paused in
            pulse = !paused
        }
    }

    // MARK: - Speaker indicator

    private var speakerIndicator: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.18))
                .frame(width: 28, height: 28)
                .scaleEffect(pulse ? 1.22 : 1.0)
                .animation(
                    pulse
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

            Image(systemName: ttsService.isPaused ? "pause.circle.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.blue)
        }
    }

    // MARK: - Speed picker

    private var speedControl: some View {
        Menu {
            ForEach(speedSteps, id: \.self) { speed in
                Button {
                    ttsService.setSpeed(speed)
                } label: {
                    HStack {
                        Text(speedLabel(speed))
                        if ttsService.speedMultiplier == speed {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speedLabel(ttsService.speedMultiplier))
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

    private func speedLabel(_ speed: Float) -> String {
        if speed == Float(Int(speed)) {
            return "\(Int(speed))×"
        }
        return String(format: "%.2g×", speed)
    }
}
