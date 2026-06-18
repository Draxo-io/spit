import Foundation
import AppKit

// MARK: - CrashWatchdog
//
// Captura mortes da app que o `CrashReporter` baseado em .ips do sistema NÃO
// consegue ver — em particular:
//
//   • SIGKILL silenciosos do kernel/sandbox (não geram .ips).
//   • Saídas inesperadas a meio de uma operação (PTT em curso, etc.).
//   • Exceções não capturadas (ObjC NSException).
//   • Sinais síncronos: SIGSEGV, SIGABRT, SIGILL, SIGFPE, SIGBUS, SIGTRAP, SIGPIPE.
//
// Mecânica:
//
//   1. No arranque (`install()`), faz `detectPreviousExit()`:
//      Lê o último status em UserDefaults. Se a sessão anterior estava marcada
//      como "running" mas nunca chegou a "graceful", é morte silenciosa →
//      reporta para o backend.
//
//   2. Instala `NSSetUncaughtExceptionHandler` e `signal()` handlers para os
//      sinais síncronos. Cada handler escreve "crashed" + causa em UserDefaults
//      ANTES de a app morrer (sob pena de o handler nem chegar a correr) — o
//      próximo arranque envia o relatório.
//
//   3. Inicia um heartbeat (timer) que actualiza o timestamp a cada 5s.
//      Permite saber, no próximo arranque, quando foi a última vez que a app
//      estava viva.
//
//   4. `markGraceful()` é chamado em `applicationWillTerminate` — sinaliza
//      saída limpa para o próximo arranque não a confundir com crash.
//
// Notas técnicas:
//
//   • Em sandbox, `~/Library/Logs/DiagnosticReports/` é INACESSÍVEL — daí esta
//     abordagem in-process complementar ao `CrashReporter`.
//
//   • `signal()` handlers só devem chamar funções *async-signal-safe*. Em rigor
//     `UserDefaults.set` não é. Na prática funciona quase sempre porque Foundation
//     usa locks simples, mas para signals violentos (SIGSEGV) pode falhar. O
//     trade-off é aceitável para o nosso uso (menu bar app, sem multi-thread
//     pesado a meio de Foundation).

@MainActor
final class CrashWatchdog {

    static let shared = CrashWatchdog()
    private init() {}

    // MARK: - UserDefaults keys

    private static let kHeartbeat = "spit.crashwatch.heartbeat"      // Double (Unix s)
    private static let kStatus    = "spit.crashwatch.status"         // "running" | "graceful" | "crashed"
    private static let kCause     = "spit.crashwatch.cause"          // String
    private static let kVersion   = "spit.crashwatch.version"        // String
    private static let kReported  = "spit.crashwatch.reportedIds"    // [String] — UUIDs já enviados

    // MARK: - State

    private var heartbeatTimer: Timer?

    // MARK: - Public lifecycle

    /// Chamado uma vez em `applicationDidFinishLaunching`, **antes** de qualquer
    /// trabalho pesado.
    func install() {
        detectPreviousExit()
        installExceptionHandler()
        installSignalHandlers()
        startHeartbeat()
        setStatus("running")
        vfLog("[CrashWatchdog] installed (pid=\(getpid()))")
    }

