import Speech
import AVFoundation

// MARK: - LiveSpeechRecognizer
// Uses Apple's SFSpeechRecognizer alongside AVAudioEngine to provide
// a real-time rolling window of the last few spoken words.
// Purpose: "proof of life" indicator while recording, not a full transcription.
//
// Language policy:
//   - Never fall back to a different language family (e.g. English when Portuguese was requested).
//   - If the correct language model isn't available, return false → HUD shows "Listening…" only.
//   - Showing "Listening…" is always better than showing words in the wrong language.

class LiveSpeechRecognizer {

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Called on main thread with the last N spoken words
    var onRollingWords: ((String) -> Void)?

    private let maxWords = 4

    // MARK: - Init

    init() {
        vfLog("LiveSpeechRecognizer: initialised")
    }

    // MARK: - Request Permission + Diagnostics

    static func requestPermission() {
        SFSpeechRecognizer.requestAuthorization { status in
            vfLog("Speech recognition permission: \(status.rawValue)")

            // Log all available locales for diagnostics
            let available = SFSpeechRecognizer.supportedLocales()
                .filter { SFSpeechRecognizer(locale: $0)?.isAvailable == true }
                .map { $0.identifier }
                .sorted()
            vfLog("SFSpeechRecognizer available locales (\(available.count)): \(available.joined(separator: ", "))")
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - Start

    /// Returns true if recognition started successfully.
    /// - Parameter language: AppSettings language value ("pt", "pt-BR", "en", "auto", etc.)
    /// - Returns: false if the correct-language recognizer isn't available — HUD shows "Listening…" only.
    func start(language: String = "auto") -> Bool {
        guard Self.isAuthorized else {
            vfLog("LiveSpeechRecognizer: not authorized — skipping")
            return false
        }

        let candidates = buildCandidates(language: language)

        if candidates.isEmpty {
            vfLog("LiveSpeechRecognizer: no candidates for language '\(language)' — skipping word preview")
            return false
        }

        // Try each candidate — pick first one that can be instantiated.
        // We don't check isAvailable here because it can be temporarily false even for
        // installed languages (e.g. right after app launch before the recognizer warms up).
        // If the recognizer truly can't work, the recognition task will error immediately.
        var chosenRecognizer: SFSpeechRecognizer?
        for locale in candidates {
            if let r = SFSpeechRecognizer(locale: locale) {
                chosenRecognizer = r
                vfLog("LiveSpeechRecognizer: using \(locale.identifier) (isAvailable=\(r.isAvailable)) for '\(language)'")
                break
            }
        }

        guard let recognizer = chosenRecognizer else {
            vfLog("LiveSpeechRecognizer: could not instantiate recognizer for '\(language)' — showing 'Listening…' only")
            return false
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        self.request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self else { return }

            if let result = result {
                let words = result.bestTranscription.formattedString
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                let last = words.suffix(self.maxWords).joined(separator: " ")
                DispatchQueue.main.async {
                    self.onRollingWords?(last)
                }
            }

            if let error = error {
                let nsError = error as NSError
                let ignored = [301, 203, 209]  // silence, timeout, etc.
                if !ignored.contains(nsError.code) {
                    vfLog("LiveSpeechRecognizer error: \(error.localizedDescription)")
                }
            }
        }

        vfLog("LiveSpeechRecognizer: started ✅")
        return true
    }

    // MARK: - Feed Buffer

    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    // MARK: - Stop

    func stop() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        vfLog("LiveSpeechRecognizer: stopped")
    }

    // MARK: - Build Candidates using SFSpeechRecognizer.supportedLocales()

    /// Returns locale candidates for a given language string.
    /// Uses the API's own supported locale list — no hardcoded guessing.
    /// NEVER crosses language families (e.g. won't fall back to English for Portuguese).
    private func buildCandidates(language: String) -> [Locale] {
        let lang = language.lowercased()

        // Determine the target base language code
        let targetBase: String
        switch lang {
        case "auto":
            // Use the first system preferred language
            guard let first = NSLocale.preferredLanguages.first else { return [] }
            targetBase = String(first.split(separator: "-").first ?? Substring(first)).lowercased()
            vfLog("LiveSpeechRecognizer: auto → primary base language '\(targetBase)' (from '\(first)')")
        default:
            // Extract base from whatever was passed ("pt-BR" → "pt", "pt" → "pt", "en" → "en")
            targetBase = String(lang.split(separator: "-").first ?? Substring(lang)).lowercased()
        }

        // Ask the API which locales it actually supports for this language family.
        // NOTE: supportedLocales() returns identifiers with underscore (e.g. "pt_BR", "pt_PT"),
        // so we must split on BOTH "-" and "_" to extract the base language code.
        let supported = SFSpeechRecognizer.supportedLocales()
            .filter { locale in
                let id = locale.identifier.lowercased()
                let base: String
                if let i = id.firstIndex(of: "-") {
                    base = String(id[id.startIndex..<i])
                } else if let i = id.firstIndex(of: "_") {
                    base = String(id[id.startIndex..<i])
                } else {
                    base = id
                }
                return base == targetBase
            }
            .sorted { $0.identifier < $1.identifier }

        // Log ALL supported locales once for diagnostics (only on first call or when empty)
        let allLocales = SFSpeechRecognizer.supportedLocales().map { $0.identifier }.sorted()
        vfLog("LiveSpeechRecognizer: ALL supported locales: \(allLocales.joined(separator: ", "))")
        vfLog("LiveSpeechRecognizer: matching '\(targetBase)': \(supported.map { $0.identifier })")

        if supported.isEmpty {
            vfLog("LiveSpeechRecognizer: language '\(targetBase)' has no supported locales — skipping word preview")
        }

        return supported
    }
}
