import Foundation

// AuthManager stub — open-source v2.0. No network calls.

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    static let planChangedNotification = Notification.Name("SpitPlanChanged")

    @Published private(set) var isLoggedIn: Bool = false

    private init() {}

    func refreshIfNeeded() async {}
    func refreshAccount() async {}
    func handleDeepLink(jwt: String) async {}
    func logout() {}
}
