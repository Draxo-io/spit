import AppKit
import SwiftUI

// MARK: - ReviewHUDWindowController
// Janela flutuante para o ReviewHUD.
// Aparece no canto inferior direito do ecrã, sobre todas as janelas.

class ReviewHUDWindowController: NSWindowController {

    static let shared = ReviewHUDWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true   // system generates shadow from window alpha mask → follows rounded corners
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Mostrar HUD

    func show(result: DictationResult, controller: DictationController) {
        guard let screen = NSScreen.main else { return }

        // Posicionar no canto inferior direito
        let screenRect = screen.visibleFrame
        let windowWidth: CGFloat = 360
        let margin: CGFloat = 20
        let x = screenRect.maxX - windowWidth - margin
        let y = screenRect.minY + margin

        // Criar SwiftUI view
        let hudView = ReviewHUDView(result: result, controller: controller) { [weak self] in
            self?.close()
        }

        let hosting = NSHostingView(rootView: hudView)
        window?.contentView = hosting

        // Size window to fit SwiftUI content (height varies depending on which banners are shown)
        let fittingSize = hosting.fittingSize
        let windowHeight = max(fittingSize.height, 120)
        // Re-anchor bottom-right corner after height is known
        let windowY = y  // y is already the bottom edge
        window?.setFrame(NSRect(x: x, y: windowY, width: windowWidth, height: windowHeight), display: false)

        window?.orderFrontRegardless()

        // Animar entrada
        window?.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.window?.animator().alphaValue = 1
        }
    }

    // MARK: - Fechar

    override func close() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.window?.animator().alphaValue = 0
        } completionHandler: {
            super.close()
        }
    }
}
