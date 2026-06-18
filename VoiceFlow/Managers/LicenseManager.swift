import Foundation

// LicenseManager stub — open-source v2.0.
// All cloud licensing and network calls removed.
// Plan is always .pro and device is always activated (free app).
// deviceIdentifier() kept for opt-in anonymous telemetry.

enum SpitPlan: String, Codable {
    case trial      // kept for UserDefaults decode compat
    case pro
    case lifetime   // kept for UserDefaults decode compat
    case byok       // kept for UserDefaults decode compat
}

enum PlanState {
    case inactive
    case proMonthly
    case lifetime
}

enum LicenseError: LocalizedError {
    case noLicense
    case deviceTrialNotActivated
    case trialExhausted
    case monthlyLimitReached
    case deviceMismatch
    case invalidToken
    case networkError
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let m): return m
        default:                  return "License error."
        }
    }
}

class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    static let apiBase = "https://spit-api.rafa-782.workers.dev"
    static let webBase = "https://getspit.app"

    @Published private(set) var plan: SpitPlan = .pro
    @Published private(set) var isActivated: Bool = true
    @Published private(set) var monthlySecondsUsed: Double = 0
    @Published private(set) var monthlyTTSCharsUsed: Double = 0
    @Published private(set) var ttsLimit: Int? = nil
    @Published private(set) var userEmail: String? = nil

    var ttsExhausted: Bool { false }
    var planState: PlanState { .proMonthly }
    var monthlyTTSMinutesEstimate: Double { 0 }
    var ttsLimitMinutesEstimate: Double? { nil }

    private init() {}

    func getJWT() -> String? { nil }

    @discardableResult
    func refreshStatus() async -> Bool { true }

    func deviceIdentifier() -> String {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments  = ["-rd1", "-c", "IOPlatformExpertDevice"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let range = output.range(of: #""IOPlatformUUID" = "(.+?)""#, options: .regularExpression) {
            let uuid = output[range].components(separatedBy: "\"")[3]
            return uuid
        }
        if let stored = UserDefaults.standard.string(forKey: "spit.deviceId") { return stored }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "spit.deviceId")
        return new
    }
}
