import AppKit
import SwiftUI
import Combine

// MARK: - MenuBarController
// Gere o ícone na menu bar e o painel flutuante associado.
// Usa NSPanel em vez de NSPopover — o NSPopover em apps LSUIElement no macOS 14/15
// perde a âncora ao botão e aparece numa posição arbitrária.

@MainActor
class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hostingView: NSHostingView<AnyView>?
    private var dictationController: DictationController
    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?

    init(dictationController: DictationController) {
        self.dictationController = dictationController
        super.init()
    }

    // MARK: - Setup

    func setup() {
        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Spit")
            button.action = #selector(togglePanel(_:))
            button.target = self
        }

        // NSPanel — nonactivatingPanel: não tira o foco da app onde o utilizador está a escrever
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu          // fica por cima de tudo
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        rebuildContent()

        // Observar mudanças de estado para actualizar ícone
        observeState()
    }

    // MARK: - Content

    private func rebuildContent() {
        let content = MenuBarPopoverView()
            .environmentObject(dictationController)
            .environmentObject(CreditsManager.shared)
            .environmentObject(VocabularyManager.shared)

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting
        self.hostingView = hosting
    }

    // MARK: - Observar Estado

    private func observeState() {
        dictationController.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }

        let iconName = state.menuBarIcon
        button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Spit")

        switch state {
        case .recording:
            startBlinking()
        default:
            stopBlinking()
        }
    }

    // MARK: - Blinking durante gravação

    private var blinkTimer: Timer?
    private var blinkState = false

    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.blinkState.toggle()
            button.alphaValue = self.blinkState ? 1.0 : 0.3
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        statusItem.button?.alphaValue = 1.0
    }

    // MARK: - Toggle Panel

    @objc func togglePanel(_ sender: AnyObject?) {
        vfLog("togglePanel — isVisible: \(panel.isVisible)")
        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem.button else {
            vfLog("openPanel — statusItem button is nil")
            return
        }

        // Ajustar tamanho ao conteúdo SwiftUI
        let panelWidth: CGFloat = 300
        var panelHeight: CGFloat = 240
        if let hosting = hostingView {
            let fitted = hosting.fittingSize
            if fitted.height > 10 { panelHeight = fitted.height }
        }

        // Obter posição real do botão no ecrã
        // Método 1 (preferido): via button.window.convertToScreen
        // Método 2 (fallback): via NSScreen.main — coloca no canto superior direito
        let buttonScreenFrame: NSRect

        if let buttonWindow = button.window {
            let frameInWindow = button.convert(button.bounds, to: nil)
            buttonScreenFrame = buttonWindow.convertToScreen(frameInWindow)
            vfLog("openPanel — buttonWindow OK, buttonScreenFrame: \(buttonScreenFrame)")
        } else {
            // Fallback: usar mouse location para inferir o ecrã ativo
            let mouseScreen = NSScreen.screens.first(where: {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            }) ?? NSScreen.main
            let sf = mouseScreen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // Posicionar no canto superior direito do ecrã ativo (onde a menu bar está)
            buttonScreenFrame = NSRect(
                x: sf.maxX - panelWidth / 2 - 20,
                y: sf.maxY - 22,  // altura aproximada da menu bar
                width: panelWidth,
                height: 22
            )
            vfLog("openPanel — FALLBACK positioning near top-right, screen: \(sf)")
        }

        // Posicionar imediatamente abaixo do ícone, centrado horizontalmente
        let x = buttonScreenFrame.midX - panelWidth / 2
        let y = buttonScreenFrame.minY - panelHeight - 6  // 6px de espaço

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: false)

        // Garantir que não sai fora dos limites do ecrã
        let targetScreen = NSScreen.screens.first(where: {
            NSPointInRect(NSPoint(x: buttonScreenFrame.midX, y: buttonScreenFrame.midY), $0.frame)
        }) ?? NSScreen.main

        if let screen = targetScreen {
            var frame = panel.frame
            if frame.maxX > screen.visibleFrame.maxX {
                frame.origin.x = screen.visibleFrame.maxX - frame.width - 8
            }
            if frame.origin.x < screen.visibleFrame.minX {
                frame.origin.x = screen.visibleFrame.minX + 8
            }
            if frame.origin.y < screen.visibleFrame.minY {
                // Se o painel ficaria abaixo do ecrã, mostrar acima do ícone
                frame.origin.y = buttonScreenFrame.maxY + 6
            }
            panel.setFrame(frame, display: false)
        }

        panel.orderFront(nil)
        vfLog("openPanel — final frame: \(panel.frame)")

        // Fechar quando clica fora do painel
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        panel.orderOut(nil)
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
