import Foundation
import Security

// MARK: - KeychainManager
// Guarda a API key do utilizador de forma segura no Keychain do macOS.

class KeychainManager {

    static let shared = KeychainManager()
    private let service = "com.rafaellopes.voiceflow"
    private let apiKeyAccount = "openai-api-key"

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
}
