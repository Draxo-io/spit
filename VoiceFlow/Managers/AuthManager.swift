import Foundation
import AppKit
import Combine

// MARK: - AuthManager
// Gere autenticação por login via browser (magic link → JWT).
// Fluxo: app.getspit.com/login → spit://auth?jwt=<TOKEN>
// Ver SPEC-AUTH.md para especificação completa.

struct UserAccount: Codable {
    let email: String
    let plan: SpitPlan
    let activatedAt: Date
    let expiresAt: Date?  // nil para lifetime/byok
}

@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    // MARK: - Published state

    @Published private(set) var account: UserAccount?

    var isAuthenticated: Bool { account != nil }

    /// Returns the stored JWT token (or nil if not authenticated). Used by API calls
    /// that need to authenticate the user with the backend (e.g. customer portal URL).
    var jwtToken: String? {
        KeychainManager.shared.getString(account: jwtKey)
    }

    // MARK: - Keychain keys

    private let jwtKey     = "spit-auth-jwt"
    private let refreshKey = "spit-auth-refresh"

    // MARK: - Init

    private init() {
        loadFromKeychain()
    }

    // MARK: - Login (abre browser)

    func login() {
        let url = URL(string: "https://app.getspit.com/login")!
        NSWorkspace.shared.open(url)
        vfLog("AuthManager — browser opened for login")
    }

    // MARK: - Logout

    func logout() {
        KeychainManager.shared.deleteString(account: jwtKey)
        KeychainManager.shared.deleteString(account: refreshKey)
        account = nil
        // Notificar LicenseManager para voltar ao estado trial
        LicenseManager.shared.clearAuthState()
        vfLog("AuthManager — logged out")
    }

    // MARK: - Handle deep link  spit://auth?jwt=xxx

    func handleDeepLink(jwt: String) async {
        vfLog("AuthManager — JWT received, fetching account…")
        KeychainManager.shared.saveString(jwt, account: jwtKey)

        if let acc = await fetchAccount(jwt: jwt) {
            account = acc
            persistAccount(acc)
            LicenseManager.shared.applyAuthPlan(acc.plan, email: acc.email)
            vfLog("AuthManager — authenticated as \(acc.email) plan=\(acc.plan.rawValue)")
        } else {
            vfLog("AuthManager — failed to fetch account after deep link")
            KeychainManager.shared.deleteString(account: jwtKey)
        }
    }

    // MARK: - Refresh forçado (chamar quando o utilizador abre UI relevante)

    /// Notification posted quando o plano server-side mudou em relação ao que estava em memória.
    /// userInfo: ["oldPlan": SpitPlan, "newPlan": SpitPlan]
    static let planChangedNotification = Notification.Name("SpitPlanChanged")

    /// Força refresh do `/auth/me`. Se o plano mudou, posta `planChangedNotification`.
    /// Chamar quando o utilizador abre o popover ou as Settings — barato e útil.
    func refreshAccount() async {
        guard let jwt = KeychainManager.shared.getString(account: jwtKey) else { return }
        let oldPlan = account?.plan
        guard let acc = await fetchAccount(jwt: jwt) else { return }
        account = acc
        persistAccount(acc)
        LicenseManager.shared.applyAuthPlan(acc.plan, email: acc.email)
        if let oldPlan, oldPlan != acc.plan {
            vfLog("AuthManager — plan changed server-side: \(oldPlan.rawValue) → \(acc.plan.rawValue)")
            NotificationCenter.default.post(
                name: Self.planChangedNotification,
                object: nil,
                userInfo: ["oldPlan": oldPlan, "newPlan": acc.plan]
            )
        }
    }

    func refreshIfNeeded() async {
        guard let jwt = KeychainManager.shared.getString(account: jwtKey) else { return }

        // Se o JWT expira em menos de 7 dias, tentar renovar
        if let exp = jwtExpiry(jwt), exp.timeIntervalSinceNow < 7 * 86400 {
            vfLog("AuthManager — JWT expiring soon, refreshing…")
            if let newJWT = await refreshJWT() {
                KeychainManager.shared.saveString(newJWT, account: jwtKey)
                if let acc = await fetchAccount(jwt: newJWT) {
                    account = acc
                    persistAccount(acc)
                    LicenseManager.shared.applyAuthPlan(acc.plan, email: acc.email)
                }
            } else {
                vfLog("AuthManager — refresh failed, clearing auth state")
                logout()
            }
            return
        }

        // JWT ainda válido — apenas recarregar conta em memória
        if account == nil {
            if let acc = await fetchAccount(jwt: jwt) {
                account = acc
                persistAccount(acc)
                LicenseManager.shared.applyAuthPlan(acc.plan, email: acc.email)
            }
        }
    }

    // MARK: - Fetch account from server

    private func fetchAccount(jwt: String) async -> UserAccount? {
        guard let url = URL(string: "\(LicenseManager.apiBase)/auth/me") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let obj = try? JSONDecoder().decode(AuthMeResponse.self, from: data)
        else { return nil }

        return UserAccount(
            email: obj.email,
            plan: SpitPlan(rawValue: obj.plan) ?? .trial,
            activatedAt: obj.activated_at ?? Date(),
            expiresAt: obj.expires_at
        )
    }

    // MARK: - Refresh JWT

    private func refreshJWT() async -> String? {
        guard let refresh = KeychainManager.shared.getString(account: refreshKey) else { return nil }
        guard let url = URL(string: "\(LicenseManager.apiBase)/auth/refresh") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
        req.timeoutInterval = 10

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let obj = try? JSONDecoder().decode(RefreshResponse.self, from: data)
        else { return nil }

        if let newRefresh = obj.refresh_token {
            KeychainManager.shared.saveString(newRefresh, account: refreshKey)
        }
        return obj.jwt
    }

    // MARK: - Keychain persistence

    private func loadFromKeychain() {
        // Carrega conta guardada em UserDefaults (snapshot do último fetch)
        if let data = UserDefaults.standard.data(forKey: "spit.authAccount"),
           let acc = try? JSONDecoder().decode(UserAccount.self, from: data) {
            account = acc
        }
    }

    func persistAccount(_ acc: UserAccount) {
        account = acc
        if let data = try? JSONEncoder().encode(acc) {
            UserDefaults.standard.set(data, forKey: "spit.authAccount")
        }
    }

    // MARK: - JWT expiry

    private func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        // Base64url → Base64
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = payload.count % 4
        if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: payload),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? TimeInterval
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Response models

    private struct AuthMeResponse: Codable {
        let email: String
        let plan: String
        let activated_at: Date?
        let expires_at: Date?
    }

    private struct RefreshResponse: Codable {
        let jwt: String
        let refresh_token: String?
    }
}
