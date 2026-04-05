import Carbon
import AppKit

// MARK: - HotkeyManager
// Carbon RegisterEventHotKey — funciona sem permissões especiais.
// Requer event loop AppKit (NSApplication.run) — que main.swift garante.
// PTT usa NSEvent.addGlobalMonitorForEvents para capturar keyDown + keyUp.

class HotkeyManager {

    // Toggle hotkey (Carbon)
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    var onHotkeyPressed: (() -> Void)?

    // Push-to-talk
    var onPTTKeyDown: (() -> Void)?
    var onPTTKeyUp: (() -> Void)?
    private var pttMonitor: Any?
    private var pttKeyCode: UInt32 = 0
    private var pttModifiers: UInt32 = 0

    static var shared: HotkeyManager?  // Não é weak — precisa de sobreviver

    init() {
        HotkeyManager.shared = self
    }

    // MARK: - Registar Hotkey

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()

        // 1. Instalar event handler para HotKeyPressed
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            vfLog("ERRO InstallEventHandler: \(status)")
            return
        }
        vfLog("InstallEventHandler OK")

        // 2. Registar a combinação de teclas
        var hotKeyID = EventHotKeyID(
            signature: OSType(0x5646_4C4F), // "VFLO"
            id: 1
        )

        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if regStatus != noErr {
            vfLog("ERRO RegisterEventHotKey: \(regStatus)")
        } else {
            vfLog("✅ Hotkey registado — keyCode:\(keyCode) modifiers:\(modifiers)")
        }
    }

    func registerGlobeKey() {
        register(keyCode: 2, modifiers: UInt32(cmdKey | shiftKey))
    }

    // MARK: - Push-to-Talk

    func registerPTT(keyCode: UInt32, modifiers: UInt32) {
        unregisterPTT()
        pttKeyCode = keyCode
        pttModifiers = modifiers

        pttMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            guard let self = self else { return }
            let eventKeyCode = UInt32(event.keyCode)
            guard eventKeyCode == self.pttKeyCode else { return }

            // Verificar modificadores (0 = qualquer combinação aceite)
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

    // MARK: - Unregister Toggle

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            NSLog("[HotkeyManager] Hotkey desregistado")
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
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

// MARK: - Carbon Callback (top-level C function)

private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    vfLog("🔥 Hotkey recebido!")
    DispatchQueue.main.async {
        HotkeyManager.shared?.onHotkeyPressed?()
    }
    return noErr
}
