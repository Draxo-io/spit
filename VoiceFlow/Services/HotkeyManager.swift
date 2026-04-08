import AppKit
import Carbon.HIToolbox   // cmdKey, shiftKey, optionKey, controlKey

// MARK: - HotkeyManager
// Detecção de atalho via NSEvent monitors (local + global).
//
// SMART HOTKEY (PTT + Toggle unificado):
//   - keyDown → dispara onSmartKeyDown (sempre)
//   - keyUp   → dispara onSmartKeyUp com a duração da pressão
//   - DictationController decide: < 500ms = toggle, ≥ 500ms = PTT release
//
// Globe (🌐 / Fn) — keyCode 63 — gera .flagsChanged, não .keyDown.
// Tratado com monitors dedicados.

private let kGlobeKeyCode: UInt32 = 63

class HotkeyManager {

    // MARK: - Smart Dictation Hotkey (PTT + Toggle unificado)

    var onSmartKeyDown: (() -> Void)?
    var onSmartKeyUp: (() -> Void)?

    private var smartDownMonitor: Any?
    private var smartUpMonitor: Any?
    private var smartLocalMonitor: Any?
    private var smartKeyCode: UInt32 = 0
    private var smartModifiers: UInt32 = 0
    private var globeIsDown = false

    static var shared: HotkeyManager?

    init() {
        HotkeyManager.shared = self
    }

    // MARK: - Registar Smart Hotkey

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        smartKeyCode = keyCode
        smartModifiers = modifiers

        if keyCode == kGlobeKeyCode {
            registerGlobeSmart()
        } else {
            registerKeySmart()
        }

        vfLog("✅ Smart hotkey registado — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    private func registerKeySmart() {
        // Global keyDown monitor
        smartDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleSmartDown(event)
        }
        // Global keyUp monitor
        smartUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
            self?.handleSmartUp(event)
        }
        // Local monitors (quando Settings está aberta)
        smartLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            if event.type == .keyDown {
                if self.handleSmartDown(event) { return nil }
            } else if event.type == .keyUp {
                self.handleSmartUp(event)
                return nil
            }
            return event
        }
    }

    private func registerGlobeSmart() {
        globeIsDown = false
        let combined = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleGlobeSmartEvent(event)
        }
        smartDownMonitor = combined
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event -> NSEvent? in
            self?.handleGlobeSmartEvent(event)
            return event
        }
        smartLocalMonitor = local
    }

    private func handleGlobeSmartEvent(_ event: NSEvent) {
        guard event.keyCode == kGlobeKeyCode else { return }
        let isDown = event.modifierFlags.contains(.function)
        if isDown && !globeIsDown {
            globeIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onSmartKeyDown?() }
        } else if !isDown && globeIsDown {
            globeIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onSmartKeyUp?() }
        }
    }

    @discardableResult
    private func handleSmartDown(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == smartKeyCode else { return false }
        guard !event.isARepeat else { return true }  // consume repeat, don't fire
        let mods = carbonModifiers(from: event)
        guard mods == smartModifiers else { return false }
        DispatchQueue.main.async { [weak self] in self?.onSmartKeyDown?() }
        return true
    }

    @discardableResult
    private func handleSmartUp(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == smartKeyCode else { return false }
        let mods = carbonModifiers(from: event)
        guard mods == smartModifiers else { return false }
        DispatchQueue.main.async { [weak self] in self?.onSmartKeyUp?() }
        return true
    }

    // MARK: - Unregister Smart

    func unregister() {
        if let m = smartDownMonitor  { NSEvent.removeMonitor(m); smartDownMonitor = nil }
        if let m = smartUpMonitor    { NSEvent.removeMonitor(m); smartUpMonitor = nil }
        if let m = smartLocalMonitor { NSEvent.removeMonitor(m); smartLocalMonitor = nil }
        globeIsDown = false
        onSmartKeyDown = nil
        onSmartKeyUp = nil
        vfLog("Smart hotkey desregistado")
    }

    // MARK: - Read Selection (TTS) Hotkey

    var onTTSPressed: (() -> Void)?
    private var ttsGlobalMonitor: Any?
    private var ttsLocalMonitor: Any?
    private var ttsKeyCode: UInt32 = 0
    private var ttsModifiers: UInt32 = 0

    func registerTTS(keyCode: UInt32, modifiers: UInt32) {
        unregisterTTS()
        ttsKeyCode = keyCode
        ttsModifiers = modifiers

        ttsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleTTSEvent(event)
        }
        ttsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event -> NSEvent? in
            guard let self else { return event }
            if self.handleTTSEvent(event) { return nil }
            return event
        }
        vfLog("TTS hotkey registado — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    @discardableResult
    private func handleTTSEvent(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == ttsKeyCode else { return false }
        guard !event.isARepeat else { return false }
        let mods = carbonModifiers(from: event)
        guard mods == ttsModifiers else { return false }
        DispatchQueue.main.async { [weak self] in self?.onTTSPressed?() }
        return true
    }

    func unregisterTTS() {
        if let m = ttsGlobalMonitor { NSEvent.removeMonitor(m); ttsGlobalMonitor = nil }
        if let m = ttsLocalMonitor  { NSEvent.removeMonitor(m); ttsLocalMonitor  = nil }
        onTTSPressed = nil
        vfLog("TTS hotkey desregistado")
    }

    deinit {
        unregister()
        unregisterTTS()
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
