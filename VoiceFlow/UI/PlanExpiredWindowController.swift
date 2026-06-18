import AppKit
import SwiftUI

// MARK: - PlanExpiredWindowController
// Janela leve e dispensável (fecha com Esc ou clique fora) mostrada quando
// o utilizador prime o atalho global com o plano expirado.
// Ao clicar no CTA, fecha-se e abre a UpgradeWindowController.

final class PlanExpiredWindowController: NSWindowController, NSWindowDelegate {

    static let shared = PlanExpiredWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: PlanExpiredView())
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        guard let screen = NSScreen.main else { return }
        // Centre horizontally, top-third vertically
        let sw = screen.visibleFrame.width
        let sh = screen.visibleFrame.height
        let wx: CGFloat = (sw - 360) / 2 + screen.visibleFrame.minX
        let wy: CGFloat = screen.visibleFrame.minY + sh * 0.65
        window?.setFrameOrigin(NSPoint(x: wx, y: wy))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Auto-dismiss after 8 s if not interacted with
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        perform(#selector(autoDismiss), with: nil, afterDelay: 8)
    }

    @objc private func autoDismiss() {
        window?.orderOut(nil)
    }

    // Dismiss on Esc
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        return true
    }
}

// MARK: - PlanExpiredView

private struct PlanExpiredView: View {

    @StateObject private var license = LicenseManager.shared

    private var message: String {
        switch license.planState {
        case .proMonthly where !LicenseManager.shared.isActivated:
            return "A tua subscrição expirou."
        default:
            return "Subscrição necessária para ditar ou ler."
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.headline)
                    Text("Não é possível ditar ou ler enquanto o plano estiver expirado.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button("Ver opções de renovação →") {
                NSObject.cancelPreviousPerformRequests(
                    withTarget: PlanExpiredWindowController.shared
                )
                PlanExpiredWindowController.shared.window?.orderOut(nil)
                UpgradeWindowController.shared.show()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 360)
    }
}
