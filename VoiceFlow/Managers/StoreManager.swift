import Foundation

// StoreManager stub — open-source v2.0. No StoreKit dependencies.
// hasProSubscription is always true; the app is completely free.

@MainActor
final class StoreManager: ObservableObject {
    static let shared = StoreManager()

    @Published private(set) var hasProSubscription: Bool = true
    @Published private(set) var didLoadEntitlements: Bool = true
    @Published private(set) var purchaseInProgress: Bool = false
    @Published private(set) var lastError: String? = nil

    private init() {}

    func start() {}
    func restore() async {}
    func purchase(_ product: Any) async {}
}
