import AppKit

// MARK: - HUDCoordinator
// Single source of truth for all dictation-related HUD visibility.
//
// The ReviewHUD is no longer auto-shown after dictation — it is opened manually
// via the menu bar icon (left click). The coordinator only dismisses the
// RecordingHUD when a dictation cycle completes.

@MainActor
final class HUDCoordinator {

    static let shared = HUDCoordinator()
    private init() {}

    private var recording: RecordingHUDWindowController { .shared }

    // MARK: - Recording lifecycle

    /// Modelo a recarregar — mostra a pill com estado de loading.
    func modelLoadingStarted() {
        recording.showLoading()
    }

    /// Recording just started — show the pill.
    func recordingStarted() {
        recording.showRecording()
    }

    /// Live speech recognizer produced new rolling words.
    func recordingWords(_ words: String) {
        recording.updateWords(words)
    }

    /// User stopped, voice detected, audio is being transcribed.
    func processingStarted() {
        recording.transitionToProcessing()
    }

    // MARK: - Dictation completed

    /// Dictation cycle finished — dismisses the RecordingHUD.
    ///
    /// The ReviewHUD is normally opened manually via the menu bar icon, EXCEPT
    /// when the text never reached its destination and only landed in the
    /// clipboard (`pastedViaClipboard` — Accessibility permission missing, or
    /// injection failed). In that case we open it automatically so the text
    /// doesn't silently vanish: the user sees it and the alert with the ⌘V
    /// instruction. See SPEC §7 "Quando abre".
    func dictationCompleted(result: DictationResult) {
        recording.dismiss()
        vfLog("[HUDCoordinator] completed — outcome:\(result.outcome)")

        if result.pastedViaClipboard {
            vfLog("[HUDCoordinator] text only in clipboard — auto-opening ReviewHUD")
            ReviewHUDWindowController.shared.showForLastResult(result)
        }
    }
}
