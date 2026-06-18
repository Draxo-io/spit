import Foundation
import Combine

// MARK: - CreditsManager
// Gere a API key BYOK do utilizador e tracking de custo estimado mensal.

class CreditsManager: ObservableObject {

    static let shared = CreditsManager()

    // MARK: - Estado

    @Published private(set) var totalSecondsTranscribed: Double = 0   // lifetime total
    @Published private(set) var monthlySecondsTranscribed: Double = 0  // current month only

    // MARK: - TTS (Read selection) tracking
    @Published private(set) var totalSecondsRead: Double = 0    // lifetime TTS
    @Published private(set) var monthlySecondsRead: Double = 0  // current month TTS

    /// Estimated Whisper cost for the current calendar month — $0.006 / min
    var estimatedMonthlyCost: Double {
        monthlySecondsTranscribed / 60.0 * 0.006
    }

    /// Compact display: "~$0.04 /mo" — always in USD so users worldwide understand the currency
    var estimatedMonthlyCostFormatted: String {
        let cost = estimatedMonthlyCost
        if cost < 0.0001 {
            return "~$0.00 /mo"
        } else if cost < 0.01 {
            return String(format: "~$%.4f /mo", cost)
        } else {
            return String(format: "~$%.2f /mo", cost)
        }
    }

    var hasUserAPIKey: Bool {
        KeychainManager.shared.hasAPIKey
    }

    // MARK: - Chave a usar

    var activeAPIKey: String? {
        return KeychainManager.shared.getAPIKey()
    }

    private let totalSecondsKey        = "creditsTotalSeconds"
    private let monthlySecondsKey      = "creditsMonthlySeconds"
    private let monthlyPeriodKey       = "creditsMonthlyPeriod"   // stored as "YYYY-MM"
    private let totalTTSSecondsKey     = "creditsTotalTTSSeconds"
    private let monthlyTTSSecondsKey   = "creditsMonthlyTTSSeconds"
    private let monthlyTTSPeriodKey    = "creditsMonthlyTTSPeriod"

    private var currentMonthPeriod: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date())
    }

    private init() {
        totalSecondsTranscribed = UserDefaults.standard.double(forKey: totalSecondsKey)

        // Load monthly counter — reset if we've rolled into a new month
        let savedPeriod = UserDefaults.standard.string(forKey: monthlyPeriodKey) ?? ""
        if savedPeriod == currentMonthPeriod {
            monthlySecondsTranscribed = UserDefaults.standard.double(forKey: monthlySecondsKey)
        } else {
            monthlySecondsTranscribed = 0
            UserDefaults.standard.set(0, forKey: monthlySecondsKey)
            UserDefaults.standard.set(currentMonthPeriod, forKey: monthlyPeriodKey)
        }

        // TTS counters — same month-rollover pattern
        totalSecondsRead = UserDefaults.standard.double(forKey: totalTTSSecondsKey)
        let savedTTSPeriod = UserDefaults.standard.string(forKey: monthlyTTSPeriodKey) ?? ""
        if savedTTSPeriod == currentMonthPeriod {
            monthlySecondsRead = UserDefaults.standard.double(forKey: monthlyTTSSecondsKey)
        } else {
            monthlySecondsRead = 0
            UserDefaults.standard.set(0, forKey: monthlyTTSSecondsKey)
            UserDefaults.standard.set(currentMonthPeriod, forKey: monthlyTTSPeriodKey)
        }

        vfLog("CreditsManager.init() — hasKey: \(hasUserAPIKey), monthly: \(monthlySecondsTranscribed)s, tts: \(monthlySecondsRead)s")
    }

    // MARK: - Recording usage

    /// Record transcription seconds (called after successful dictation).
    func recordTranscription(seconds: Double) {
        guard seconds > 0 else { return }
        totalSecondsTranscribed += seconds
        monthlySecondsTranscribed += seconds
        UserDefaults.standard.set(totalSecondsTranscribed, forKey: totalSecondsKey)
        UserDefaults.standard.set(monthlySecondsTranscribed, forKey: monthlySecondsKey)
        UserDefaults.standard.set(currentMonthPeriod, forKey: monthlyPeriodKey)
    }

    /// Record TTS seconds (called after successful read selection).
    func recordTTS(seconds: Double) {
        guard seconds > 0 else { return }
        totalSecondsRead += seconds
        monthlySecondsRead += seconds
        UserDefaults.standard.set(totalSecondsRead, forKey: totalTTSSecondsKey)
        UserDefaults.standard.set(monthlySecondsRead, forKey: monthlyTTSSecondsKey)
        UserDefaults.standard.set(currentMonthPeriod, forKey: monthlyTTSPeriodKey)
    }

    // MARK: - Activar BYOK

    func activateUserKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let saved = KeychainManager.shared.saveAPIKey(key)
        if saved {
            print("[CreditsManager] Modo BYOK activado")
        }
        return saved
    }

    // MARK: - Remover chave

    func removeUserKey() {
        KeychainManager.shared.deleteAPIKey()
    }

    // MARK: - Verificar se pode ditar

    func canDictate() -> Bool {
        return hasUserAPIKey
    }

    // MARK: - Mensagem de estado para UI

    var statusMessage: String {
        if hasUserAPIKey {
            return String(localized: "Own key")
        } else {
            return String(localized: "No API key")
        }
    }
}
