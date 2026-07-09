import AppKit
import SwiftUI

// MARK: - RecordingHUDWindowController
// Floating pill shown from recording start until the ReviewHUD appears.
// Uses .popUpMenu level (same as the menu bar panel) to ensure reliable visibility
// even when Spit is a UIElement app and another app is focused.

class RecordingHUDWindowController: NSWindowController {

    static let shared = RecordingHUDWindowController()

    private var hudState: RecordingHUDState = .recording(words: "", startedAt: Date())
    private var recordingStartedAt: Date = Date()
    private var dismissTask: DispatchWorkItem?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu             // must match menu bar panel — .floating is too low for UIElement apps
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Show (loading state — modelo a recarregar)

    func showLoading() {
        let work = { [self] in
            dismissTask?.cancel()
            dismissTask = nil
            hudState = .loading
            presentWithState()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Show (recording state)

    func showRecording() {
        let work = { [self] in
            dismissTask?.cancel()
            dismissTask = nil
            recordingStartedAt = Date()
            hudState = .recording(words: "", startedAt: recordingStartedAt)
            presentWithState()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Update rolling words

    func updateWords(_ words: String) {
        let work = { [self] in
            guard case .recording = hudState else { return }
            hudState = .recording(words: words, startedAt: recordingStartedAt)
            updateContent()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Transition to processing

    func transitionToProcessing() {
        let work = { [self] in
            hudState = .processing(startedAt: Date())
            updateContent()
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Dismiss

    func dismiss() {
        DispatchQueue.main.async { [weak self] in
            self?.dismissTask?.cancel()
            guard let self, let _ = self.window else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    window.animator().alphaValue = 0
                } completionHandler: {
                    window.orderOut(nil)
                }
            }
            self.dismissTask = work
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Private

    private func presentWithState() {
        guard let window = window else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouseLocation, $0.frame, false)
        }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let windowWidth: CGFloat  = 300
        let screenRect = screen.visibleFrame
        let margin: CGFloat = 20

        // Right-align with ReviewHUD (360px wide) so the transition is seamless
        let reviewHUDWidth: CGFloat = 360
        let x = screenRect.maxX - reviewHUDWidth - margin + (reviewHUDWidth - windowWidth)
        let y = screenRect.minY + margin

        let view = RecordingHUDView(state: hudState)
        let hosting = NSHostingView(rootView: view)

        // Set fixed height — avoids _NSDetectedLayoutRecursion from calling fittingSize
        // before the hosting view is in the window hierarchy.
        window.setFrame(NSRect(x: x, y: y, width: windowWidth, height: 52), display: false)
        window.contentView = hosting
        window.alphaValue = 1
        window.orderFrontRegardless()
    }

    private func updateContent() {
        guard let hosting = window?.contentView as? NSHostingView<RecordingHUDView> else {
            presentWithState()
            return
        }
        hosting.rootView = RecordingHUDView(state: hudState)
    }
}