    /// Chamado em `applicationWillTerminate` — marca saída limpa.
    func markGraceful() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        setStatus("graceful")
        UserDefaults.standard.synchronize()
        vfLog("[CrashWatchdog] graceful shutdown marked")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        updateHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHeartbeat() }
        }
    }

    private func updateHeartbeat() {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: Self.kHeartbeat)
        d.set(currentAppVersion(), forKey: Self.kVersion)
    }

    // MARK: - Status + cause

    private func setStatus(_ status: String) {
        UserDefaults.standard.set(status, forKey: Self.kStatus)
    }

    /// Definir causa sem perder a anterior se já gravada.
    private static func setCauseIfEmpty(_ cause: String) {
        let d = UserDefaults.standard
        if (d.string(forKey: kCause) ?? "").isEmpty {
            d.set(cause, forKey: kCause)
            d.set("crashed", forKey: kStatus)
            d.synchronize()
        }
    }

    // MARK: - Handlers

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.prefix(20).joined(separator: " || ")
            let cause = "uncaught_NSException[\(exception.name.rawValue)]: \(exception.reason ?? "")  ||  \(stack)"
            CrashWatchdog.setCauseIfEmpty(cause)
        }
    }

    private func installSignalHandlers() {
        // SIGTERM e SIGINT são habitualmente "limpos" mas se chegam é porque algo
        // externo nos mandou parar — vale a pena registar.
        let signals: [(Int32, String)] = [
            (SIGABRT, "SIGABRT"), (SIGILL,  "SIGILL"),  (SIGFPE, "SIGFPE"),
            (SIGSEGV, "SIGSEGV"), (SIGBUS,  "SIGBUS"),  (SIGTRAP, "SIGTRAP"),
            (SIGPIPE, "SIGPIPE"), (SIGTERM, "SIGTERM"), (SIGINT,  "SIGINT"),
        ]
        for (sig, name) in signals {
            signal(sig) { rec in
                // ATENÇÃO: apenas funções minimamente async-signal-safe. Mantém curto.
                let signalName: String
                switch rec {
                case SIGABRT: signalName = "SIGABRT"
                case SIGILL:  signalName = "SIGILL"
                case SIGFPE:  signalName = "SIGFPE"
                case SIGSEGV: signalName = "SIGSEGV"
                case SIGBUS:  signalName = "SIGBUS"
                case SIGTRAP: signalName = "SIGTRAP"
                case SIGPIPE: signalName = "SIGPIPE"
                case SIGTERM: signalName = "SIGTERM"
                case SIGINT:  signalName = "SIGINT"
                default:      signalName = "SIG_\(rec)"
                }
                CrashWatchdog.setCauseIfEmpty("signal_\(signalName)")
                // Restaurar default e re-raise para que o crash siga o caminho normal
                // (e o macOS gere o .ips se aplicável).
                signal(rec, SIG_DFL)
                raise(rec)
            }
            _ = name  // silencia warning de unused
        }
    }

    // MARK: - Detect previous exit

    private func detectPreviousExit() {
        let d = UserDefaults.standard
        let prevStatus    = d.string(forKey: Self.kStatus) ?? ""
        let prevHeartbeat = d.double(forKey: Self.kHeartbeat)
        let prevVersion   = d.string(forKey: Self.kVersion) ?? "?"
        let prevCause     = d.string(forKey: Self.kCause)   ?? ""

        defer {
            // Limpar a causa para esta nova sessão.
            d.removeObject(forKey: Self.kCause)
        }

        guard !prevStatus.isEmpty, prevStatus != "graceful" else { return }

        let lastSeen = Date(timeIntervalSince1970: prevHeartbeat)
        let ageSec   = Int(Date().timeIntervalSince1970 - prevHeartbeat)

        let kind: String
        if prevStatus == "crashed" && !prevCause.isEmpty {
            kind = prevCause
        } else {
            // Status era "running" e morreu sem chegar a "graceful" nem a "crashed".
            // Sinal não capturado / SIGKILL / sandbox kill / out-of-resources.
            kind = "silent_exit"
        }

        vfLog("[CrashWatchdog] Previous exit detected: status=\(prevStatus), kind=\(kind.prefix(80)), lastHeartbeat=\(Int(prevHeartbeat)) (\(ageSec)s ago)")

        let incidentId = UUID().uuidString
        // Não duplicar (caso reportemos múltiplas vezes a mesma morte).
        var reported = d.stringArray(forKey: Self.kReported) ?? []
        if reported.contains(incidentId) { return }
        reported.append(incidentId)
        d.set(Array(reported.suffix(200)), forKey: Self.kReported)

    }

    // MARK: - Helpers

    private func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Últimas N linhas do nosso debug log. Sandbox-aware (NSHomeDirectory aponta para o container).
    nonisolated private func tailDebugLog(lines: Int) -> [String] {
        let path = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Spit/spit-debug.log")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        let split = text.split(separator: "\n", omittingEmptySubsequences: true)
        return split.suffix(lines).map(String.init)
    }
}
