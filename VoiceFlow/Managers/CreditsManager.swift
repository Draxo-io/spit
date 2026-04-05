import Foundation
import Combine

// MARK: - CreditsManager
// Controla o acesso à API e o consumo de minutos do utilizador.
// Modelo: BYOK puro — utilizador usa a sua própria chave OpenAI.
// Free trial = primeiros 30 min com a chave do utilizador (contagem local).

enum APIKeyMode {
    case freeTrial      // Chave própria do utilizador, com contagem de 30 min grátis
    case userKey        // BYOK ilimitado (após confirmar intenção de uso contínuo)
}

class CreditsManager: ObservableObject {

    static let shared = CreditsManager()

    // MARK: - Estado

    @Published private(set) var minutesUsed: Double = 0
    @Published private(set) var mode: APIKeyMode = .freeTrial

    let freeTrialMinutesTotal: Double = 60  // 60 min grátis

    var freeTrialMinutesRemaining: Double {
        max(0, freeTrialMinutesTotal - minutesUsed)
    }

    var freeTrialExhausted: Bool {
        mode == .freeTrial && minutesUsed >= freeTrialMinutesTotal
    }

    var hasUserAPIKey: Bool {
        KeychainManager.shared.hasAPIKey
    }

    // MARK: - Chave a usar

    var activeAPIKey: String? {
        // Sempre usa a chave do utilizador — BYOK puro
        return KeychainManager.shared.getAPIKey()
    }

    private let minutesUsedKey = "creditsMinutesUsed"
    private let modeKey = "creditsMode"

    private init() {
        minutesUsed = UserDefaults.standard.double(forKey: minutesUsedKey)
        let savedMode = UserDefaults.standard.string(forKey: modeKey)
        mode = (savedMode == "userKey") ? .userKey : .freeTrial
        vfLog("CreditsManager.init() — mode: \(mode), minutesUsed: \(minutesUsed)")

        // Verificação de chave no Keychain feita de forma assíncrona
        // para evitar bloquear o init (Keychain pode pedir autorização)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            vfLog("CreditsManager — checking Keychain for user API key...")
            if self.hasUserAPIKey {
                self.mode = .userKey
                vfLog("CreditsManager — modo BYOK auto-activado (chave encontrada)")
            } else {
                vfLog("CreditsManager — sem chave no Keychain")
            }
        }
    }

    // MARK: - Registar Uso

    func registerUsage(seconds: TimeInterval) {
        guard mode == .freeTrial else { return }  // BYOK não tem limite
        let minutes = seconds / 60.0
        minutesUsed += minutes
        UserDefaults.standard.set(minutesUsed, forKey: minutesUsedKey)
    }

    // MARK: - Activar BYOK

    func activateUserKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let saved = KeychainManager.shared.saveAPIKey(key)
        if saved {
            mode = .userKey
            UserDefaults.standard.set("userKey", forKey: modeKey)
            print("[CreditsManager] Modo BYOK activado")
        }
        return saved
    }

    // MARK: - Voltar para Free Trial (ex: remoção de chave)

    func removeUserKey() {
        KeychainManager.shared.deleteAPIKey()
        mode = .freeTrial
        UserDefaults.standard.set("freeTrial", forKey: modeKey)
    }

    // MARK: - Verificar se pode ditar

    func canDictate() -> Bool {
        guard hasUserAPIKey else { return false }
        switch mode {
        case .userKey:
            return true
        case .freeTrial:
            return !freeTrialExhausted
        }
    }

    // MARK: - Mensagem de estado para UI

    var statusMessage: String {
        switch mode {
        case .userKey:
            return String(localized: "Your API key is active — unlimited usage")
        case .freeTrial:
            if freeTrialExhausted {
                return String(localized: "Free trial exhausted — add your API key")
            }
            let remaining = Int(freeTrialMinutesRemaining)
            return String(format: String(localized: "%d free minutes remaining"), remaining)
        }
    }
}
