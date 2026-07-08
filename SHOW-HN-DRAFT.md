# Show HN — rascunho

## Título
```
Show HN: Spit – On-device voice dictation for Mac, free and open source
```

## URL a submeter
```
https://github.com/Draxo-io/spit
```
(Link para o repo, não para o site — maximiza conversão em stars, que é o objetivo. O README já serve como landing page com instalação/features.)

## Primeiro comentário (postar imediatamente a seguir a submeter, como autor)

```
Hi HN,

I built Spit because every dictation app I tried for Mac either sent my
voice to someone else's server, cost a monthly fee, or both. It runs
Whisper entirely on-device via WhisperKit — no network calls during
normal use, no account, no subscription. MIT licensed.

How it works: a global hotkey (Globe key by default) starts/stops
recording, WhisperKit transcribes locally, and the text gets injected
into whatever app has focus via the Accessibility API (falls back to
clipboard+paste for apps that don't support AX text insertion). There's
also a live word preview while you talk, using SFSpeechRecognizer, so
you're not staring at a blank HUD waiting.

Requires Apple Silicon — Whisper inference needs the Neural Engine to
be fast enough to feel instant. Tested down to macOS 14.

Some things I learned building this that might be useful to others
doing on-device ML on macOS:

- Jetsam (the kernel's silent SIGKILL for memory pressure) is brutal
  and easy to miss in normal testing. WhisperKit's real footprint
  (`phys_footprint`, not `resident_size` — the latter drastically
  under-reports ANE/GPU memory) was 3GB+ on some models. I now listen
  to `DispatchSource.makeMemoryPressureSource` and unload models
  proactively, but had to be careful: reacting to every "warning"
  event (which fires often under normal system load) caused the model
  to unload and reload constantly, adding a ~10s reload tax to random
  dictations. Only unloading on "critical" for the frequently-used
  model, and reserving "warning" for the larger, less latency-sensitive
  TTS model, fixed it.
- WhisperKit's Core ML compilation is per-device, so first-run model
  load is slow the first time and fast after — worth setting
  expectations for that in onboarding.

It's a one-person, no-investor project (I run a small studio,
Draxo.io). Happy to answer anything about the implementation,
WhisperKit, or the Jetsam stuff.
```

## Notas de timing
- Postar 3ª ou 4ª-feira, entre 8h-10h ET (13h-15h em Portugal)
- Ficar disponível 4-6h a seguir para responder a comentários
- Não pedir upvotes a ninguém, não postar em grupos de "upvote exchange" — HN deteta e penaliza isso duramente
