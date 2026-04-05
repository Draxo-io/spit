import SwiftUI

// MARK: - MenuBarPopoverView
// Popover shown when clicking the menu bar icon.

struct MenuBarPopoverView: View {

    @EnvironmentObject var dictationController: DictationController
    @EnvironmentObject var creditsManager: CreditsManager
    @EnvironmentObject var vocabularyManager: VocabularyManager

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            statusView
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            Divider()
            creditsView
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
            Divider()
            if let result = dictationController.lastResult {
                lastResultView(result: result)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                Divider()
            }
            actionsView
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
        }
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundColor(.accentColor)
            Text("Spit")
                .font(.headline)
            Spacer()
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Status

    private var statusView: some View {
        HStack(spacing: 10) {
            if case .recording = dictationController.state {
                AudioLevelView(level: dictationController.audioLevel)
                    .frame(width: 40, height: 20)
            } else {
                Image(systemName: dictationController.state.menuBarIcon)
                    .font(.title3)
                    .foregroundColor(stateColor)
                    .frame(width: 40, height: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(dictationController.state.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("⌘⇧D to dictate")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Credits

    private var creditsView: some View {
        HStack {
            Image(systemName: creditsManager.mode == .userKey ? "key.fill" : "clock")
                .font(.caption)
                .foregroundColor(creditsManager.freeTrialExhausted ? .red : .secondary)
            Text(creditsManager.statusMessage)
                .font(.caption)
                .foregroundColor(creditsManager.freeTrialExhausted ? .red : .secondary)
            Spacer()
        }
    }

    // MARK: - Last Result

    private func lastResultView(result: DictationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last dictation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(result.duration))s")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(result.correctedText)
                .font(.caption)
                .lineLimit(3)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Actions

    private var actionsView: some View {
        HStack {
            Button {
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.openSettings()
                }
            } label: {
                Label("Settings", systemImage: "gear")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - State colour

    private var stateColor: Color {
        switch dictationController.state {
        case .idle:       return .green
        case .recording:  return .red
        case .processing: return .orange
        case .injecting:  return .blue
        case .error:      return .red
        }
    }
}

// MARK: - AudioLevelView

struct AudioLevelView: View {
    let level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(index: i))
                    .frame(width: 4, height: barHeight(index: i))
                    .animation(.easeInOut(duration: 0.1), value: level)
            }
        }
    }

    private func normalizedLevel() -> Float {
        let clamped = max(-60, min(0, level))
        return (clamped + 60) / 60
    }

    private func barHeight(index: Int) -> CGFloat {
        let nl = normalizedLevel()
        let threshold = Float(index) / Float(barCount)
        return nl > threshold ? CGFloat(4 + index * 3) : 4
    }

    private func barColor(index: Int) -> Color {
        let nl = normalizedLevel()
        let threshold = Float(index) / Float(barCount)
        return nl > threshold ? .red : Color.secondary.opacity(0.3)
    }
}
