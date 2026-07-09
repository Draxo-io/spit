---
paths:
  - VoiceFlow/Services/AudioRecorder.swift
  - VoiceFlow/Services/SystemAudioManager.swift
  - VoiceFlow/Services/LiveSpeechRecognizer.swift
---

# Pipeline de áudio — regras duras

Estas regras já custaram horas de debugging. **Não violar sem ler `CHANGELOG.md` primeiro.**

## AudioRecorder

- **NÃO tentar forçar built-in mic em Bluetooth HFP.** Tentado em 2026-04-21 com
  `AUAudioUnit.setDeviceID` → `EXC_CRASH SIGABRT` em `installTapOnBus`.
  Causa: `setDeviceID` dispara `AVAudioEngineConfigurationChange` → handler
  recursivo → crash. Em Bluetooth HFP o sample rate do mic cai para 8-16 kHz
  mas funciona. **Aceitar.**

- **NÃO registar observer para `AVAudioEngineConfigurationChange`** que chame
  `setupAndStartEngine`. O `AVAudioEngine` adapta-se a mudanças de device
  automaticamente.

- Usa o formato de `inputNode.outputFormat(forBus: 0)` tal como vem. Converte
  para mono via `AVAudioConverter` para o ficheiro de output, mas **passa o
  buffer raw ao `LiveSpeechRecognizer`** (ele precisa do formato original do
  input, não do mono convertido).

- `minimumRecordingSeconds = 1.5` guarda para silence auto-stop. Gravações
  <1.5s são tratadas como "too short" pelo `DictationController` antes de
  chegar à transcrição.

## SystemAudioManager (pausar/retomar media)

- **MRMediaRemote (API privada) foi REMOVIDA — não reintroduzir.** Rejeitada
  pela App Store. Toda a detecção de estado migrou para vias públicas.

- `didPauseMedia` garante que `resumeMedia()` só re-envia a key se **nós** é
  que pausámos. Não confiar no estado actual do sistema para isto.

- `resumeMedia()` deve ser chamado **depois** de `audioRecorder.stopRecording()`
  no `DictationController.stopDictation()`. Ordem inversa deixa burst de
  música no output do ficheiro gravado.

- **`cgEvent.post(tap: .cghidEventTap)` — não trocar para `cgSessionEventTap`.**
  Chrome, browsers e web players (YouTube Music, Google Music, Spotify Web)
  só escutam media keys ao nível HID — exactamente o nível onde a tecla
  física F8 chega. `cgSessionEventTap` é entregue acima e estes apps não a
  vêem. Spotify desktop, Apple Music e similares funcionam em ambos. Fix:
  2026-04-27 (Google Music em Chrome não pausava).

- **Detecção de estado: 3 fases em cascata — nunca colapsar para 1.**
  `kAudioDevicePropertyDeviceIsRunningSomewhere` retorna `true` mesmo com media
  PAUSADA (I/O proc activo para retoma rápida) — por isso sozinho NÃO chega.
  Sequência correcta em `isOutputDeviceActive()`:

  **Fase 1 — gate rápido:** `DeviceIsRunningSomewhere == 0` → nada a tocar → return false.

  **Fase 2 — Apple Events para players desktop conhecidos (Spotify, Music, QuickTime Player):**
  - `true` → a tocar → pausar.
  - `false` (player a correr mas PAUSADO, nenhum a tocar) → skip key.
  - `nil` (player não corre / sem permissão) → passar à fase 3.
  Helpers: `isPlayerPlaying(appName:bundleID:)` para Spotify/Music,
  `isQuickTimePlayerPlaying()` para QuickTime Player (usa `rate of first document`).
  **Só envia Apple Event se o app já estiver em execução** (check `NSWorkspace.runningApplications`)
  — caso contrário `tell application "Spotify"` LANÇARIA o Spotify.

  **Fase 3 — return false (conservador). ← FIX 2026-06-23**
  `DeviceIsRunning` NÃO distingue browser pausado de browser a tocar:
  - Spotify Web em Chrome mantém `DeviceIsRunning = 1` mesmo pausado.
  - AVAudioEngine do Spit (TTS) também faz `DeviceIsRunning = 1`.
  Enviar a key nestas condições inicia media pausada. Fase 3 retorna sempre `false`.
  Trade-off: browsers a tocar não são auto-pausados — aceite.

- **NÃO voltar ao DistributedNotificationCenter para o Spotify.** O Spotify
  desktop recente já não posta `com.spotify.client.PlaybackStateChanged`, por
  isso o estado ficava eternamente `nil` e o bug "retoma música pausada ao
  iniciar ditado" persistia. Causa raiz confirmada nos logs 2026-05-22 (zero
  notificações Spotify alguma vez recebidas). Fix definitivo: Apple Events
  2026-05-22.

## LiveSpeechRecognizer

- É o **single source of truth** para "voice detected" — campo `liveWordsSeen`
  em `DictationController`. **Não reintroduzir gates por dB RMS** — foram
  removidos porque davam falsos negativos em áudio baixo legítimo, e
  criavam desfasamento entre HUD e backend.

- Recordings curtos (<2s) frequentemente dão `liveWordsSeen = false` porque o
  Speech framework não tem tempo de produzir palavras. Isto é **esperado** —
  resulta em "Nenhuma voz detectada" no ReviewHUD. **Não é bug.**

- O recognizer precisa de locale BCP-47 (ex.: `pt-BR`, `en-US`). Mapeamento de
  nomes Whisper ("Portuguese") → BCP-47 ("pt") em
  `DictationController.normalizeWhisperLang()`.

- **Quando `settings.language == "auto"`, passar `"auto"` ao recognizer** — NÃO
  usar `lastDetectedLanguage` da sessão anterior (corrigido 2026-05-26). O
  recognizer resolve via `NSLocale.preferredLanguages.first` (idioma do macOS),
  o proxy mais robusto. Causa do bug anterior: em "auto", o `lastDetectedLanguage`
  ficava preso no idioma da última sessão — se o user fez uma sessão acidental
  em EN, as seguintes mostravam preview em inglês mesmo a ditar em PT. O Whisper
  na transcrição faz auto-detect real do áudio, pelo que o texto final fica
  correto independentemente do que o live preview mostra.
