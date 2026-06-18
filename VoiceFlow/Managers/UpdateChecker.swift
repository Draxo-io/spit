import Foundation
import AppKit

/// Checks for app updates by polling latest.json on getspit.app.
/// Lightweight, zero dependencies — uses plain URLSession.
///
/// Flow:
///   1. Called on launch (after 5s delay) and every 24h thereafter.
///   2. Fetches https://getspit.app/latest.json
///   3. Compares `version` + `build` with current bundle.
///   4. If newer: posts `UpdateChecker.updateAvailableNotification`
///      with `UpdateInfo` in userInfo. UI layer decides how to show it.
///   5. `openDownloadPage()` opens the GitHub release URL in the browser.
final class UpdateChecker {

    // ── Singleton ──────────────────────────────────────────────────────────
    static let shared = UpdateChecker()

    // ── Constants ─────────────────────────────────────────────────────────
    static let updateAvailableNotification = Notification.Name("SpitUpdateAvailable")
    // Hosted as a raw file in the GitHub repo — always reflects the latest release.
    private static let latestURL = URL(string: "https://raw.githubusercontent.com/rafaellopes/spit/main/latest.json")!
    private static let checkInterval: TimeInterval = 24 * 3600   // 24h
    private static let initialDelay: TimeInterval = 5            // seconds after launch

    // ── State ─────────────────────────────────────────────────────────────
    private var timer: Timer?
    private(set) var latestInfo: UpdateInfo?

    private init() {}

    // ── Public API ────────────────────────────────────────────────────────

    func startChecking() {
        // First check after short delay so launch isn't impacted.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.initialDelay) { [weak self] in
            self?.check()
            self?.schedulePeriodicCheck()
        }
    }

    func checkManually() {
        check()
    }

    func openDownloadPage() {
        guard let url = latestInfo.flatMap({ URL(string: $0.url) }) else {
            NSWorkspace.shared.open(URL(string: "https://getspit.app")!)
            return
        }
        NSWorkspace.shared.open(url)
    }

    // ── Private ───────────────────────────────────────────────────────────

    private func schedulePeriodicCheck() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.checkInterval,
            repeats: true
        ) { [weak self] _ in self?.check() }
    }

    private func check() {
        let task = URLSession.shared.dataTask(with: Self.latestURL) { [weak self] data, _, error in
            guard let self, let data, error == nil else { return }
            guard let info = try? JSONDecoder().decode(UpdateInfo.self, from: data) else { return }

            self.latestInfo = info

            // Compare versions
            guard self.isNewer(remote: info) else { return }

            vfLog("[UpdateChecker] Update available: \(info.version) (build \(info.build))")

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.updateAvailableNotification,
                    object: nil,
                    userInfo: ["info": info]
                )
            }
        }
        task.resume()
    }

    /// Returns true if the remote version is newer than the running bundle.
    private func isNewer(remote: UpdateInfo) -> Bool {
        let localBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        let localVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

        // First compare build numbers (unambiguous).
        if remote.build != localBuild { return remote.build > localBuild }

        // Fallback: semantic version comparison.
        return versionIsGreater(remote.version, than: localVersion)
    }

    /// Compares "1.2.3" > "1.1.9" style.
    private func versionIsGreater(_ a: String, than b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let len = max(aParts.count, bParts.count)
        for i in 0..<len {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}

// ── Data model ────────────────────────────────────────────────────────────────

struct UpdateInfo: Codable {
    let version: String
    let build: Int
    let date: String
    let url: String
    let notes: String
    let min_os: String

    /// True if this device meets the minimum OS requirement.
    var isCompatible: Bool {
        let current = ProcessInfo.processInfo.operatingSystemVersion
        let parts = min_os.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0
        return current.majorVersion >= major
    }
}
