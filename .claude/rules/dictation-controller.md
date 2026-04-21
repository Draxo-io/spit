---
paths:
  - VoiceFlow/Controllers/DictationController.swift
  - VoiceFlow/UI/HUDCoordinator.swift
---

# DictationController — regras de estado e concorrência

## Princípio cardinal

**O `DictationController` é o único orquestrador.** Nenhum service em
`VoiceFlow/Services/` deve conhecer estado de ditado. Services oferecem APIs
imperativas ("gravar", "transcrever", "injectar") — o Controller decide a
sequência. Ver `ARCHITECTURE.md` para a justificação.

## Máquina de estados

```
idle → recording → processing → injecting → idle
                                     ↘        ↗
                                      error/empty
```

- **Única saída é `finishCycle(result:mode:hasSuspicious:)`.** Sem `return
  early` directo para `state = .idle`. Qualquer caminho de erro, vazio ou
  sucesso passa por `finishCycle`. Isto garante:
    - `HUDCoordinator.dictationCompleted` é sempre chamado.
    - Logging central (`[HUDCoordinator] completed —...`).
    - Ponto único para invariantes futuros.

- Em `processRecording`, todos os `catch` terminam com `finishCycle(...)` +
  `return`. Nunca fazer `throw` para cima ou deixar o Task morrer em silêncio.

## Concorrência

- `DictationController` é `@MainActor`. Serialização vem "de borla".

- `isStartingDictation` é uma guard **síncrona** — set antes de qualquer
  `await`. Sem isto, duas invocações de `startDictation()` podem passar o
  check `state == .idle` em paralelo (race).

- `dictationTask?.cancel()` antes de criar nova Task em `stopDictation` e
  `retryPendingDictation`. Garante que `processRecording` anterior não escreve
  depois de nós reiniciarmos.

- Todos os callbacks de services (`onLevelUpdate`, `onAudioBuffer`,
  `onDeviceChanged`, `onSmartKeyDown`, `onSmartKeyUp`) devem fazer hop para
  main via `Task { @MainActor in ... }` ou `DispatchQueue.main.async`. Não
  assumir que correm na main thread.

## Snapshot de foco — SEMPRE em `stopDictation()`

- `capturedFocusedElement`, `capturedTargetApp`, `capturedTargetHasFocusedWindow`
  são tirados **no momento do stop**, antes do `await` de transcribe/translate.

- Usar `NSWorkspace.frontmostApplication` depois do stop é **sempre errado** —
  o utilizador pode ter mudado de app nos 2-5s da pipeline async.

## Voice detected

- Fonte única: `liveWordsSeen` (bool). Set em `liveSpeechRecognizer.onRollingWords`
  quando `!words.isEmpty`.

- **Não** adicionar gates por dB, por duração, por regex, por nada. Se o live
  recognizer viu palavras, o backend procede. Se não viu, mostra "no voice".
  Ponto.

- Recordings <2s frequentemente resultam em `liveWordsSeen = false`. Esperado.

## Lifecycle de retry

- `storePendingRetry(url, duration)` guarda áudio por 10 min após falha de
  transcribe. Cancela automaticamente quando `pendingRetryURL` é limpo (sucesso
  ou novo ditado).

- Retry **nunca re-grava** — reusa o `.m4a` guardado. Isto é crítico para
  falhas de rede: o utilizador não tem de repetir o que disse.

## HUD e estado visual

- `HUDCoordinator` é quem decide se o ReviewHUD aparece (baseado em
  `reviewHUDMode`, `hasSuspicious`, `pastedViaClipboard`, `usedKeyboardFallback`).
  Controller **não** toma essa decisão.

- Controller só chama `HUDCoordinator.recordingStarted()`,
  `.processingStarted()`, `.dictationCompleted(...)`. O resto é do Coordinator.
