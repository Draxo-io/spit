import AppKit

// MARK: - HotkeyManager
// Detecção de atalho via NSEvent monitors (local + global).
// Substituímos Carbon RegisterEventHotKey que em macOS 14/15 com sandbox
// falha silenciosamente ao re-registar após mudança de atalho.
//
// Global monitor → dispara quando outra app está em primeiro plano
// Local monitor  → dispara quando Spit está em primeiro plano (janela Settings aberta)
// PTT usa NSEvent.addGlobalMonitorForEvents para keyDown + keyUp.

class HotkeyManager {

    // Toggle hotkey
    private var toggleGlobalMonitor: Any?
    private var toggleLocalMonitor: Any?
    private var registeredKeyCode: UInt32 = 0
    private var registeredModifiers: UInt32 = 0
    var onHotkeyPressed: (() -> Void)?

    // Push-to-talk
    var onPTTKeyDown: (() -> Void)?
    var onPTTKeyUp: (() -> Void)?
    private var pttMonitor: Any?
    private var pttKeyCode: UInt32 = 0
    private var pttModifiers: UInt32 = 0

    static var shared: HotkeyManager?

    init() {
        HotkeyManager.shared = self
    }

    // MARK: - Registar Toggle Hotkey

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        registeredKeyCode = keyCode
        registeredModifiers = modifiers

        // Global: captura quando outras apps estão em primeiro plano
        // Requer Accessibility (já pedida pela app para text injection)
        toggleGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleToggleEvent(event)
        }

        // Local: captura quando Spit está em primeiro plano (Settings aberto)
        toggleLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            // Não interceptar durante gravação de atalho na SettingsView
            if self.handleToggleEvent(event) {
                return nil  // consumir evento
            }
            return event
        }

        vfLog("✅ Hotkey registado (NSEvent) — keyCode:\(keyCode) modifiers:\(modifiers)")
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
        vfLog("Toggle hotkey desregistado")
    }

    // MARK: - Push-to-Talk

    func registerPTT(keyCode: UInt32, modifiers: UInt32) {
        unregisterPTT()
        pttKeyCode = keyCode
        pttModifiers = modifiers

        pttMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return }
            let eventKeyCode = UInt32(event.keyCode)
            guard eventKeyCode == self.pttKeyCode else { return }

            if self.pttModifiers != 0 {
                let eventMods = self.carbonModifiers(from: event)
                guard eventMods == self.pttModifiers else { return }
            }

            if event.type == .keyDown && !event.isARepeat {
                DispatchQueue.main.async { self.onPTTKeyDown?() }
            } else if event.type == .keyUp {
                DispatchQueue.main.async { self.onPTTKeyUp?() }
            }
        }
        vfLog("PTT registado — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    func unregisterPTT() {
        if let monitor = pttMonitor {
            NSEvent.removeMonitor(monitor)
            pttMonitor = nil
            vfLog("PTT desregistado")
        }
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
