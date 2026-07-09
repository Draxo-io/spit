import AppKit
import Carbon.HIToolbox   // cmdKey, shiftKey, optionKey, controlKey
import CoreGraphics

// MARK: - HotkeyManager
// Detecção de atalho via NSEvent monitors (local + global).
//
// SMART HOTKEY (PTT + Toggle unificado):
//   - keyDown → dispara onSmartKeyDown (sempre)
//   - keyUp   → dispara onSmartKeyUp com a duração da pressão
//   - DictationController decide: < 500ms = toggle, ≥ 500ms = PTT release
//
// Globe (🌐 / Fn) — keyCode 63 — gera .flagsChanged, não .keyDown.
// Interceptado via CGEventTap (ativo) para SUPRIMIR o evento do macOS.
// Isto elimina o som do sistema (dictation/input switch) que acompanhava o Globe key press.
// NSEvent global monitors são apenas passivos — não conseguem engolir o evento.

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
    private var regularKeyIsDown = false

    // CGEventTap for Globe key (replaces NSEvent monitors when Globe is the hotkey)
    private var globeEventTap: CFMachPort?
    private var globeRunLoopSource: CFRunLoopSource?

    /// True while the dictation hotkey is physically held down (PTT in progress).
    var isKeyHeld: Bool { globeIsDown || regularKeyIsDown }

    static var shared: HotkeyManager?

    init() {
        HotkeyManager.shared = self
    }

    // MARK: - Public accessors (read-only snapshot for UI)
    var currentKeyCode: UInt32 { smartKeyCode }
    var currentModifiers: UInt32 { smartModifiers }

    // MARK: - Registar Smart Hotkey

    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        smartKeyCode = keyCode
        smartModifiers = modifiers

        if keyCode == kGlobeKeyCode {
            registerGlobeSmart()
        } else if Self.isModifierKeyCode(keyCode) {
            registerModifierSmart()
        } else {
            registerKeySmart()
        }

        vfLog("✅ Smart hotkey registado — keyCode:\(keyCode) modifiers:\(modifiers)")
    }

    // MARK: - Tecla modificadora sozinha (ex: ⌥ Option direito, keyCode 61)
    //
    // Modificadores geram `.flagsChanged`, não `.keyDown` — daí o caminho próprio.
    // Monitor PASSIVO (não suprime): ⌥+letra continua a produzir acentos
    // normalmente; só detectamos o press/release da tecla como trigger de ditado.

    /// Modificadores suportados como hotkey (Right/Left de cada família).
    static func isModifierKeyCode(_ kc: UInt32) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62].contains(kc)
    }

    private func modifierFlag(for keyCode: UInt32) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default:     return []
        }
    }

    private func registerModifierSmart() {
        smartDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleModifierSmartEvent(event)
        }
        smartLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event -> NSEvent? in
            self?.handleModifierSmartEvent(event)
            return event   // passivo — não engolir
        }
    }

    private func handleModifierSmartEvent(_ event: NSEvent) {
        guard UInt32(event.keyCode) == smartKeyCode else { return }
        let flag = modifierFlag(for: smartKeyCode)
        let isDown = event.modifierFlags.contains(flag)
        if isDown && !regularKeyIsDown {
            regularKeyIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onSmartKeyDown?() }
        } else if !isDown && regularKeyIsDown {
            regularKeyIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onSmartKeyUp?() }
        }
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

    // MARK: - Globe Key via CGEventTap (activo — suprime o evento do sistema)

    private func registerGlobeSmart() {
        globeIsDown = false
        unregisterGlobeTap()

        // CGEventTap ativo: intercepta .flagsChanged ANTES do macOS processar o Globe.
        // Retornar nil suprime o evento — o macOS não activa dictation/input switch
        // e não toca o som do sistema. Isto elimina o "bip duplo" (sistema + Tink do Spit).
        //
        // Requer AX trust (AXIsProcessTrusted() == true), que o Spit já exige.
        let eventMask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let tapCallback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleGlobeCGEvent(proxy: proxy, type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: tapCallback,
            userInfo: selfPtr
        ) else {
            vfLog("⚠️ CGEventTap Globe falhou (AX não trustada?) — fallback para NSEvent")
            registerGlobeSmartNSEvent()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        globeEventTap = tap
        globeRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        vfLog("✅ Globe CGEventTap registado (suprime som do sistema)")
    }

    /// Chamado pelo CGEventTap callback — corre na main thread (source no main run loop).
    private func handleGlobeCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS pode desativar automaticamente o tap por timeout ou inactividade.
        // Reactivar imediatamente para evitar que o Globe key deixe de funcionar.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = globeEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                vfLog("⚠️ Globe CGEventTap desativado pelo sistema — reativado automaticamente")
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Deixar passar eventos de outras teclas (ex: Shift, Cmd, etc.)
        guard keyCode == 63 else {
            return Unmanaged.passUnretained(event)
        }

        // Globe down: .maskSecondaryFn está activo; up: não está.
        let isDown = event.flags.contains(.maskSecondaryFn)
        if isDown && !globeIsDown {
            globeIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onSmartKeyDown?() }
        } else if !isDown && globeIsDown {
            globeIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onSmartKeyUp?() }
        }

        // nil = engolir o evento — o macOS não o processa (sem som de sistema)
        return nil
    }

    /// Fallback caso o CGEventTap falhe (raro — AX não trustada).
    private func registerGlobeSmartNSEvent() {
        smartDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleGlobeSmartEvent(event)
        }
        smartLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event -> NSEvent? in
            self?.handleGlobeSmartEvent(event)
            return event
        }
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

    private func unregisterGlobeTap() {
        if let source = globeRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            globeRunLoopSource = nil
        }
        if let tap = globeEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            globeEventTap = nil
        }
    }

    @discardableResult
    private func handleSmartDown(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == smartKeyCode else { return false }
        guard !event.isARepeat else { return true }  // consume repeat, don't fire
        let mods = carbonModifiers(from: event)
        guard mods == smartModifiers else { return false }
        regularKeyIsDown = true
        DispatchQueue.main.async { [weak self] in self?.onSmartKeyDown?() }
        return true
    }

    @discardableResult
    private func handleSmartUp(_ event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == smartKeyCode else { return false }
        let mods = carbonModifiers(from: event)
        guard mods == smartModifiers else { return false }
        regularKeyIsDown = false
        DispatchQueue.main.async { [weak self] in self?.onSmartKeyUp?() }
        return true
    }

    // MARK: - Unregister Smart

    func unregister() {
        if let m = smartDownMonitor  { NSEvent.removeMonitor(m); smartDownMonitor = nil }
        if let m = smartUpMonitor    { NSEvent.removeMonitor(m); smartUpMonitor = nil }
        if let m = smartLocalMonitor { NSEvent.removeMonitor(m); smartLocalMonitor = nil }
        unregisterGlobeTap()
        globeIsDown = false
        regularKeyIsDown = false
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
