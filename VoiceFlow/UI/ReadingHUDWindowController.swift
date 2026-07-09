import AppKit
import SwiftUI

// MARK: - ReadingHUDWindowController
// Floating pill shown while TTS is reading text aloud.
// Uses .popUpMenu level to ensure visibility above all app windows.

class ReadingHUDWindowController: NSWindowController {

    static let shared = ReadingHUDWindowController()

    private var dismissToken = UUID()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 52),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show

    func show() {
        let work = { [self] in
            guard let window = window else {
                vfLog("ReadingHUD — window is nil!")
                return
            }

            dismissToken = UUID()

            let view = ReadingHUDView()
            let hosting = NSHostingView(rootView: view)
            hosting.autoresizingMask = [.width, .height]
            window.contentView = hosting

            positionOnScreen()

            window.alphaValue = 1
            window.orderFrontRegardless()
            vfLog("ReadingHUD — shown at \(window.frame)")
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Dismiss

    func dismiss() {
        let work = { [self] in
            guard let window = window else { return }
            let token = UUID()
            dismissToken = token
            let capturedToken = token
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard self?.dismissToken == capturedToken else { return }
                    self?.window?.orderOut(nil)
                }
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Positioning

    private func positionOnScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let windowWidth: CGFloat = 320
        let windowHeight: CGFloat = 52
        let screenRect = screen.visibleFrame
        let margin: CGFloat = 20

        let reviewHUDWidth: CGFloat = 360
        let x = screenRect.maxX - reviewHUDWidth - margin + (reviewHUDWidth - windowWidth)
        let y = screenRect.minY + margin

        window?.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
                         display: true)
    }
}
