# Spit — Arquitectura

Este documento descreve **porquê** o código está organizado como está. Para o **quê**
(regras, paths, protocolos), ver `CLAUDE.md`. Para **histórico** de bugs e causas
raiz, ver `CHANGELOG.md`.

Público-alvo: agentes Claude e o próprio Rafael em sessões futuras.

## Visão geral — uma imagem mental

```
┌──────────────────────────────────────────────────────────────────┐
│                         Hotkey física                              │
│                     (Globe / outra tecla)                          │
└───────────────────────────┬──────────────────────────────────────┘
                            │ CGEventTap (Globe) / NSEvent (outras)
                            ▼
                    ┌──────────────┐
                    │ HotkeyManager │  ← detecção, suprime evento do sistema
                    └───────┬──────┘
                            │ onSmartKeyDown / onSmartKeyUp
                            ▼
         ╔═════════════════════════════════════════════╗
         ║           DictationController                ║
         ║  (MainActor, ObservableObject)               ║
         ║                                               ║
         ║   State machine ÚNICA:                        ║
         ║   idle → recording → processing → injecting   ║
         ║                              └────→ idle      ║
         ║                                               ║
         ║   Única saída: finishCycle(result, mode)      ║
         ╚══════════════════╤══════════════════════════╝
                            │ orquestra
          ┌─────────────────┼───────────────────┬──────────────┐
          ▼                 ▼                   ▼              ▼
  ┌──────────────┐  ┌────────────────┐  ┌────────────┐  ┌──────────┐
  │ AudioRecorder│  │ WhisperService │  │TextInjector│  │ HUDCoord.│
  │              │  │ (proxy/BYOK/   │  │            │  │          │
  │ tap → buffer │  │  local)        │  │ AX / ⌘V    │  │ UI state │
  └──────┬───────┘  └────────────────┘  └────────────┘  └──────────┘
         │ raw buffer
         ▼
  ┌──────────────────┐
  │LiveSpeechRecogn. │  ← preview de palavras no HUD
  │(Apple Speech fw) │     E fonte única de "voice detected"
  └──────────────────┘

Serviços auxiliares (chamados pelo Controller):
  SystemAudioManager  — pausa/retoma media (play/pause key)
  FocusDetector        — snapshot do elemento AX em foco
  VocabularyManager    — substituições aprendidas
  TranslationService   — tradução opcional pós-Whisper
  TextFormattingService— LLM de formatação (autoparagraph)
  CreditsManager       — BYOK key + contabilização
  LicenseManager       — trial/pro/BYOK state
```

## Princípio cardinal

> **Serviços são burros. O Controller é esperto.**

Todos os services em `VoiceFlow/Services/` devem ser ignorantes sobre o estado de
ditado. Não conhecem máquina de estados, não decidem se devem ou não actuar, não
sabem o que vem antes ou depois. Oferecem APIs **imperativas** ("gravar",
"transcrever", "injectar") e devolvem resultados.

O `DictationController` é o **único** que sabe a sequência correcta. Esta
separação é o que evita race conditions e estados inconsistentes.

**Consequência prática**: se estás tentado a adicionar lógica condicional dentro
de um service que depende do estado de outro service — **pára**. Essa lógica
pertence ao Controller.

## Decisões específicas (com porquê)

### 1. `DictationController` em `@MainActor`

Não é uma actor isolada com inbox própria, é `@MainActor`. Porquê:

- O state da UI (HUDs, menu bar, settings) tem de ser actualizado na main thread
  de qualquer forma.
- `AXUIElement`, `NSWorkspace`, `NSEvent`, `CGEvent` querem main thread.
- Qualquer serialização extra via custom actor introduzia hops sem ganho.

**Trade-off aceite**: blocking work não pode correr no controller directamente.
Por isso `processRecording` é `async` e as chamadas pesadas (transcribe, translate,
format) são `await` — cada uma suspende a main thread apenas durante o hop, não
durante o work real.

### 2. Única saída via `finishCycle(...)`

Toda a saída da máquina de estados passa por `finishCycle(result:mode:hasSuspicious:)`.
Não há `return early` directo → `state = .idle`. Porquê:

- Garante que `HUDCoordinator.dictationCompleted` é chamado sempre — sem isso,
  o HUD pode ficar preso em estados parciais.
- Logging central: a linha `[HUDCoordinator] completed —...` é a prova de que
  o ciclo fechou.
- Facilita adicionar invariantes futuros (telemetria, cleanup, analytics) num
  só sítio.

### 3. Snapshot de foco em `stopDictation()`, não em `processRecording()`

`capturedFocusedElement` e `capturedTargetApp` são tirados no momento em que o
utilizador larga a hotkey. Porquê:

- Entre stop e injecção passam 2-5s (Whisper + tradução + formatação).
- Nesse tempo o utilizador pode trocar de app ou clicar noutro campo.
- Se capturássemos só antes de injectar, injectávamos no sítio errado.

### 4. `liveWordsSeen` como fonte única de "voice detected"

Havia antes um gate por dB RMS no buffer mono. Foi removido porque:

- Dava falsos negativos em voz baixa legítima.
- Duplicava o que o `LiveSpeechRecognizer` já fazia (que também escreve no HUD).
- Tornava o HUD e o backend discordantes: o utilizador via palavras no HUD mas
  o backend dizia "no voice".

Regra: o que o utilizador vê no HUD é o que o backend vê. Uma só fonte.

### 5. Pausa de media via play/pause key, não AppleScript por app

Considerou-se fazer `tell application "Spotify" to pause` etc. Rejeitado:

