# Spit (VoiceFlow) — Instruções para agentes

Este ficheiro é lido no arranque de qualquer thread que mexa neste projeto.
**Lê-o por completo antes de editar código.**

## Nome

O projeto chama-se **Spit** (user-facing). O bundle identifier é `app.getspit`.
O repo ainda se chama `VoiceFlow` por razões históricas — ignora essa inconsistência.

## O que é

App macOS menu-bar de ditado por voz com:
- Hotkey global (por defeito Globe 🌐) para iniciar/parar ditado
- Transcrição via Whisper (proxy Groq para trial/pro, BYOK OpenAI/Groq, ou local)
- Injecção de texto no app em foco (AX API, fallback clipboard+⌘V)
- TTS (read selection) na mesma hotkey com comportamento "smart"
- Live preview de palavras via `SFSpeechRecognizer` durante a gravação
- Pausa/retoma media (Spotify, Apple Music, etc.) durante ditado

## Protocolo de rebuild (OBRIGATÓRIO após qualquer edit)

Sequência automática — não esperar que o utilizador peça:

```bash
kill $(pgrep Spit) 2>/dev/null
cd /Users/rafaellopes/projects/VoiceFlow
xcodebuild -scheme VoiceFlow -configuration Debug -destination 'platform=macOS' build
open /Users/rafaellopes/Library/Developer/Xcode/DerivedData/VoiceFlow-aolpcvsxnunafqfwlrkmiotqesgm/Build/Products/Debug/Spit.app
```

## Paths críticos

| Artefacto | Path |
|---|---|
| Código fonte | `/Users/rafaellopes/projects/VoiceFlow/VoiceFlow/` |
| DerivedData app | `~/Library/Developer/Xcode/DerivedData/VoiceFlow-aolpcvsxnunafqfwlrkmiotqesgm/Build/Products/Debug/Spit.app` |
| **Debug log (runtime)** | `~/Library/Containers/app.getspit/Data/tmp/spit-debug.log` |
| Crash reports | `~/Library/Logs/DiagnosticReports/Spit-*.ips` |
| Settings (UserDefaults) | `~/Library/Containers/app.getspit/Data/Library/Preferences/app.getspit.plist` |
| Keychain | `app.getspit` service — chaves `byok.openai`, `byok.groq`, JWT de licença |

**Regra de ouro de debugging:** `tail -200` do `spit-debug.log` antes de propor qualquer fix.
Nunca diagnosticar por intuição — `FileLogger.swift` escreve síncrono com fsync.

## Arquitectura — em três linhas

1. **`HotkeyManager`** detecta keyDown/keyUp globais (CGEventTap para Globe, NSEvent para outras teclas) e dispara `onSmartKeyDown`/`onSmartKeyUp`.
2. **`DictationController`** (MainActor) é o único orquestrador. Máquina de estados: `idle → recording → processing → injecting → idle`. Todas as saídas passam por `finishCycle(...)`.
3. **Services são "burros"** — `AudioRecorder`, `WhisperService`, `TextInjector`, `TTSService` etc. não conhecem estado de ditado. Só o `DictationController` decide o que acontece a seguir.

## Regras aprendidas (NÃO violar — já custaram horas)

### AudioRecorder
- **NÃO tentar forçar built-in mic em Bluetooth HFP.** Foi tentado com `AUAudioUnit.setDeviceID` em 2026-04-21 e resultou em `EXC_CRASH SIGABRT` em `installTapOnBus`: `setDeviceID` dispara `AVAudioEngineConfigurationChange` → handler recursivo → crash.
- **NÃO registar observer para `AVAudioEngineConfigurationChange`** que volte a chamar `setupAndStartEngine`. Confia no `AVAudioEngine` — ele adapta-se a mudanças de device automaticamente.
- Usa o formato do `inputNode.outputFormat(forBus: 0)` tal como vem. Converte para mono via `AVAudioConverter` para o output file, mas **passa o buffer raw ao `LiveSpeechRecognizer`** (ele precisa do formato original).
- Guarda `minimumRecordingSeconds = 1.5` para silence auto-stop; gravações <1.5s nem chegam à transcrição.

