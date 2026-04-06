import AppKit
import Carbon.HIToolbox   // cmdKey, shiftKey, optionKey, controlKey

// MARK: - HotkeyManager
// Detecção de atalho via NSEvent monitors (local + global).
// Substituímos Carbon RegisterEventHotKey que em macOS 14/15 com sandbox
// falha silenciosamente ao re-registar após mudança de atalho.
//
// Global monitor → dispara quando outra app está em primeiro plano
// Local monitor  → dispara quando Spit está em primeiro plano (janela Settings aberta)
// PTT usa NSEvent.addGlobalMonitorForEvents para keyDown + keyUp.
//
// Globe (🌐 / Fn) — keyCode 63 — gera .flagsChanged, não .keyDown.
// Tratado com monitors dedicados tanto em toggle como em PTT.

private let kGlobeKeyCode: UInt32 = 63

class HotkeyManager {

    // Toggle hotkey
    private var toggleGlobalMonitor: Any?
    private var toggleLocalMonitor: Any?
    private var registeredKeyCode: UInt32 = 0
    private var registeredModifiers: UInt32 = 0
    private var globeWasDown = false          // evita disparo repetido enquanto Globe está pressionada
    var onHotkeyPressed: (() -> Void)?

    // Push-to-talk
    var onPTTKeyDown: (() -> Void)?
    var onPTTKeyUp: (() -> Void)?
    private var pttMonitor: Any?
    private var pttKeyCode: UInt32 = 0
    private var pttModifiers: UInt32 = 0
    private var pttGlobeDown = false

    static var shared: HotkeyManager?

    init() {
        HotkeyManager.shared = self
    }

    // MARK: - Registar Toggle Hotkey

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        registeredKeyCode = keyCode
        registeredModifiers = modifiers

        if keyCode == kGlobeKeyCode {
            registerGlobeToggle()
        } else {
            registerKeyDownToggle()
        }

        vfLog("✅ Hotkey registado — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    // Toggle via .keyDown (teclas normais)
    private func registerKeyDownToggle() {
        toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleToggleEvent(event)
        }
        toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            if self.handleToggleEvent(event) { return nil }
            return event
        }
    }

    // Toggle via .flagsChanged (Globe / Fn key)
    private func registerGlobeToggle() {
        globeWasDown = false

        toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleGlobeToggleEvent(event)
        }
        toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event -> NSEvent? in
            self?.handleGlobeToggleEvent(event)
            return event   // não consumir — macOS precisa do evento para o próprio Globe menu
        }
    }

    private func handleGlobeToggleEvent(_ event: NSEvent) {
        guard event.keyCode == kGlobeKeyCode else { return }
        let isDown = event.modifierFlags.contains(.function)
        if isDown && !globeWasDown {
            globeWasDown = true
            DispatchQueue.main.async { [weak self] in self?.onHotkeyPressed?() }
        } else if !isDown {
            globeWasDown = false
        }
    }

    /// Verifica se o evento corresponde ao atalho registado. Devolve true se disparou.
    @discardableResult
    private func handleToggleEvent(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == registeredKeyCode else { return false }
        guard !event.isARepeat else { return false }
        let mods = carbonModifiers(from: event)
        guard mods == registeredModifiers else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.onHotkeyPressed?()
        }
        return true
    }

    // MARK: - Unregister Toggle

    func unregister() {
        if let m = toggleGlobalMonitor { NSEvent.removeMonitor(m); toggleGlobalMonitor = nil }
        if let m = toggleLocalMonitor  { NSEvent.removeMonitor(m); toggleLocalMonitor  = nil }
        globeWasDown = false
        vfLog("Toggle hotkey desregistado")
    }

    // MARK: - Push-to-Talk

    func registerPTT(keyCode: UInt32, modifiers: UInt32) {
        unregisterPTT()
        pttKeyCode = keyCode
        pttModifiers = modifiers

        if keyCode == kGlobeKeyCode {
            registerGlobePTT()
        } else {
            registerKeyDownPTT()
        }

        vfLog("PTT registado — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    // PTT via .keyDown/.keyUp (teclas normais)
    private func registerKeyDownPTT() {
        pttMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return }
            guard UInt32(event.keyCode) == self.pttKeyCode else { return }

            if self.pttModifiers != 0 {
                guard self.carbonModifiers(from: event) == self.pttModifiers else { return }
            }

            if event.type == .keyDown && !event.isARepeat {
                DispatchQueue.main.async { self.onPTTKeyDown?() }
            } else if event.type == .keyUp {
                DispatchQueue.main.async { self.onPTTKeyUp?() }
            }
        }
    }

    // PTT via .flagsChanged (Globe / Fn key)
    private func registerGlobePTT() {
        pttGlobeDown = false

        pttMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self, event.keyCode == kGlobeKeyCode else { return }
            let isDown = event.modifierFlags.contains(.function)
            if isDown && !self.pttGlobeDown {
                self.pttGlobeDown = true
                DispatchQueue.main.async { self.onPTTKeyDown?() }
            } else if !isDown && self.pttGlobeDown {
                self.pttGlobeDown = false
                DispatchQueue.main.async { self.onPTTKeyUp?() }
            }
        }
    }

    func unregisterPTT() {
        if let monitor = pttMonitor {
            NSEvent.removeMonitor(monitor)
            pttMonitor = nil
            vfLog("PTT desregistado")
        }
        pttGlobeDown = false
        onPTTKeyDown = nil
        onPTTKeyUp = nil
    }

    deinit {
        unregister()
        unregisterPTT()
    }

    // MARK: - Helpers

    private func carbonModifiers(from event: NSEvent) -> UInt32 {
        var c: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.control) { c |= UInt32(controlKey) }
        return c
    }
}
