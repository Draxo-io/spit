import Foundation
import Security

// MARK: - KeychainManager
// Guarda a API key do utilizador de forma segura no Keychain do macOS.

class KeychainManager {

    static let shared = KeychainManager()
    private let service = "app.getspit.spit"

    /// Legacy service name used before the app was renamed from VoiceFlow → Spit.
    /// Kept only for one-time migration in getString — never write to this service.
    private let legacyService = "com.rafaellopes.voiceflow"
    private let apiKeyAccount = "openai-api-key"
    private let groqKeyAccount = "groq-api-key"

    private init() {}

    // MARK: - Guardar API Key

    func saveAPIKey(_ key: String) -> Bool {
        let data = key.data(using: .utf8)!
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: apiKeyAccount,
            kSecValueData:   data
        ]

        // Apagar entrada existente antes de criar nova
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Obter API Key

    func getAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      apiKeyAccount,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }

        return key
    }

    // MARK: - Apagar API Key

    func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: apiKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Verificar se existe

    var hasAPIKey: Bool {
        return getAPIKey() != nil
    }

    // MARK: - Groq API Key

    func saveGroqKey(_ key: String) -> Bool {
        let data = key.data(using: .utf8)!
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: groqKeyAccount,
            kSecValueData:   data
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    func getGroqKey() -> String? { getString(account: groqKeyAccount) }
    func deleteGroqKey() { deleteString(account: groqKeyAccount) }
    var hasGroqKey: Bool { getGroqKey() != nil }

    // MARK: - Generic string storage (used by LicenseManager for JWT, etc.)

    func saveString(_ value: String, account: String) {
        let data = value.data(using: .utf8)!
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData:   data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func getString(account: String) -> String? {
        // Try current service first.
        if let value = readFromService(service, account: account) { return value }

        // One-time migration: if not found under current service, check the legacy
        // service name ("com.rafaellopes.voiceflow") used before the app rename.
        // If found there, re-save under the current service and delete the old entry.
        if let value = readFromService(legacyService, account: account) {
            saveString(value, account: account)          // write to current service
            deleteFromService(legacyService, account: account)  // clean up old entry
            return value
        }

        return nil
    }

    private func readFromService(_ svc: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: svc,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteFromService(_ svc: String, account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: svc,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func deleteString(account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
