import AppKit
import ApplicationServices
import UserNotifications

// MARK: - TextInjector
// Injecta texto no campo com foco.
//
// Estratégia (por ordem de preferência):
//
// 1. AX kAXSelectedTextAttribute — direto, sem clipboard (apps nativas: TextEdit, Pages, Xcode…)
//    Usa o elemento capturado em stopDictation(), antes de qualquer operação async.
//    Se kAXSelectedTextRange está disponível, usamos AX e NÃO fazemos fallback
//    (evita duplicação por AX com latência + keyboard events).
//
// 2. CGEvent Unicode keyboard — sem clipboard (browsers, Electron, qualquer app sem AX).
//    Antes de enviar: ativa o app-alvo capturado em stopDictation() para garantir
//    que os eventos chegam ao destino certo mesmo após 3-5s de processamento async.
//
// 3. Clipboard (read-only) — só quando AX não está autorizado.
//    NUNCA auto-cola. O utilizador usa ⌘V manualmente.

enum InjectionResult {
    case injectedViaAX             // AX kAXSelectedTextAttribute
    case injectedViaKeyboard       // CGEvent Unicode keyboard events
    case injectedViaClipboardPaste // Clipboard + ⌘V forçado (apps onde AX dá falso-positivo)
    case copiedToClipboard         // AX não autorizado — clipboard manual
    case failed(String)
}

class TextInjector {

    private let focusDetector = FocusDetector()

    // Apps onde `kAXSelectedTextAttribute` retorna .success mas o texto NÃO aparece
    // (Electron/Catalyst/Web wrappers que aceitam a chamada AX silenciosamente).
    // Para estes saltamos o AX e vamos directos a clipboard+⌘V.
    private static let axUnreliableBundleIDs: Set<String> = [
        "net.whatsapp.WhatsApp",           // WhatsApp (Catalyst)
        "desktop.WhatsApp",                // WhatsApp (alt distribution)
        "com.tinyspeck.slackmacgap",       // Slack
        "com.hnc.Discord",                 // Discord
        "com.microsoft.teams",             // Microsoft Teams (legacy)
        "com.microsoft.teams2",            // Microsoft Teams (new)
        "ru.keepcoder.Telegram",           // Telegram (Mac App Store)
        "org.telegram.desktop",            // Telegram (Desktop)
        "com.openai.chat",                 // ChatGPT desktop
        "com.anthropic.claudefordesktop",  // Claude desktop
        "notion.id",                       // Notion
        "md.obsidian",                     // Obsidian
        "us.zoom.xos",                     // Zoom
        "com.spotify.client",              // Spotify
        "com.todesktop.230313mzl4w4u92"    // Cursor
    ]

    private func isAXUnreliable(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return Self.axUnreliableBundleIDs.contains(id)
    }

    // MARK: - Espaçamento automático

