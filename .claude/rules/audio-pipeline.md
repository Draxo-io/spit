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

- **NÃO enviar sempre `NX_KEYTYPE_PLAY`.** Se nenhum app estiver registado como
  now-playing (PID = 0), o macOS captura a key e **abre o Apple Music**.
  Verifica `MRMediaRemoteGetNowPlayingApplicationPID` primeiro; se PID = 0,
  skip. Fix: 2026-04-21 (ver `CHANGELOG.md`).

- `MRMediaRemoteGetNowPlayingApplicationIsPlaying` **mente em Bluetooth HFP**
  (retorna `false` com música a tocar). Por isso usamos PID, não isPlaying.

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

- **Fallback para output device activo (Core Audio).** Chrome / browsers a
  tocar via web frequentemente NÃO registam no MediaRemote — `nowPlayingPID`
  retorna 0. Solução: quando PID = 0, verificar
  `kAudioDevicePropertyDeviceIsRunningSomewhere` no default output device.
  Se há áudio a sair, é seguro enviar play/pause (já há algum app a tocar,
  não vamos abrir Apple Music). Se output silencioso, manter o skip
  (preserva o fix anti-Apple-Music). Fix: 2026-04-27.

## LiveSpeechRecognizer

- É o **single source of truth** para "voice detected" — campo `liveWordsSeen`
  em `DictationController`. **Não reintroduzir gates por dB RMS** — foram
  removidos porque davam falsos negativos em áudio baixo legítimo, e
  criavam desfasamento entre HUD e backend.

- Recordings curtos (<2s) frequentemente dão `liveWordsSeen = false` porque o
  Speech framework não tem tempo de produzir palavras. Isto é **esperado** —
  resulta em "Nenhuma voz detectada" no ReviewHUD. **Não é bug.**

- O recognizer precisa de locale BCP-47 (ex.: `pt-BR`, `en-US`). Quando
  `settings.language == "auto"`, usa `lastDetectedLanguage` do Whisper da
  sessão anterior. Mapeamento de nomes Whisper ("Portuguese") → BCP-47 ("pt")
  feito em `DictationController.normalizeWhisperLang()`.
