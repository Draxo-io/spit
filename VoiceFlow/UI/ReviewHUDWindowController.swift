import AppKit
import SwiftUI

// MARK: - ReviewHUDWindowController
// Floating card shown after a successful dictation, bottom-right corner.
// Height adapts to content (original + translated text can be much taller than plain dictation).
//
// This controller is intentionally minimal — all visibility logic lives in HUDCoordinator.
// The controller only knows how to: schedule a show after a small delay (so the RecordingHUD
// fade-out doesn't overlap), show the card, and close it.

final class ReviewHUDWindowController: NSWindowController {

    static let shared = ReviewHUDWindowController()

    // Token invalidation — prevents a stale scheduled show from firing after a newer call
    // replaced it (e.g. two rapid dictations in a row).
    private var pendingToken: UUID = UUID()

    // Each successful show() increments this. The ReviewHUDView's onDismiss captures the
    // generation at creation time and only closes the window if it still matches — this
    // prevents an old view's 10s auto-dismiss from closing a newer card that replaced it
    // in the same window.
    private var windowGeneration: Int = 0

    // Token that prevents a stale close() animation completionHandler from hiding the
    // window after a newer show() already made it visible again.
    // Pattern: close() captures the current token; show() rotates it; the completionHandler
    // only calls orderOut if the token still matches (i.e. no new show() fired meanwhile).
    private var closeAnimationToken: UUID = UUID()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask:   [.nonactivatingPanel, .borderless],
            backing:     .buffered,
            defer:       true
        )
        panel.level                       = .popUpMenu
        panel.isOpaque                    = false
        panel.backgroundColor             = .clear
        panel.hasShadow                   = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed        = false
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public entry point

    /// Show the ReviewHUD for the given result.
    /// Called from MenuBarController when the user clicks the menu bar icon.
    func showForLastResult(_ result: DictationResult) {
        show(result: result)
    }

    // MARK: - Schedule Show (kept for compatibility)

    /// Schedules a show after `delay` seconds. Later calls invalidate earlier ones.
    func scheduleShow(result: DictationResult, delay: TimeInterval = 0.15) {
        pendingToken = UUID()
        let token = pendingToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingToken == token else {
                vfLog("[ReviewHUD] scheduleShow — stale token, dropped")
                return
            }
            self.show(result: result)
        }
    }

    /// Cancels any pending scheduled show without closing an already-visible card.
    func cancelPendingShow() {
        pendingToken = UUID()
    }

    // MARK: - Show (immediate)

    private func show(result: DictationResult) {
        let work = { [self] in
            guard let window = window else { return }

            // Rotate the token so any in-flight close() completionHandler won't call orderOut.
            closeAnimationToken = UUID()

            vfLog("[ReviewHUD] show() text:'\(result.correctedText.prefix(40))' translated:\(result.wasTranslated)")

            windowGeneration += 1
            let gen = windowGeneration

            // Position: bottom-right of the cursor's screen
            let mouse  = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                         ?? NSScreen.main
                         ?? NSScreen.screens[0]
            let sr = screen.visibleFrame
            let x  = sr.maxX - 440 - 20

            let dc = (NSApp.delegate as? AppDelegate)?.dictationController

            // Inject retry only when saved audio exists — avoids showing the button
            // for unrelated errors (network, auth, etc.) where no audio was kept.
            let hasPendingRetry = dc?.pendingRetryURL != nil
            var hudView = ReviewHUDView(
                result: result,
                onDismiss: { [weak self] in
                    guard let self, self.windowGeneration == gen else { return }
                    self.close()
                },
                translateAction: { _, lang in
                    // Fonte única: sincroniza a config global e re-processa o
                    // lastResult; devolve o texto final já processado para o HUD.
                    await dc?.setDictationTranslation(enabled: !lang.isEmpty, target: lang)
                    return dc?.lastResult?.correctedText
                }
            )
            if hasPendingRetry {
                hudView.retryAction = { [weak self] in
                    dc?.retryPendingDictation()
                    self?.close()
                }
            }
            let hosting = NSHostingView(rootView: hudView)

            // ── Adaptive height ──────────────────────────────────────────────
            // NSHostingView só consegue medir corretamente quando está numa window
            // hierarchy. Medição fora de window dá valores errados (layout incompleto).
            //
            // Fix: attachar à window PRIMEIRO com frame generoso, forçar layout,
            // depois ler fittingSize e ajustar o frame final.
            hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 2000)
            window.contentView = hosting          // entra na window hierarchy
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()       // força layout síncrono

            let fittingHeight = hosting.fittingSize.height
            // 40 pt buffer: NSHostingView.fittingSize por vezes subestima
            // (conteúdo condicional, quebras de linha em casos-limite).
            // Preferimos whitespace extra a cortar o botão Copiar.
            let bufferedHeight = fittingHeight + 40

            // Âncora no canto inferior-direito: fundo da janela rente ao visibleFrame
            // (acima do Dock), a janela cresce para cima.
            // Se o conteúdo for muito alto, cortamos pelo topo — o botão Copiar
            // (em baixo) é mais crítico do que o cabeçalho (em cima).
            let safeMargin: CGFloat = 20
            let windowBottomY = sr.minY + safeMargin
            let maxWindowHeight = sr.maxY - windowBottomY - safeMargin
            let windowHeight = min(max(bufferedHeight, 160), maxWindowHeight)

            window.setFrame(NSRect(x: x, y: windowBottomY, width: 440, height: windowHeight), display: false)
            window.alphaValue = 1
            window.orderFrontRegardless()

            vfLog("[ReviewHUD] ✅ on screen at \(window.frame) (content height: \(windowHeight))")
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - Close

    override func close() {
        let work = { [self] in
            guard let window = window else { return }
            let token = closeAnimationToken  // capture BEFORE animation starts
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                window.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                // Only hide if no new show() was called while we were fading out.
                guard let self, self.closeAnimationToken == token else { return }
                window.orderOut(nil)
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}
