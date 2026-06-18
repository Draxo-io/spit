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
    private var modelLoadingCancellable: AnyCancellable?
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
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Spit")
            img?.isTemplate = true          // adapta automaticamente a dark/light mode
            button.image = img
            button.imageScaling = .scaleNone
            button.sendAction(on: .leftMouseDown)   // dispara no press, não no release — área efectiva = quadrado inteiro
            button.action = #selector(statusItemClicked(_:))
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
        observeModelLoading()
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

    // MARK: - Observar carregamento do modelo local

    private func observeModelLoading() {
        modelLoadingCancellable = LocalWhisperService.shared.$isLoading
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLoading in
                guard let self else { return }
                // Only show loading indicator if in idle state (don't override recording icon)
                if case .idle = self.dictationController.state {
                    if isLoading {
                        self.startModelLoadingAnimation()
                    } else {
                        self.stopModelLoadingAnimation()
                    }
                }
            }
    }

    private var modelLoadTimer: Timer?
    private var modelLoadFrame = 0
    private let modelLoadFrames = ["waveform", "waveform.badge.clock", "waveform", "waveform.badge.clock"]

    private func startModelLoadingAnimation() {
        guard modelLoadTimer == nil else { return }
        modelLoadFrame = 0
        modelLoadTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.modelLoadFrame = (self.modelLoadFrame + 1) % self.modelLoadFrames.count
                button.image = NSImage(systemSymbolName: self.modelLoadFrames[self.modelLoadFrame],
                                       accessibilityDescription: "Loading model…")
            }
        }
        // Also set tooltip
        statusItem.button?.toolTip = String(localized: "Loading local AI model…")
    }

    private func stopModelLoadingAnimation() {
        modelLoadTimer?.invalidate()
        modelLoadTimer = nil
        // Restore normal icon
        updateIcon(for: dictationController.state)
        statusItem.button?.toolTip = nil
    }

    /// Chamado após autenticação por magic link: abre o popover e pisca verde brevemente.
    func showAuthSuccess() {
        guard let button = statusItem.button else { return }

        // Flash verde no ícone durante 2s
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Autenticado")
        button.contentTintColor = NSColor.systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            button.contentTintColor = nil
            self.updateIcon(for: self.dictationController.state)
        }

        // Abrir o popover para mostrar o estado da conta
        if !panel.isVisible {
            openPanel()
        }
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

    // MARK: - Menu bar click handlers

    /// Left click: toggle the popover panel.
    @objc func statusItemClicked(_ sender: AnyObject?) {
        vfLog("statusItemClicked — isVisible: \(panel.isVisible)")
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

        // Rebuild content each time so SwiftUI re-reads @Published state (lastResult, etc.)
        // that may have changed while the panel was hidden.
        rebuildContent()

        // Width fixed; height accommodates two blocks (Digitação + Leitura) with lastResult row.
        let panelWidth: CGFloat  = 300
        let panelHeight: CGFloat = 420

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

        // 4. Fechar ao clicar fora — instala monitor apenas no próximo ciclo do event loop
        //    (evita que o próprio clique que abriu o painel o feche imediatamente)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                self?.closePanel()
            }
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
