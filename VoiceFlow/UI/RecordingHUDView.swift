import SwiftUI

// MARK: - RecordingHUDState

enum RecordingHUDState {
    case recording(words: String, startedAt: Date)
    case processing(startedAt: Date)
}

// MARK: - RecordingHUDView
// Compact pill shown from recording start until the ReviewHUD appears.
// Uses TimelineView for elapsed counter — avoids the repeated NSHostingView rootView
// updates (from live speech words) cancelling and recreating the Timer subscription.

struct RecordingHUDView: View {

    let state: RecordingHUDState

    @State private var pulse = false

    private let longThreshold: TimeInterval = 180   // warn at 3 min; auto-stop fires at 4 min (240s)

    var body: some View {
        TimelineView(.periodic(from: startDate, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(startDate)
            HStack(spacing: 10) {
                stateIndicator
                contentArea(elapsed: elapsed)
                Spacer(minLength: 0)
                Text(timeString(elapsed))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.regularMaterial)
            )
        }
        .onAppear {
            pulse = isRecording
        }
        .onChange(of: isRecording) { newValue in
            withAnimation { pulse = newValue }
        }
    }

    // MARK: - Indicator

    private var stateIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.18))
                .frame(width: 28, height: 28)
                .scaleEffect(pulse ? 1.28 : 1.0)
                .animation(
                    pulse
                        ? .easeInOut(duration: 0.65).repeatForever(autoreverses: true)
                        : .easeOut(duration: 0.2),
                    value: pulse
                )

            Image(systemName: indicatorIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(indicatorColor)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentArea(elapsed: TimeInterval) -> some View {
        switch state {
        case .recording(let words, _):
            VStack(alignment: .leading, spacing: 2) {
                Text(words.isEmpty ? "A ouvir…" : "…\(words)")
                    .font(.system(size: 12, weight: words.isEmpty ? .regular : .medium))
                    .foregroundColor(words.isEmpty ? .secondary : .primary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .animation(.easeInOut(duration: 0.12), value: words)

                if elapsed >= longThreshold {
                    Text("Ditado longo — para em 4 min o sistema transcreve automaticamente")
                        .font(.system(size: 10))
                        .foregroundColor(.orange.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

        case .processing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                Text("A transcrever…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    private var startDate: Date {
        switch state {
        case .recording(_, let t): return t
        case .processing(let t):   return t
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .recording:  return .red
        case .processing: return .orange
        }
    }

    private var indicatorIcon: String {
        switch state {
        case .recording:  return "mic.fill"
        case .processing: return "waveform"
        }
    }

    private func timeString(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let m = s / 60
        return m > 0
            ? String(format: "%d:%02d", m, s % 60)
            : String(format: "0:%02d", s % 60)
    }
}
