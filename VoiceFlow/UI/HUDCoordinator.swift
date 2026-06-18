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
    /// The ReviewHUD is now opened manually via the menu bar icon.
    func dictationCompleted(result: DictationResult) {
        recording.dismiss()
        vfLog("[HUDCoordinator] completed — outcome:\(result.outcome)")
    }
}
