import SwiftUI

// MARK: - RecordingHUDState

enum RecordingHUDState {
    case recording(words: String)   // mic active, rolling words
    case processing                 // whisper is working
}

// MARK: - RecordingHUDView
// Small floating panel shown from recording start until the ReviewHUD appears.
// During recording: pulsing mic + last spoken words (rolling window).
// During processing: spinner + "Transcribing..."

struct RecordingHUDView: View {

    let state: RecordingHUDState

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            indicator
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 300, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.regularMaterial)
        )
    }

    // MARK: - Indicator

    private var indicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.2))
                .frame(width: 28, height: 28)
                .scaleEffect(pulse ? 1.25 : 1.0)
                .animation(
                    pulse ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                    value: pulse
                )

            Image(systemName: indicatorIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(indicatorColor)
        }
        .onAppear {
            if case .recording = state { pulse = true }
        }
        .onChange(of: isRecording) { recording in
            pulse = recording
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch state {
            case .recording(let words):
                if words.isEmpty {
                    Text("Listening…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Text("…\(words)")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.primary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                        .animation(.easeInOut(duration: 0.15), value: words)
                }

            case .processing:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                    Text("Transcribing…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private var indicatorColor: Color {
        switch state {
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var indicatorIcon: String {
        switch state {
        case .recording: return "mic.fill"
        case .processing: return "waveform"
        }
    }
}
