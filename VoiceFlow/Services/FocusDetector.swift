import AppKit
import ApplicationServices

// MARK: - FocusDetector
// Verifica se existe um campo de texto editável com foco antes de iniciar gravação.
// Usa AXUIElement (Accessibility API).

enum FocusStatus {
    case textFieldActive     // Campo de texto activo e editável — pode injectar
    case noTextFieldActive   // Sem campo de texto — usar clipboard
    case accessibilityDenied // Sem permissão de Accessibility
}

class FocusDetector {

    // MARK: - Verificar Estado do Foco

    func checkFocusStatus() -> FocusStatus {
        // Verificar permissão de Accessibility
        guard AXIsProcessTrusted() else {
            return .accessibilityDenied
        }

        // Obter elemento em foco no sistema
        guard let focusedElement = getFocusedElement() else {
            return .noTextFieldActive
        }

        // Verificar se é um campo de texto editável
        if isEditableTextField(focusedElement) {
            return .textFieldActive
        }

        return .noTextFieldActive
    }

    // MARK: - Elemento em Foco

    func getFocusedElement() -> AXUIElement? {
        // Obter a app frontmost
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        // Obter o elemento em foco
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement,
                                                    kAXFocusedUIElementAttribute as CFString,
                                                    &focusedElement)
        guard result == .success, let element = focusedElement else { return nil }
        return (element as! AXUIElement)
    }

    // MARK: - Verificar se é Campo Editável

    private func isEditableTextField(_ element: AXUIElement) -> Bool {
        // Verificar role
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        let editableRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
            "AXTextField",
            "AXTextArea",
            "AXSearchField"
        ]

        guard editableRoles.contains(role) else { return false }

        // Verificar se o atributo de valor é settable (editável)
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    // MARK: - Obter Texto Actual do Campo

    func getCurrentFieldText() -> String? {
        guard let element = getFocusedElement() else { return nil }
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        return valueRef as? String
    }

    // MARK: - Focused Window Check

    /// Returns true if the given app likely has a window that can receive keyboard input.
    /// Uses three checks in order — stops as soon as one succeeds:
    ///   1. kAXFocusedWindowAttribute  — works for most native macOS apps and browsers
    ///   2. kAXMainWindowAttribute     — fallback for apps that track main but not focused window
    ///   3. Electron framework check   — Claude Desktop, VS Code, Slack, Notion, etc. don't expose
    ///      proper AX window attributes but DO receive Cmd+V; detect them via their bundle on disk
    func hasFocusedWindow(for app: NSRunningApplication?) -> Bool {
        guard let app = app else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // 1. Focused window
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           focusedRef != nil {
            vfLog("hasFocusedWindow: YES via kAXFocusedWindowAttribute (\(app.localizedName ?? "?"))")
            return true
        }

        // 2. Main window
        var mainRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainRef) == .success,
           mainRef != nil {
            vfLog("hasFocusedWindow: YES via kAXMainWindowAttribute (\(app.localizedName ?? "?"))")
            return true
        }

        // 3. Electron framework detection — apps built with Electron don't expose AX window
        //    attributes but always have a focused content area that accepts Cmd+V.
        if let bundleURL = app.bundleURL {
            let electronPath = bundleURL
                .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
                .path
            if FileManager.default.fileExists(atPath: electronPath) {
                vfLog("hasFocusedWindow: YES via Electron detection (\(app.localizedName ?? "?"))")
                return true
            }
        }

        vfLog("hasFocusedWindow: NO — all checks failed (\(app.localizedName ?? "?")), likely no field")
        return false
    }
}
