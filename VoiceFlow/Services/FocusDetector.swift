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
}
