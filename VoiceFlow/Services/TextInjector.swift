import AppKit
import ApplicationServices

// MARK: - TextInjector
// Injecta texto no campo com foco.
// Estratégia:
// 1. AX injection (se Accessibility disponível)
// 2. Clipboard + ⌘V via osascript (funciona sem Accessibility na app)
// 3. Clipboard + CGEvent ⌘V (requer Accessibility)
// 4. Último recurso: texto fica no clipboard

enum InjectionResult {
    case injected           // Texto injectado directamente via AX
    case pastedAndRestored  // Texto colado via ⌘V, clipboard original restaurado
    case copiedToClipboard  // Último recurso — texto no clipboard (não conseguiu colar)
    case failed(String)     // Falha inesperada
}

class TextInjector {

    private let focusDetector = FocusDetector()

    // MARK: - Injectar Texto

    func inject(text: String) -> InjectionResult {
        guard !text.isEmpty else { return .failed("Empty text") }

        let axTrusted = AXIsProcessTrusted()
        vfLog("inject() — \(text.count) chars, AXTrusted: \(axTrusted)")

        guard axTrusted else {
            // No accessibility permission — text to clipboard, user must ⌘V manually
            vfLog("AX not trusted — clipboard only")
            return pasteViaClipboard(text: text, axTrusted: false, certainPaste: false)
        }

        // AX is trusted — try direct injection first, then always fall back to ⌘V.
        // We do NOT gate the ⌘V on getFocusedElement() because:
        //   - Web-based text fields (Chrome, Safari) often fail AX element inspection
        //   - If there's no focused field, ⌘V simply does nothing (safe)
        //   - Showing a false "no focus" warning is worse than silently sending ⌘V

        if let element = focusDetector.getFocusedElement() {
            vfLog("Focused element found — trying direct AX inject")
            if tryAxInject(text: text, into: element) {
                vfLog("✅ AX inject succeeded")
                return .injected
            }
            vfLog("Direct AX inject failed — falling back to ⌘V")
        } else {
            vfLog("No focused element via AX (possibly web field) — attempting ⌘V anyway")
        }

        // Always attempt ⌘V when AX is trusted — certainPaste:true = no warning shown
        return pasteViaClipboard(text: text, axTrusted: true, certainPaste: true)
    }

    // MARK: - Injecção via AXUIElement

    private func tryAxInject(text: String, into element: AXUIElement) -> Bool {
        // Método A: kAXSelectedTextAttribute (insere na posição do cursor / substitui selecção)
        var selectedRangeRef: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )

        if rangeResult == .success {
            let setResult = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFString
            )
            if setResult == .success {
                vfLog("AX inject via kAXSelectedTextAttribute OK")
                return true
            }
            vfLog("AX kAXSelectedTextAttribute falhou: \(setResult.rawValue)")
        }

        // Método B: AXInsertedText (algumas apps suportam)
        let insertResult = AXUIElementSetAttributeValue(
            element,
            "AXInsertedText" as CFString,
            text as CFString
        )
        if insertResult == .success {
            vfLog("AX inject via AXInsertedText OK")
            return true
        }

        // Método C: Append ao valor existente (último recurso AX)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settable.boolValue {
            var currentValueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValueRef)
            let currentText = (currentValueRef as? String) ?? ""
            let newValue = currentText + text
            let result = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                newValue as CFString
            )
            if result == .success {
                vfLog("AX inject via kAXValueAttribute append OK")
                return true
            }
        }

        return false
    }

    // MARK: - Colar via Clipboard Temporário + ⌘V

    /// - certainPaste: true = we know there's a focused field, ⌘V will land correctly
    ///                false = no focused field detected, ⌘V result is uncertain → show warning
    private func pasteViaClipboard(text: String, axTrusted: Bool, certainPaste: Bool) -> InjectionResult {
        let pasteboard = NSPasteboard.general

        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetPID = frontApp?.processIdentifier
        vfLog("Target: \(frontApp?.localizedName ?? "?") PID:\(targetPID ?? -1) ax:\(axTrusted) certain:\(certainPaste)")

        // Always save + put text in clipboard
        let savedItems = saveClipboard(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if axTrusted {
            // Send ⌘V to frontmost app
            simulatePaste(targetPID: targetPID)
            vfLog("⌘V sent via postToPid(\(targetPID ?? -1))")

            if certainPaste {
                // Focused field confirmed — restore clipboard, no warning
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.restoreClipboard(pasteboard, items: savedItems)
                    vfLog("Clipboard restored")
                }
                return .pastedAndRestored
            } else {
                // No focused field — ⌘V attempted but uncertain
                // Leave text in clipboard + show warning so user can ⌘V manually if needed
                // Restore clipboard after longer delay (user may still paste)
                DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                    self.restoreClipboard(pasteboard, items: savedItems)
                    vfLog("Clipboard restored (delayed — no focus case)")
                }
                return .copiedToClipboard
            }
        } else {
            // AX not trusted — text in clipboard, user must paste manually
            vfLog("AX not trusted — clipboard only, user must ⌘V")
            return .copiedToClipboard
        }
    }

    // MARK: - Simulate ⌘V

    @discardableResult
    private func simulatePaste(targetPID: pid_t?) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            vfLog("Failed to create CGEvent for ⌘V")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        if let pid = targetPID, pid > 0 {
            // Send directly to the target process — most reliable
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
            vfLog("⌘V sent via postToPid(\(pid))")
        } else {
            // Fallback: broadcast to HID event tap
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            vfLog("⌘V sent via HID event tap (no PID)")
        }

        return true
    }

    // MARK: - Salvar / Restaurar Clipboard

    private struct ClipboardItem {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private func saveClipboard(_ pasteboard: NSPasteboard) -> [ClipboardItem] {
        var items: [ClipboardItem] = []

        guard let types = pasteboard.types else { return items }

        for type in types {
            if let data = pasteboard.data(forType: type) {
                items.append(ClipboardItem(type: type, data: data))
            }
        }

        return items
    }

    private func restoreClipboard(_ pasteboard: NSPasteboard, items: [ClipboardItem]) {
        guard !items.isEmpty else { return }

        pasteboard.clearContents()
        for item in items {
            pasteboard.setData(item.data, forType: item.type)
        }
    }

    // MARK: - Notificação Visual

    func showClipboardNotification() {
        let notification = NSUserNotification()
        notification.title = "Spit"
        notification.informativeText = "Texto copiado. Prima ⌘V para colar."
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }
}
