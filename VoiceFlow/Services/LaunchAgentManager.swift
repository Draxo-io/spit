import Foundation
import ServiceManagement

// MARK: - LaunchAgentManager
//
// Gere o LaunchAgent embebido que mantém o Spit "vivo" — relança automaticamente
// quando a app sai com erro ou crashar (incluindo SIGKILL silencioso do kernel,
// que o `CrashWatchdog` regista mas não pode reverter sozinho).
//
// Princípio: o plist em `Contents/Library/LaunchAgents/app.getspit.relaunch.plist`
// é registado via `SMAppService.agent(plistName:)`. O launchd passa a monitorizar
// o processo identificado por `BundleProgram` e relança-o quando:
//
//   • exit code != 0 (sinal não tratado, abort, ...).
//   • signaled crash (SIGSEGV/SIGABRT/SIGKILL/etc.).
//
// E NÃO relança quando:
//
//   • NSApp.terminate produz exit code 0 (⌘Q, menu Quit, applicationWillTerminate).
//
// Anti-loop: `ThrottleInterval=30` no plist limita a frequência de relançamento.
// Requer macOS 13+ (SMAppService).

@MainActor
final class LaunchAgentManager {

    static let shared = LaunchAgentManager()
    private init() {}

    /// Nome do plist tal como existe em `Contents/Library/LaunchAgents/`.
    private static let plistName = "app.getspit.relaunch.plist"

    /// Regista o LaunchAgent no launchd do user. Idempotente — chamar a cada arranque.
    /// Falhar não é crítico: o pior cenário é não relançarmos automaticamente.
    func register() {
        let service = SMAppService.agent(plistName: Self.plistName)
        let previous = service.status

        if previous == .enabled {
            vfLog("[LaunchAgent] já registado (\(Self.plistName))")
            return
        }

        do {
            try service.register()
            vfLog("[LaunchAgent] ✅ registado (\(Self.plistName), prev: \(statusName(previous)))")
        } catch {
            vfLog("[LaunchAgent] ⚠️ register falhou (\(statusName(service.status))): \(error.localizedDescription)")
        }
    }

    /// Desregista o LaunchAgent. Útil para desinstalação limpa.
    func unregister() async {
        let service = SMAppService.agent(plistName: Self.plistName)
        do {
            try await service.unregister()
            vfLog("[LaunchAgent] desregistado")
        } catch {
            vfLog("[LaunchAgent] ⚠️ unregister falhou: \(error.localizedDescription)")
        }
    }

    var status: SMAppService.Status {
        SMAppService.agent(plistName: Self.plistName).status
    }

    // MARK: - Helpers

    private func statusName(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered:           return "notRegistered"
        case .enabled:                 return "enabled"
        case .requiresApproval:        return "requiresApproval"
        case .notFound:                return "notFound"
        @unknown default:              return "unknown(\(s.rawValue))"
        }
    }
}
