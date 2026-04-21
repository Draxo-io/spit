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

1. **AX API** primeiro, quando há `precapturedElement` e app-alvo activo.
2. **Clipboard + ⌘V** quando AX falha mas app-alvo tem foco.
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

## FocusDetector

- Usa AX API. Chamadas podem bloquear — **não** chamar em hot paths.

- Verifica sempre `AXIsProcessTrusted()` antes de tentar — sem permissão AX
  devolve `nil` silenciosamente.
