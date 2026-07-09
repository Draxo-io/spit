---
paths:
  - VoiceFlow/Services/HotkeyManager.swift
  - VoiceFlow/Services/TextInjector.swift
  - VoiceFlow/Services/FocusDetector.swift
---

# Hotkey global e injecção de texto — regras duras

## Hotkey Globe (🌐, keyCode 63)

- Globe dispara `.flagsChanged`, **não** `.keyDown`.

- **Tem de ser interceptado via `CGEventTap` ativo** com `return nil` para
  suprimir o evento. Sem isto, o macOS activa dictation/input switch e toca
  o som do sistema — causa "bip duplo" com o Tink do Spit.

- CGEventTap requer **AX trust** (`AXIsProcessTrusted() == true`). Fallback
  para `NSEvent` monitors (passivos) quando AX não está trustada — nesse caso
  o bip do sistema é inevitável. Aceitar como mal menor.

- Para teclas **não-Globe**, usar `NSEvent.addGlobalMonitorForEvents` é
  suficiente. CGEventTap só é necessário para Globe.

## Smart Hotkey (PTT + Toggle unificados)

- `onSmartKeyDown` dispara **sempre** no keyDown.

- `onSmartKeyUp` recebe a duração da pressão. Limiar: `AppSettings.pttThresholdMs`
  (default 500ms).

- `held >= 500ms` → comporta-se como PTT release (stop immediato).
- `held < 500ms` → comporta-se como toggle tap (mantém a gravar até o
  utilizador tocar outra vez).

- `isARepeat` deve ser consumido mas **não** disparar callback (evita trigger
  múltiplo quando utilizador segura).

## TextInjector — ordem de tentativas

1. **AX API** primeiro, quando há `precapturedElement` e app-alvo activo
   **e** o bundleID **não** está em `axUnreliableBundleIDs`.
2. **Clipboard + ⌘V** quando:
   - AX falha mas app-alvo tem foco, OU
   - app-alvo está em `axUnreliableBundleIDs` (Electron/Catalyst onde
     `kAXSelectedTextAttribute` retorna `.success` mas não insere texto:
     WhatsApp, Slack, Discord, Teams, Telegram, ChatGPT, Claude, Notion,
     Obsidian, Zoom, Spotify, Cursor).
3. **Clipboard apenas** quando AX não está trustada (mostra ReviewHUD com
   instruções).

- `capturedFocusedElement` e `capturedTargetApp` são snapshots tirados em
  `DictationController.stopDictation()`. **Não** usar
  `NSWorkspace.frontmostApplication` depois do stop — a transcrição demora 2-5s
  e o foco pode mudar entretanto.

- Finder (`com.apple.finder`) sempre tratado como "no field" — força o banner
  de fallback clipboard+⌘V.

- Electron/web apps frequentemente têm foco de janela mas não expõem AX text
  fields. `FocusDetector.hasFocusedWindow()` distingue:
    - Window sim, AX element não → Electron com campo → paste funciona.
    - Nem window nem AX → sem campo de todo → mostra banner.

- No caminho blacklist (`.injectedViaClipboardPaste`) o clipboard **é sempre
  restaurado** após 0.6s (vs 0.4s no caminho normal) — delay suficiente para
  o Electron/Catalyst processar o Cmd+V antes do restore. Fix 2026-04-30:
  anteriormente não restaurava, destruindo o clipboard do utilizador em cada
  ditado para Electron apps. Em caso raro de paste engolido silenciosamente
  (modal/overlay), o utilizador perde o texto no clipboard — aceite como
  trade-off, pois preservar o clipboard é mais importante.

## Regra de apresentação do banner "Sem campo ativo"

**Princípio:** o banner só aparece quando o Spit *não tem certeza* se o
paste chegou ao destino. Em apps blacklisted o paste funciona quase sempre
→ banner ficaria ruidoso → não mostrar.

Decisão é tomada em `DictationController.processRecording` ao mapear o
`InjectionResult` para flags do `DictationResult`:

| Caminho de injecção | `pastedViaClipboard` | `usedKeyboardFallback` | Banner? |
|---|---|---|---|
| `.injectedViaAX` | false | false | ❌ |
| `.injectedViaKeyboard` (tem AX, sem field) | false | true se `noField` | ✅ se noField |
| `.injectedViaKeyboard` (clipboard+V por sem AX) | false | `isFinderOrLikelyNoField` | ✅ só se sem janela |
| `.injectedViaClipboardPaste` (blacklist) | **false** | **false** | ❌ |
| `.copiedToClipboard` (AX não trusted) | true | false | ✅ (warningBanner) |
| `.failed(...)` | true | false | ✅ |

`usedKeyboardFallback = true` só quando: `targetBundleID == "com.apple.finder"`
**OR** (`!hadCapturedAXElement && !hadFocusedWindow`).

**Ao alterar `TextInjector` ou esta lógica, manter:**
1. Apps blacklisted **não** disparam banner — texto vai silenciosamente para
   clipboard como safety net.
2. Banner só dispara quando há evidência real de falha (sem AX **e** sem
   janela, ou Finder, ou AX não-trustada, ou injection failed).
3. Para acrescentar app à blacklist: editar `axUnreliableBundleIDs` em
   `TextInjector.swift` — não criar nova lista paralela.

## FocusDetector

- Usa AX API. Chamadas podem bloquear — **não** chamar em hot paths.

- Verifica sempre `AXIsProcessTrusted()` antes de tentar — sem permissão AX
  devolve `nil` silenciosamente.
