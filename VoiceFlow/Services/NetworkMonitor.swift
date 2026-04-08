import Foundation
import Network
import Combine

// MARK: - NetworkMonitor
// Observes network reachability via NWPathMonitor.
// Published `isOnline` is intentionally suppressed for local-AI users
// (transcriptionEngine == .local) so the offline LED never shows when
// the user doesn't need the network.

final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    /// True when the device has a usable network path.
    @Published private(set) var isOnline: Bool = true

    /// True when the user should see an "offline" warning in the UI.
    /// False when transcriptionEngine == .local (network not needed).
    var showOfflineWarning: Bool {
        guard !isOnline else { return false }
        // Load settings inline — avoids a circular dependency with DictationController
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
           let settings = try? JSONDecoder().decode(AppSettings.self, from: data),
           settings.transcriptionEngine == .local {
            return false
        }
        return true
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.spit.network-monitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
