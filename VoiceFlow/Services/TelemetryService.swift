import Foundation

// TelemetryService stub — open-source v2.0. No network calls.

final class TelemetryService {

    static let shared = TelemetryService()
    private init() {}

    private let vocabConsentKey = "spit.telemetry.vocabConsent"

    // MARK: - Device Ping (no-op)

    func pingIfNeeded() {}

    // MARK: - Vocabulary Consent

    var vocabularyConsentGiven: Bool {
        get { UserDefaults.standard.bool(forKey: vocabConsentKey) }
        set { UserDefaults.standard.set(newValue, forKey: vocabConsentKey) }
    }

    // MARK: - Vocabulary Contribution (no-op)

    func syncVocabularyIfNeeded() {}
}
