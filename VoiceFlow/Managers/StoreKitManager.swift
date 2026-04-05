import Foundation
import StoreKit

// MARK: - StoreKitManager
// Gere a compra única "Spit Pro" via StoreKit 2.
// Product ID: app.getspit.pro
// Modelo: pay-once, desbloqueio permanente.

@MainActor
class StoreKitManager: ObservableObject {

    static let shared = StoreKitManager()

    // MARK: - Estado

    @Published private(set) var proProduct: Product?
    @Published private(set) var isPro: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var purchaseError: String?

    private let proProductID = "app.getspit.pro"
    private var transactionListener: Task<Void, Error>?

    // MARK: - Init

    private init() {
        transactionListener = listenForTransactions()
        Task {
            await loadProducts()
            await checkProStatus()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Carregar Produto

    func loadProducts() async {
        do {
            let products = try await Product.products(for: [proProductID])
            proProduct = products.first
            vfLog("StoreKit — product loaded: \(proProduct?.displayName ?? "nil")")
        } catch {
            vfLog("StoreKit — failed to load products: \(error)")
        }
    }

    // MARK: - Verificar Estado Pro

    func checkProStatus() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == proProductID,
               transaction.revocationDate == nil {
                isPro = true
                vfLog("StoreKit — Pro active ✅")
                return
            }
        }
        isPro = false
        vfLog("StoreKit — Pro not active")
    }

    // MARK: - Comprar Pro

    func purchasePro() async {
        guard let product = proProduct else {
            purchaseError = "Product not available. Check your connection."
            return
        }

        isLoading = true
        purchaseError = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    isPro = true
                    vfLog("StoreKit — purchase successful ✅")
                case .unverified(_, let error):
                    purchaseError = "Purchase could not be verified: \(error.localizedDescription)"
                }
            case .userCancelled:
                vfLog("StoreKit — user cancelled")
            case .pending:
                vfLog("StoreKit — purchase pending (Ask to Buy / parental controls)")
                purchaseError = "Purchase is pending approval."
            @unknown default:
                break
            }
        } catch StoreKitError.notEntitled {
            purchaseError = "Purchase not allowed on this device."
        } catch StoreKitError.networkError(let e) {
            purchaseError = "Network error: \(e.localizedDescription)"
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Restaurar Compras

    func restorePurchases() async {
        isLoading = true
        do {
            try await AppStore.sync()
            await checkProStatus()
            vfLog("StoreKit — restore sync complete")
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
        isLoading = false
    }

    // MARK: - Listener de Transações (para compras externas, promoções, etc.)

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached {
            for await result in Transaction.updates {
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await MainActor.run {
                        if transaction.productID == self.proProductID {
                            self.isPro = transaction.revocationDate == nil
                        }
                    }
                }
            }
        }
    }
}
