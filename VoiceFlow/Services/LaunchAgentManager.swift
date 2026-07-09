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

    /// Regista o LaunchAgent no launchd do user. Chamar a cada arranque.
    /// Falhar não é crítico: o pior cenário é não relançarmos automaticamente.
    ///
    /// RE-REGISTA SEMPRE (unregister → register), mesmo quando status == .enabled.
    /// O registo do smd fica ancorado ao bundle exacto (path + versão) que chamou
    /// register(). Se essa cópia deixar de existir (ex.: build antiga apagada ou
    /// substituída por update), o launchd falha o relaunch EM SILÊNCIO e a app
    /// não reabre depois de um kill do Jetsam. Bug real 2026-07-09: agent preso
    /// ao build 10 (apagado) → produção 2.1 morta pelo Jetsam nunca reabria.
    /// Re-ancorar no arranque custa milissegundos e garante que o relaunch
    /// aponta sempre para a cópia que está de facto a correr.
    func register() {
        Task { @MainActor in
            let service = SMAppService.agent(plistName: Self.plistName)
            let previous = service.status

            if previous == .enabled {
                try? await service.unregister()
            }

            do {
                try service.register()
                vfLog("[LaunchAgent] ✅ registado e re-ancorado a este bundle (\(Self.plistName), prev: \(statusName(previous)))")
            } catch {
                vfLog("[LaunchAgent] ⚠️ register falhou (\(statusName(service.status))): \(error.localizedDescription)")
            }
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