- Precisaria de AppleScript entitlements e target por cada app (Spotify, Music,
  Chrome, Safari, YouTube Music, Tidal, ...).
- Cada um com sintaxe diferente.
- Play/pause key é **universal**: qualquer app que responde a media keys do
  teclado físico pausa.

**Custo pago**: se nenhum app estiver registado como now-playing, a key abre
o Apple Music (default handler do macOS). Mitigado com o check do
`MRMediaRemoteGetNowPlayingApplicationPID` (ver `CHANGELOG.md` 2026-04-21).

### 6. Três backends de transcrição: proxy / BYOK / local

- **Proxy (Groq)**: default para trial + pro. Backend nosso, medido em segundos
  consumidos, enforcement de licença.
- **BYOK (OpenAI/Groq)**: utilizador traz a própria chave. Sem contabilização
  de créditos, apenas validação de licença "BYOK".
- **Local (whisper.cpp)**: privacy-first, sem rede. Modelo carregado em RAM.

Um só protocolo abstracto? Não — as três têm models de erro e metadata diferentes
(ex.: proxy reporta segundos consumidos, BYOK não). A abstracção seria leaky.
Preferiu-se dispatch explícito em `DictationController.transcribe(url:settings:)`.

### 7. CGEventTap para Globe, NSEvent para o resto

O Globe (keyCode 63) dispara `.flagsChanged`, não `.keyDown`. Um NSEvent monitor
passivo (global) **não engole o evento** — o macOS processa-o na mesma e toca o
som do sistema / activa dictation. Por isso usamos CGEventTap ativo com
`return nil` para suprimir.

Requer AX trust. Fallback NSEvent quando AX não está trustada — aceita o bip
duplo como mal menor.

### 8. FileLogger síncrono com fsync

`NSLog`/`os_log` no macOS moderno vai para o sistema de logs unificado e **não
aparece em stderr/Console.app em tempo real** durante development. Solução:
`FileLogger` que escreve síncrono para `~/Library/Containers/app.getspit/Data/tmp/spit-debug.log`.

- Síncrono → ordem garantida, nada perdido em crashes.
- Uma linha por evento, com timestamp ISO8601 e `file:linha`.
- Rápido de `tail -f` e grep durante debugging.

### 9. App Sandbox + entitlements mínimos

App Sandbox está on. Entitlements essenciais:
- `com.apple.security.device.audio-input` — mic
- `com.apple.security.network.client` — proxy + BYOK
- `com.apple.security.automation.apple-events` — AX API em alguns cenários
- `com.apple.security.temporary-exception.apple-events` — apps target para injecção

Sem Sandbox, os utilizadores podem distribuir mas não submeter à App Store. A
decisão de manter Sandbox é para manter a porta aberta.

## Fluxos-chave em 10 linhas cada

### Fluxo de ditado (happy path)

1. `HotkeyManager.onSmartKeyDown` → `DictationController.startDictation()`
2. Check license → check state → guard `isStartingDictation`
3. `SystemAudioManager.pauseMedia()` — só se PID > 0
4. `AudioRecorder.startRecording()` instala tap e cria `.m4a`
5. `LiveSpeechRecognizer.start()` e `onAudioBuffer` passa buffer raw ao recognizer
6. Utilizador larga Globe → `onSmartKeyUp` com `held >= 500ms`
7. `stopDictation()`: para live recognizer, captura foco, para recording,
   `resumeMedia()`, check voice detected
8. `processRecording()`: transcribe → cleanup → vocabulary → autoparagraph →
   translate → inject
9. `HUDCoordinator.dictationCompleted()` decide se mostra ReviewHUD
10. `finishCycle()` → `state = .idle`

### Fluxo de erro (transcribe falha)

1. `processRecording()` apanha exception de `transcribe(...)`
2. `describeError(error)` gera mensagem humana
3. `storePendingRetry(url, duration)` guarda o áudio por 10min para retry
4. `finishCycle(result: .placeholder(outcome: .error(...)))` → HUD mostra retry button
5. Utilizador clica retry → `retryPendingDictation()` → volta ao ponto 1 sem
   re-gravar

### Fluxo TTS (Smart Globe — ler selecção)

1. `onSmartKeyDown` com state `.idle` e texto seleccionado
2. `TTSService.selectedTextForSmartKey()` — tenta AX primeiro, Cmd+C fallback
3. `TTSService.speak(text)` — stream do proxy TTS ou fallback AVSpeechSynthesizer
4. Globe pressionado novamente → `TTSService.stop()` (Globe = stop universal)

## O que NÃO está aqui (deliberadamente)

- **Detalhes de implementação** dos services: ler o código, é o que manda.
- **API do proxy backend**: `SPEC-AUTH.md`.
- **Comportamento UX** de cada HUD: `SPEC.md`.
- **Protocolos operacionais** (rebuild, debug): `CLAUDE.md`.
- **Bugs passados**: `CHANGELOG.md`.

## Checklist ao adicionar uma feature nova

1. Afecta a máquina de estados? → Editar `DictationController`, **não** inventar
   estado paralelo noutro sítio.
2. Precisa de novo service? → Novo ficheiro em `Services/`, API imperativa, sem
   conhecer o Controller.
3. Pode ficar preso em estado parcial? → Garantir que todos os paths chegam a
   `finishCycle(...)`.
4. Depende de uma API privada da Apple? → Registar no `CHANGELOG.md` com o risco.
5. Muda comportamento user-visible? → Actualizar `SPEC.md`.
6. Adiciona decisão não óbvia? → Actualizar este ficheiro ou criar ADR em
   `docs/ADR/NNNN-titulo.md`.
