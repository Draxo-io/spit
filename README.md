# Spit

> App macOS de ditado e leitura por voz. Menu bar app. Privacidade-first com modo local offline disponível.

**Status:** beta · macOS 13+ · Made in EU

## Features principais

- 🎙 **Ditado por voz** com Whisper — cloud (trial/pro, via proxy Groq) ou local (offline, ilimitado)
- 🔊 **Leitura em voz alta** (TTS) com Cartesia/OpenAI
- 🌍 **Tradução automática** pós-transcrição
- 🧠 **Parágrafo automático** via LLM (reutiliza a chave STT)
- 📝 **Vocabulário pessoal** — substituições + prompt hints
- 🎛 **Smart hotkey** unificada: tap = toggle, hold = PTT
- 🔒 **BYOK** (bring your own key) — OpenAI, Groq, Cartesia, DeepL, etc.
- 🎵 **Pausa automática** de Spotify/Music/browsers durante ditado

## Instalação

- **App Store:** [getspit.app](https://getspit.app) *(em preparação)*
- **Download directo:** [getspit.app/download](https://getspit.app) *(em preparação)*
- **Build local:** ver secção abaixo.

## Build local

### Pré-requisitos

- macOS 13.0 (Ventura) ou superior
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Apple Developer Team ID (só necessário para code signing local)

### Passos

```bash
git clone <este-repo>
cd VoiceFlow

# Gerar projecto Xcode a partir de project.yml
xcodegen generate

# Editar project.yml e definir o DEVELOPMENT_TEAM
# (ou abrir em Xcode e escolher o team manualmente)

# Build + run
xcodebuild -scheme VoiceFlow -configuration Debug -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/VoiceFlow-*/Build/Products/Debug/Spit.app
```

Em desenvolvimento, usa o slash command `/rebuild` (definido em `.claude/commands/rebuild.md`)
para automatizar o ciclo completo.

## Stack técnico

- **Linguagem:** Swift 5.9, SwiftUI + AppKit
- **Áudio:** `AVAudioEngine` + `SFSpeechRecognizer` (live preview)
- **Hotkey global:** `CGEventTap` (Globe 🌐) + `NSEvent` monitors (outras teclas)
- **Transcrição:** OpenAI Whisper API · Groq Whisper · [WhisperKit](https://github.com/argmaxinc/WhisperKit) local
- **TTS:** Cartesia Sonic · OpenAI TTS · `AVSpeechSynthesizer` (fallback)
- **Licenciamento:** proxy backend + JWT; BYOK via Keychain
- **Dependências externas:** **zero** — só SDK Apple + WhisperKit (local)

## Documentação para developers

| Ficheiro | O que contém |
|---|---|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Visão geral de arquitectura e decisões de design |
| [`SPEC.md`](SPEC.md) | Especificação funcional do produto |
| [`SPEC-AUTH.md`](SPEC-AUTH.md) | Licenciamento, trial, proxy, BYOK |
| [`CHANGELOG.md`](CHANGELOG.md) | Histórico de bugs com causa raiz |
| [`CLAUDE.md`](CLAUDE.md) | Instruções para agentes Claude (rebuild, debugging, regras) |
| `.claude/rules/*.md` | Regras scoped por ficheiro/área |

## Privacidade

- **Modo local:** zero rede. Áudio nunca sai do dispositivo.
- **Modo cloud (proxy):** áudio é transmitido encriptado para o nosso proxy, que
  reencaminha para Groq. Áudio e transcrições não são guardados depois da
  resposta.
- **Modo BYOK:** áudio vai directamente para o provider que escolheres
  (OpenAI/Groq/etc.) com a tua chave. Aplicam-se as políticas deles.
- **App Sandbox** sempre activo. Entitlements mínimos: mic, network client.

## License

Por definir. *(Em consideração: abertura OSS depois da v1.0.)*

## Acknowledgments

- [OpenAI Whisper](https://github.com/openai/whisper) — speech recognition models
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device inference
- [Groq](https://groq.com) — fast cloud inference
- [Cartesia](https://cartesia.ai) — TTS

---

*Spit is built with care in the EU.*
