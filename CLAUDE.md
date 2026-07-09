# Spit (VoiceFlow) — Instruções para agentes

Este ficheiro é lido no arranque de qualquer thread que mexa neste projeto.
**Lê-o por completo antes de editar código.**

## Nome

O projeto chama-se **Spit** (user-facing). O bundle identifier é `app.getspit`.
O repo ainda se chama `VoiceFlow` por razões históricas — ignora essa inconsistência.

## O que é

App macOS menu-bar de ditado por voz com:
- Hotkey global (por defeito Globe 🌐) para iniciar/parar ditado
- Transcrição via Whisper (proxy Groq/OpenIA para trial/pro, BYOK OpenAI/Groq, ou local)
- Injecção de texto no app em foco (AX API, fallback clipboard+⌘V)
- TTS (read selection) na mesma hotkey com comportamento "smart"
- Live preview de palavras via `SFSpeechRecognizer` durante a gravação
- Pausa/retoma media (Spotify, Apple Music, etc.) durante ditado ou leitura caso esteja a reproduzir algo ao teclar o hotkey

Para visão geral de arquitectura → `ARCHITECTURE.md`.
Para spec funcional → `SPEC.md` e `SPEC-AUTH.md`.
Para histórico de bugs corrigidos → `CHANGELOG.md`.

> **Regra de auditoria**: quando o utilizador pedir para "rever / auditar /
> verificar divergências" entre código e documentação, ler **todos** os
> documentos listados acima (CLAUDE.md, CHANGELOG.md, ARCHITECTURE.md,
> SPEC.md, SPEC-AUTH.md, `.claude/rules/*.md`). Nunca restringir a um
> subset sem instrução explícita do utilizador. Cada um cobre uma camada
> diferente (regras para agentes, lições de bugs, arquitectura interna,
> spec funcional de produto, autenticação) e uma auditoria só é completa
> quando cobre todas.

## Build de desenvolvimento vs produção — SEPARADAS (2026-07-07)

A build de **Debug** é uma app distinta da de produção, para poderem coexistir
e ser testadas em simultâneo sem conflito:

| | Debug ("Spit Dev") | Release (produção) |
|---|---|---|
| Bundle ID | `app.getspit.dev` | `app.getspit` |
| Ícone na barra | martelo 🔨 | waveform |
| Hotkey default | ⌥ Option direito (keyCode 61) | Globe 🌐 (keyCode 63) |
| Auto-relaunch (LaunchAgent) | **desligado** | ligado |
| Container/definições/log | isolados em `app.getspit.dev` | `app.getspit` |

Isto resolveu o bug em que ter as duas instaladas com o mesmo bundle ID fazia
o guard de instância matar uma e as duas competirem pelo mesmo CGEventTap do
Globe → travamentos. **Nunca reverter o bundle ID da Debug para `app.getspit`.**
A proibição de mudar o bundle ID refere-se só à **produção** (Keychain/licenças).

## Protocolo de rebuild (OBRIGATÓRIO após qualquer edit)

Usa o slash command `/rebuild` — é o caminho canónico. Corresponde a:

```bash
# Mata SÓ a Dev (por path), nunca a produção do utilizador
pkill -f "DerivedData/VoiceFlow-hfayfoyiaxzwzjdermhtiguqxtnn/Build/Products/Debug/Spit Dev.app" 2>/dev/null
cd "/Users/rafaellopes/Library/CloudStorage/GoogleDrive-rafa@rafamail.com/Meu Drive/Empreendedorismo/Spit"
xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Debug -destination 'platform=macOS' build
open "$HOME/Library/Developer/Xcode/DerivedData/VoiceFlow-hfayfoyiaxzwzjdermhtiguqxtnn/Build/Products/Debug/Spit Dev.app"
```

Não esperar que o utilizador peça — é automático.
Avise o usuário depois e feito para que ele possa testar.

## Paths críticos

| Artefacto | Path |
|---|---|
| Código fonte | `/Users/rafaellopes/Library/CloudStorage/GoogleDrive-rafa@rafamail.com/Meu Drive/Empreendedorismo/Spit/VoiceFlow/` |
| DerivedData app (Dev) | `~/Library/Developer/Xcode/DerivedData/VoiceFlow-hfayfoyiaxzwzjdermhtiguqxtnn/Build/Products/Debug/Spit Dev.app` |
| **Debug log (Dev, runtime)** | `~/Library/Containers/app.getspit.dev/Data/Library/Logs/Spit/spit-debug.log` |
| Debug log (produção) | `~/Library/Containers/app.getspit/Data/Library/Logs/Spit/spit-debug.log` |
| Crash reports | `~/Library/Logs/DiagnosticReports/Spit-*.ips` |
| Settings Dev (UserDefaults) | `~/Library/Containers/app.getspit.dev/Data/Library/Preferences/app.getspit.dev.plist` |
| Keychain service | `app.getspit` — chaves `byok.openai`, `byok.groq`, JWT de licença |

**Regra de ouro de debugging:** `tail -200` do `spit-debug.log` antes de propor qualquer fix.
Nunca diagnosticar por intuição — `FileLogger.swift` escreve síncrono com fsync.

## Regras scoped (lidas automaticamente por `paths:`)

Regras específicas de áreas do código estão em `.claude/rules/*.md` com
`paths:` no frontmatter. Só são carregadas quando editas ficheiros dessa
área. Conteúdo actual:

| Ficheiro | Cobre |
|---|---|
| `.claude/rules/audio-pipeline.md` | `AudioRecorder`, `SystemAudioManager`, `LiveSpeechRecognizer` |
| `.claude/rules/hotkey-and-input.md` | `HotkeyManager`, `TextInjector`, `FocusDetector` |
| `.claude/rules/dictation-controller.md` | `DictationController`, `HUDCoordinator` |

