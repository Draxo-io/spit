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
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.blinkState.toggle()
                button.alphaValue = self.blinkState ? 1.0 : 0.3
            }
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

        // Tamanho fixo — evita usar fittingSize antes do primeiro layout SwiftUI
        // que devolve valores não fiáveis (0 ou demasiado grandes)
        let panelWidth: CGFloat  = 300
        let panelHeight: CGFloat = 280

        // 1. Obter o frame do botão em coordenadas de ecrã
        //    NSStatusBarButton.window é sempre não-nil enquanto o statusItem existe.
        //    Converter o bounds local do botão → espaço da janela → espaço do ecrã.
        let buttonScreenFrame: NSRect

        if let win = button.window {
            let inWindow = button.convert(button.bounds, to: nil)
            buttonScreenFrame = win.convertToScreen(inWindow)
        } else {
            // Fallback ultra-raro: inferir posição pelo cursor
            let mouseScreen = NSScreen.screens.first {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            } ?? NSScreen.main ?? NSScreen.screens[0]
            let sf = mouseScreen.frame
            buttonScreenFrame = NSRect(
                x: sf.maxX - panelWidth - 8,
                y: sf.maxY - 24,
                width: panelWidth,
                height: 24
            )
            vfLog("openPanel — FALLBACK screen frame: \(sf)")
        }

        vfLog("openPanel — buttonScreenFrame: \(buttonScreenFrame)")

        // 2. Calcular origem do painel: centro horizontal sobre o botão, logo abaixo
        var x = buttonScreenFrame.midX - panelWidth / 2
        let y = buttonScreenFrame.minY - panelHeight - 4   // 4 px de gap

        // 3. Manter dentro dos limites do ecrã
        let targetScreen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: buttonScreenFrame.midX, y: buttonScreenFrame.midY))
        } ?? NSScreen.main ?? NSScreen.screens[0]

        let visibleFrame = targetScreen.visibleFrame
        if x + panelWidth > visibleFrame.maxX { x = visibleFrame.maxX - panelWidth - 4 }
        if x < visibleFrame.minX             { x = visibleFrame.minX + 4 }

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: false)
        panel.orderFront(nil)
        vfLog("openPanel — final frame: \(panel.frame)")

        // 4. Fechar ao clicar fora
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
