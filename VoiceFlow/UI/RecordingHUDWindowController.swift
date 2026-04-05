import AppKit
import SwiftUI

// MARK: - RecordingHUDWindowController
// Manages the small floating panel shown during recording and processing.
// Appears at the bottom-right of the screen, anchored to the same corner as ReviewHUD.
// Transitions from recording → processing state, then dismisses when ReviewHUD appears.

class RecordingHUDWindowController: NSWindowController {

    static let shared = RecordingHUDWindowController()

    private var hudState: RecordingHUDState = .recording(words: "")
    private var hostingView: NSHostingView<RecordingHUDView>?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true   // system shadow from alpha mask → follows rounded pill shape
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show (recording state)

    func showRecording() {
        hudState = .recording(words: "")
        presentWithState()
    }

    // MARK: - Update rolling words

    func updateWords(_ words: String) {
        hudState = .recording(words: words)
        refreshView()
    }

    // MARK: - Transition to processing

    func transitionToProcessing() {
        hudState = .processing
        refreshView()
    }

    // MARK: - Dismiss

    func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window?.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    // MARK: - Private

    private func presentWithState() {
        // Usar o monitor onde está o cursor do rato (monitor ativo)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main
        guard let screen = screen else { return }

        let windowWidth: CGFloat = 300
        let windowHeight: CGFloat = 44
        let screenRect = screen.visibleFrame
        let margin: CGFloat = 20
        // Align to the right edge — same anchor as ReviewHUD (360px wide, same margin)
        // This makes the transition seamless: RecordingHUD right-aligns with ReviewHUD right edge
        let reviewHUDWidth: CGFloat = 360
        let x = screenRect.maxX - reviewHUDWidth - margin + (reviewHUDWidth - windowWidth)
        let y = screenRect.minY + margin

        window?.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight),
                         display: false)

        refreshView()

        window?.alphaValue = 0
        window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            window?.animator().alphaValue = 1
        }
    }

    private func refreshView() {
        let view = RecordingHUDView(state: hudState)

        if let existing = hostingView {
            existing.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            hosting.frame = window?.contentView?.bounds ?? .zero
            window?.contentView = hosting
            hostingView = hosting
        }
    }
}
