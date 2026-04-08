import AppKit
import SwiftUI

// MARK: - ReadingHUDWindowController
// Manages the floating pill shown while TTS is reading text aloud.
// Mirrors the same positioning logic as RecordingHUDWindowController.

class ReadingHUDWindowController: NSWindowController {

    static let shared = ReadingHUDWindowController()

    private var hostingView: NSHostingView<ReadingHUDView>?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func show() {
        // Always recreate the view to get a fresh @State
        let view = ReadingHUDView()
        let hosting = NSHostingView(rootView: view)
        hosting.frame = window?.contentView?.bounds ?? .zero
        window?.contentView = hosting
        hostingView = hosting

        positionOnScreen()

        window?.alphaValue = 0
        window?.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            window?.animator().alphaValue = 1
        }
    }

    // MARK: - Dismiss

    func dismiss() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    // MARK: - Positioning

    private func positionOnScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
        guard let screen = screen else { return }

        let windowWidth: CGFloat = 320
        let windowHeight: CGFloat = 44
        let screenRect = screen.visibleFrame
        let margin: CGFloat = 20

        // Right-align at the same anchor as RecordingHUD / ReviewHUD
        let reviewHUDWidth: CGFloat = 360
        let x = screenRect.maxX - reviewHUDWidth - margin + (reviewHUDWidth - windowWidth)
        let y = screenRect.minY + margin

        window?.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
                         display: false)
    }
}