    /// Lê o caractere imediatamente antes do cursor no elemento AX.
    /// Funciona mesmo em apps onde a *escrita* via AX não é fiável —
    /// muitas apps Electron/Catalyst expõem a leitura mesmo que não a escrita.
    private func charBeforeCursor(in element: AXUIElement) -> Character? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeVal = rangeRef else { return nil }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &cfRange),
              cfRange.location > 0 else { return nil }

        var lookback = CFRange(location: cfRange.location - 1, length: 1)
        guard let axRangeVal = AXValueCreate(.cfRange, &lookback) else { return nil }

        var charRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRangeVal,
            &charRef
        ) == .success, let str = charRef as? String, let char = str.first else { return nil }

        return char
    }

    /// Retorna `text` com um espaço inicial se o cursor estiver logo após
    /// conteúdo não-whitespace. Evita que dois ditados consecutivos fiquem colados.
    private func addLeadingSpaceIfNeeded(_ text: String, element: AXUIElement?) -> String {
        // Não tocar se o texto já começa com whitespace
        guard let first = text.first, !first.isWhitespace else { return text }
        guard let element else { return text }

        if let prev = charBeforeCursor(in: element), !prev.isWhitespace {
            vfLog("inject() — espaço automático inserido (prev char: '\(prev)')")
            return " " + text
        }
        return text
    }

    // MARK: - Injectar Texto

    /// - Parameters:
    ///   - text: Texto a injectar (já traduzido se aplicável).
    ///   - precapturedElement: Elemento AX capturado em stopDictation(), antes do processamento async.
    ///   - targetApp: App frontmost capturado em stopDictation().
    func inject(
        text: String,
        precapturedElement: AXUIElement? = nil,
        targetApp: NSRunningApplication? = nil
    ) -> InjectionResult {
        guard !text.isEmpty else { return .failed("Empty text") }

        let axTrusted = AXIsProcessTrusted()

        // Usar o elemento pré-capturado se disponível; caso contrário tentar obter o atual.
        // O pré-capturado reflete o foco no momento em que o utilizador parou de gravar —
        // muito mais fiável do que o foco atual (que pode ter mudado durante transcrição+tradução).
        let focusedElement: AXUIElement?
        if let captured = precapturedElement {
            focusedElement = captured
            vfLog("inject() — usando elemento pré-capturado")
        } else {
            focusedElement = axTrusted ? focusDetector.getFocusedElement() : nil
            vfLog("inject() — usando elemento atual (sem captura prévia)")
        }

        let axUnreliable = isAXUnreliable(targetApp)

        // Espaçamento automático: se o cursor está logo após texto sem espaço,
        // prepend um espaço para que dois ditados consecutivos não fiquem colados.
        // A leitura AX é tentada mesmo em apps axUnreliable (muitas lêem mas não escrevem).
        let text = addLeadingSpaceIfNeeded(text, element: focusedElement)

        vfLog("inject() — \(text.count) chars, AXTrusted: \(axTrusted), element: \(focusedElement != nil), targetApp: \(targetApp?.localizedName ?? "?"), axUnreliable: \(axUnreliable)")

        // ── Método 1: AX direct inject (saltado em apps onde AX é falso-positivo) ───
        if !axUnreliable, let element = focusedElement {
            var selectedRangeRef: CFTypeRef?
            let rangeResult = AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                &selectedRangeRef
            )

            if rangeResult == .success {
                vfLog("inject() AX path — text:\(text.count) chars: \(text.prefix(80))")
                let setResult = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    text as CFString
                )
                if setResult == .success {
                    vfLog("✅ AX inject via kAXSelectedTextAttribute OK")
                } else {
                    // AX reportou erro mas pode ter inserido com latência.
                    // NÃO fazemos fallback — evita duplicação (AX tardio + keyboard).
                    vfLog("⚠️ AX set retornou \(setResult.rawValue) — sem fallback (previne duplicação)")
                }
                return .injectedViaAX
            }
            vfLog("kAXSelectedTextRange indisponível (\(rangeResult.rawValue)) — campo não editável via AX, usando keyboard")
        }

        // ── Método 2: Clipboard + Cmd+V ou CGEvent Unicode keyboard ─────────────
        // Quando não há elemento AX (Electron, VS Code, Discord, Claude Desktop…):
        //   → Clipboard + Cmd+V é universalmente fiável. O Electron trata Cmd+V via
        //     sistema de comandos do app, não pelo renderer Chromium — funciona mesmo
        //     quando o campo de texto não processa CGEvent Unicode directamente.
        // Quando há elemento AX mas não era editável (range falhou):
        //   → Fallback para CGEvent Unicode (apps nativos que rejeitaram AX).
        if axTrusted {
            if let target = targetApp, !target.isActive {
                vfLog("⌨ Ativando app-alvo '\(target.localizedName ?? "?")' antes de injecção")
                target.activate(options: [])
                Thread.sleep(forTimeInterval: 0.08)
            } else {
                vfLog("⌨ App-alvo '\(targetApp?.localizedName ?? "?")' já está ativo")
            }

            if focusedElement == nil || axUnreliable {
                // Sem elemento AX OU app blacklisted → Clipboard + Cmd+V
                let reason = axUnreliable ? "ax-unreliable" : "no-ax-element"
                vfLog("inject() clipboard+V path (\(reason)) — text:\(text.count) chars: \(text.prefix(80))")
                let prevString = NSPasteboard.general.string(forType: .string)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)

                let src = CGEventSource(stateID: .combinedSessionState)
                if let dn = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
                   let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) {
                    dn.flags = .maskCommand
                    up.flags = .maskCommand
                    dn.post(tap: .cgSessionEventTap)
                    up.post(tap: .cgSessionEventTap)
                }

                // Restaurar clipboard anterior após o paste completar.
                // Apps Electron/Catalyst (axUnreliable) recebem um delay ligeiramente
                // maior (0.6s) para garantir que o Cmd+V é processado antes do restore.
                // Em caso raro de paste engolido silenciosamente (modal/overlay), o
                // utilizador perde o texto no clipboard — mas isso é muito preferível
                // a destruir o clipboard em cada ditado bem-sucedido. Fix: 2026-04-30.
                let restoreDelay: Double = axUnreliable ? 0.6 : 0.4
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    NSPasteboard.general.clearContents()
                    if let prev = prevString {
                        NSPasteboard.general.setString(prev, forType: .string)
                    }
                }
                return axUnreliable ? .injectedViaClipboardPaste : .injectedViaKeyboard

            } else {
                // Tem elemento AX mas não era editável → CGEvent Unicode keyboard
                vfLog("inject() keyboard path — text:\(text.count) chars: \(text.prefix(80))")
                typeViaKeyboardEvents(text: text)
                return .injectedViaKeyboard
            }
        }

        // ── Método 3: Clipboard manual (AX não autorizado) ───────────────────
        vfLog("⚠️ AX not trusted — clipboard only, user must ⌘V")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return .copiedToClipboard
    }

    // MARK: - Injecção via CGEvent Unicode (sem clipboard)

    private func typeViaKeyboardEvents(text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0

        while index < utf16.count {
            let end = min(index + chunkSize, utf16.count)
            var chunk = Array(utf16[index..<end])

            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                keyDown.post(tap: .cgSessionEventTap)
            }
            // keyUp intentionally has NO unicode string — text is inserted on keyDown only.
            // Setting unicode on keyUp causes Electron/browser apps to insert the text twice.
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.post(tap: .cgSessionEventTap)
            }
            index = end
        }
    }

    // MARK: - Notificação Visual

    func showClipboardNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = "Spit"
        content.body  = "Texto copiado. Prima ⌘V para colar."

        let request = UNNotificationRequest(
            identifier: "spit.clipboard",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { vfLog("UNNotification error: \(error)") }
        }
    }
}