Se vais editar um destes ficheiros, a regra correspondente já estará no teu
contexto. Se vais editar código que **interage** com estes módulos mas não
pertence a eles, abre o ficheiro de regras manualmente antes de propor mudanças.

## Como diagnosticar bugs (método, não intuição)

1. **Ler os últimos 100-200 linhas do `spit-debug.log`** — o ciclo completo
   aparece lá (`startDictation called` → `media paused` → `LiveSpeechRecognizer
   started` → `stopDictation called` → `transcribe OK` → `injected via …`).
2. **Se houve crash:** `ls -t ~/Library/Logs/DiagnosticReports/Spit-*.ips | head -1`
   e ler o último report. `Exception Type`, `Crashed Thread` e o topo do stack
   dizem quase sempre a resposta.
3. **Correlacionar timestamps** do log com o que o utilizador descreveu.
   Recordings curtos (<2s) vs longos têm comportamentos diferentes.
4. **Só depois propor um fix.** Nunca propor "talvez seja X" sem log.

## Quando editar `SPEC.md` / `SPEC-AUTH.md`

Edita-os **apenas** quando:
- Mudança de comportamento user-visible (novo flow, novo estado, novo menu)
- Nova regra de licenciamento / trial / proxy
- Mudança de contratos entre Spit e backend de proxy

**Não** editar para mudanças internas (refactor, fixes, performance). Usa
`CHANGELOG.md` + nota Kogno para isso.

### Regra de sincronização spec ↔ código (OBRIGATÓRIA)

Sempre que for introduzida uma **nova especificação** ou **alterada uma já
existente** — seja por pedido do utilizador ou por decisão tomada durante o
trabalho que toque comportamento user-visible / regra de negócio / contrato
de proxy — o agente **tem de**:

1. **Parar** antes de implementar.
2. **Avisar** o utilizador: identificar o que muda, em que secção do
   `SPEC.md` (ou `SPEC-AUTH.md`) entra, e qual era o texto anterior se
   aplicável.
3. **Pedir autorização explícita** para actualizar a spec.
4. Só após aprovação: actualizar o `.md` correspondente **primeiro**, e só
   depois o código.

Isto vale também no caminho inverso: se durante uma auditoria for detectada
uma divergência onde o código está certo e a spec está desactualizada,
propor a actualização da spec antes de fazer qualquer fix noutro lado.

Nunca silenciosamente alinhar código e spec — a spec é o contrato visível
ao utilizador e tem de ser revista por ele.

## Kogno — memória de agente

Antes de começar, correr:
```
mcp__kogno__search "<assunto que vais tocar>"
```
Procurar notas com prefixo `[Agente] Spit — ...` — contêm causas raiz de bugs
passados.

Ao acabar trabalho significativo, criar nota Kogno com:
- `source: "agent"`
- `project_name: "Spit"`
- Título: `[Agente] Spit — <assunto conciso>`
- Corpo: sintoma + causa raiz + fix (markdown conciso)

Verificar antes com `search` se já existe — não duplicar.

## Arquitectura JWT + Device ID — REGRAS CRÍTICAS (2026-04-29)

Estas regras custaram um dia de debugging. **Não violar sem ler a nota Kogno
"[Agente] Spit — Arquitectura JWT + Device ID (lições críticas)".**

### Dois JWTs em Keychain — sempre sincronizados

| Chave | Escrito por | Lido por |
|---|---|---|
| `spit-jwt` | `LicenseManager` (legacy) **e `AuthManager`** (sincronizado) | **Todos** os serviços proxy (transcribe, TTS, format, translate, vocab) |
| `spit-auth-jwt` | `AuthManager.handleDeepLink()` (magic-link) | Só `AuthManager` → `/auth/me` |

**Regra:** Sempre que `AuthManager` escrever `spit-auth-jwt`, tem de escrever
também em `spit-jwt`. Implementado em `handleDeepLink`, `logout`,
`refreshIfNeeded` e no `init` (migração). **Nunca remover esta sincronização.**

### X-Device-ID — sempre enviado, mesmo com JWT

```swift
// CORRECTO — sempre ambos em paralelo
request.setValue(LicenseManager.shared.deviceIdentifier(), forHTTPHeaderField: "X-Device-ID")
if let jwt = LicenseManager.shared.getJWT() {
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
}
```

JWTs de `/auth/magic/verify` não têm `device` claim. O proxy usa o header
`X-Device-ID` como fallback para auto-bind. Sem ele → 400 "missing device
identifier". Afecta `ProxyTranscriptionService` e `ProxyTTSService`.

### Proxy lê plano da DB, nunca do JWT

O JWT pode ter `plan=trial` stale. Em `handleTranscribe` e `handleTTS` do
Worker, o plano é sempre lido da DB: `plan = userRow.plan ?? claims.plan`.
**Nunca reverter para `claims.plan` como fonte de verdade de plano.**

### PRO_LIMIT_SECONDS=0 significa ilimitado

`PRO_LIMIT_SECONDS = "0"` no wrangler.toml → sem limite de transcrição Pro.
O check no Worker protege com `if (limitSecs > 0)` antes de comparar.
`0 >= 0 = true` bloquearia toda a gente — **nunca remover o guard.**

## Proibições

- **Nunca** mudar `bundle identifier` (`app.getspit`) — quebra Keychain e licenças.
- **Nunca** adicionar dependências de terceiros sem discutir primeiro. O projeto
  é deliberadamente zero-deps além do SDK Apple.
- **Nunca** commitar chaves, JWT, ou URLs de proxy com secrets hardcoded.
- **Nunca** desactivar `App Sandbox` em Release.
