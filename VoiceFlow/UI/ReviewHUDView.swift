import SwiftUI
import ApplicationServices

// MARK: - ReviewHUDView
// Floating card shown after each dictation.
// Design matches RecordingHUDView — same material, corner radius, and shadow treatment.

struct ReviewHUDView: View {

    let result: DictationResult
    weak var controller: DictationController?
    var onDismiss: (() -> Void)?

    @State private var editedText: String
    @State private var isEditing = false
    @State private var learnedMessage: String? = nil
    @FocusState private var textFieldFocused: Bool

    private let cornerRadius: CGFloat = 20

    init(result: DictationResult, controller: DictationController?, onDismiss: (() -> Void)? = nil) {
        self.result = result
        self.controller = controller
        self.onDismiss = onDismiss
        self._editedText = State(initialValue: result.correctedText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header row
            headerRow
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Clipboard / AX warning (only when needed)
            if result.pastedViaClipboard {
                warningBanner
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            // Transcribed text
            textArea
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            // Learned feedback (shown briefly after saving a correction)
            if let msg = learnedMessage {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Action buttons
            actionRow
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if !self.isEditing { self.dismiss() }
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            // Pulsing dot — indicates this was just transcribed
            Circle()
                .fill(Color.green.opacity(0.85))
                .frame(width: 7, height: 7)

            Text("Transcribed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer()

            Text("\(String(format: "%.1f", result.duration))s")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Warning Banner

    private var warningBanner: some View {
        let axTrusted = AXIsProcessTrusted()

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: axTrusted ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                if axTrusted {
                    Text("No focused field — press ⌘V to paste")
                        .font(.system(size: 12))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.8))
                } else {
                    Text("Accessibility permission required")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.9))

                    Text("Enable Spit in System Settings to paste automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: .labelColor).opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open System Settings → Accessibility") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(axTrusted ? 0.08 : 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Text Area

    private var textArea: some View {
        Group {
            if isEditing {
                TextEditor(text: $editedText)
                    .font(.system(size: 14))
                    .frame(minHeight: 56, maxHeight: 120)
                    .focused($textFieldFocused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    )
            } else {
                Text(editedText)
                    .font(.system(size: 14))
                    .foregroundColor(Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.25))
                    )
                    .onTapGesture {
                        isEditing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            textFieldFocused = true
                        }
                    }
            }
        }
    }

    // MARK: - Action Row

    private var actionRow: some View {
        HStack(spacing: 8) {
            if isEditing {
                Button {
                    copyToClipboard(editedText)
                    applyAndDismiss()
                } label: {
                    Label("Save & copy", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel") {
                    editedText = result.correctedText
                    isEditing = false
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

            } else {
                Button {
                    isEditing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        textFieldFocused = true
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    copyToClipboard(editedText)
                    dismiss()
                } label: {
                    Label("Copy", systemImage: "doc.on.clipboard")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .foregroundColor(.secondary)
            }

            Spacer()

            // Learning indicator
            if editedText != result.originalText {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .help("Spit will learn from this correction")
            }
        }
    }

    // MARK: - Actions

    private func applyAndDismiss() {
        if editedText != result.correctedText {
            let learned = controller?.applyCorrection(original: result.correctedText, corrected: editedText) ?? []

            if !learned.isEmpty {
                let pairs = learned.prefix(2).map { "'\($0.wrong)' → '\($0.correct)'" }.joined(separator: ", ")
                let suffix = learned.count > 2
                    ? String(format: String(localized: " +%d more"), learned.count - 2)
                    : ""
                withAnimation {
                    learnedMessage = String(format: String(localized: "Learned: %@%@"), pairs, suffix)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation { learnedMessage = nil }
                    dismiss()
                }
                return
            }
        }
        dismiss()
    }

    private func dismiss() {
        onDismiss?()
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
