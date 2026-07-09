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

## Substituições de vocabulário — duas vias

`VocabularyManager` divide entradas em duas categorias com base na ambiguidade
de `wrong`:

- **Inequívocas** (`wrong` não é palavra real PT/EN): proper nouns, marcas,
  siglas. Aplicadas via regex word-boundary em `apply(to:)` — chamado no
  Stage 2 do `processRecording`, antes do LLM de formatação.

- **Ambíguas** (`wrong` é palavra real PT/EN, ex.: "mel", "casa", "para"):
  passadas como `contextualSubstitutions` ao `TextFormattingService.format()`.
  O LLM judge decide com contexto (concordância, semântica, marca) se aplica
  cada substituição. Default conservador: **não substituir** salvo se o
  contexto suporta claramente.

Detecção de ambiguidade: `VocabularyManager.isAmbiguous(wrong:)` usa
`NSSpellChecker` em PT e EN (cacheado). Multi-palavra ("Rafa Lopes") é
sempre tratado como inequívoco.

**Quando o LLM não está disponível** (sem chave, offline, autoparagraph
desligado, privacy mode), as substituições ambíguas **simplesmente não se
aplicam**. Isto é deliberado — corromper "melhora" → "MEOhora" é pior do que
não substituir. O hint do Whisper continua activo (`generateWhisperPrompt`).

**Ao alterar este pipeline manter:**
1. `vocabularyManager.apply()` aplica APENAS inequívocas (regex word-boundary).
2. `vocabularyManager.ambiguousEntries()` é passado ao `format()` no autoparagraph.
3. Substituições ambíguas NUNCA são aplicadas por regex — só por LLM judge.
4. O proxy `/format` recebe `contextual_substitutions` no body (forward-compat
   — o backend pode implementar o judge sem mudar o cliente).

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