### SystemAudioManager (pausar/retomar media)
- **NÃO enviar sempre `NX_KEYTYPE_PLAY`.** Se nenhum app estiver registado como now-playing (PID = 0), o macOS captura a key e **abre o Apple Music**. Fix histórico (2026-04-21): verificar `MRMediaRemoteGetNowPlayingApplicationPID` antes de enviar a key; se PID = 0, skip.
- `MRMediaRemoteGetNowPlayingApplicationIsPlaying` **mente em Bluetooth** (retorna false com música a tocar). Por isso usamos PID, não isPlaying.
- `didPauseMedia` garante que `resumeMedia()` só re-envia a key se **nós** é que pausámos. Não confiar no estado actual do sistema para isso.
- `resumeMedia()` deve ser chamado **depois** de `audioRecorder.stopRecording()` (senão o mic capta o burst de áudio que volta no momento em que pausamos o recording).

### LiveSpeechRecognizer
- É o **single source of truth** para "voice detected" — campo `liveWordsSeen` em `DictationController`. Não reintroduzir gates por dB RMS — foram removidos porque davam falsos negativos em áudio baixo legítimo.
- Recordings curtos (<2s) frequentemente dão `liveWordsSeen = false` porque o Speech framework não tem tempo de produzir palavras. Isto é esperado — resulta em "Nenhuma voz detectada" no ReviewHUD. **Não é bug.**

### Hotkey Globe
- O CGEventTap em `HotkeyManager.registerGlobeSmart()` tem de retornar `nil` para engolir o evento — senão o macOS activa dictation/input switch e toca o som do sistema ("bip duplo" com o Tink do Spit).
- Requer AX trust. Fallback para NSEvent (passivo) quando AX não trustada — nesse caso o bip do sistema é inevitável.

### TextInjector
- Tenta AX primeiro, depois clipboard+⌘V, depois só clipboard (quando AX não trustada).
- `capturedFocusedElement` e `capturedTargetApp` são snapshots feitos em `stopDictation()` — **não** usar `NSWorkspace.frontmostApplication` depois disso, porque a transcrição demora 2-5s e o foco muda.

### Estado / concurrency
- `DictationController.isStartingDictation` é uma guard **síncrona** (não async) — set antes de qualquer `await`. Sem isso, duas invocações podem passar o check `state == .idle` em paralelo.
- `dictationTask?.cancel()` antes de criar nova — garante que `processRecording` anterior não escreve depois.

## Como diagnosticar bugs (método, não intuição)

1. **Ler os últimos 100-200 linhas do `spit-debug.log`** — o ciclo completo aparece lá (`startDictation called` → `media paused` → `LiveSpeechRecognizer started` → `stopDictation called` → `transcribe OK` → `injected via …`).
2. **Se houve crash:** `ls -t ~/Library/Logs/DiagnosticReports/Spit-*.ips | head -1` e ler o último report. `Exception Type`, `Crashed Thread` e o topo do stack dizem quase sempre a resposta.
3. **Correlacionar timestamps** do log com o que o utilizador descreveu. Recordings curtos (<2s) vs longos têm comportamentos diferentes.
4. **Só depois propor um fix.** Nunca propor "talvez seja X" sem log.

## Quando editar `SPEC.md` / `SPEC-AUTH.md`

Estes dois são a **spec funcional** do produto (v1). Edita-os **apenas** quando:
- Mudança de comportamento user-visible (novo flow, novo estado, novo menu)
- Nova regra de licenciamento / trial / proxy
- Mudança de contratos entre Spit e backend de proxy

Não editar para mudanças internas (refactor, fixes, performance). Usa nota Kogno para isso.

## Kogno — memória de agente

Antes de começar, correr:
```
mcp__kogno__search "<assunto que vais tocar>"
```
Procurar notas com prefixo `[Agente] Spit — ...` — contêm causas raiz de bugs passados.

Ao acabar trabalho significativo, criar nota Kogno com:
- `source: "agent"`
- `project_name: "Spit"`
- Título: `[Agente] Spit — <assunto conciso>`
- Corpo: sintoma + causa raiz + fix (markdown conciso)

Verificar antes com `search` se já existe — não duplicar.

## Proibições

- **Nunca** mudar `bundle identifier` (`app.getspit`) — quebra Keychain e licenças.
- **Nunca** adicionar dependências de terceiros sem discutir primeiro. O projeto é deliberadamente zero-deps além do SDK Apple.
- **Nunca** commitar chaves, JWT, ou URLs de proxy com secrets hardcoded.
- **Nunca** desactivar `App Sandbox` em Release.
