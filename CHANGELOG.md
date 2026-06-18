# Spit — Changelog de bugs e lições

Histórico de bugs corrigidos neste projeto. Cada entrada tem: **sintoma**, **causa raiz**, **fix**, **commit/data**.

Este ficheiro **não é** um changelog de features — para isso usa-se o git log. Aqui ficam **só lições** que valem a pena consultar antes de mexer em áreas sensíveis.

Ordem: mais recente em cima.

---

## 2026-04-29 — Ditado longo (>90s) falhava silenciosamente, texto perdido

**Ficheiros**: `Controllers/DictationController.swift`, `UI/HUDCoordinator.swift`, `UI/RecordingHUDView.swift`

**Sintoma**: Utilizador gravou ~147 segundos de ditado. O sistema não transcreveu, não injectou o texto, e não mostrou qualquer erro. O texto ficou perdido sem aviso.

**Causa raiz dupla**:

1. **Groq rejeita áudio > ~90-120s**: A API Whisper do Groq retornou erro imediatamente (5s após o pedido, antes de qualquer processamento real). O ficheiro M4A tinha ~2MB — bem abaixo do limite de 25MB — mas o Groq tem um limite prático de duração. O aviso visual aparecia aos 120s mas não forçava paragem.

2. **`mode:off` silenciava também os erros**: `HUDCoordinator.dictationCompleted` com `mode:.off` definia `shouldShow = false` incondicionalmente — incluindo para `outcome:error`. O utilizador não viu nada. `storePendingRetry` foi chamado (o áudio estava guardado 10 min para retry), mas o ReviewHUD com o botão Retry nunca apareceu.

**Fix em três camadas**:

1. `HUDCoordinator`: `case .off: shouldShow = isFailure` — erros sempre visíveis mesmo com o painel desligado.
2. `DictationController`: auto-stop task que dispara aos 90s — chama `stopDictation()` automaticamente. Cancela-se se o utilizador parar antes.
3. `RecordingHUDView`: `longThreshold` baixado de 120s para 60s, com aviso actualizado ("para em 90s o sistema começa automaticamente").

**Lição**: `mode:off` é uma preferência de UX para resultados normais, não um silenciador de falhas. Qualquer outcome de erro deve sempre chegar ao utilizador, independentemente do modo. Além disso, qualquer limite de API de terceiros deve ter um auto-stop client-side com margem de segurança.

---

## 2026-04-27 — Media keys não pausavam Chrome / web players (2 problemas)

**Ficheiros**: `Services/SystemAudioManager.swift`

**Sintoma**: Iniciar ditado com Google Music a tocar no Chrome não pausava
a música. Spotify desktop e Apple Music sempre funcionaram.

**Causa raiz dupla**:

1. **Routing da media key**: `sendPlayPauseKey()` injectava o NSEvent via
   `cgEvent.post(tap: .cgSessionEventTap)`. Chrome/browsers/web players só
   escutam ao nível HID (onde a tecla física F8 chega). `cgSessionEventTap`
   é entregue acima e estes apps não o vêem.

2. **Guard `PID = 0` bloqueava antes de chegar à key**: Chrome com Google
   Music não regista no `MRMediaRemoteGetNowPlayingApplicationPID` — PID
   sempre 0 → guard fazia `skip` → key nunca era enviada. A fix do tap
   sozinho era irrelevante.

**Fix em duas camadas**:

1. Trocar `.cgSessionEventTap` → `.cghidEventTap`. Replica exactamente o
   caminho da tecla física para que Chrome/browsers vejam o evento.

2. Quando `PID = 0`, fallback via Core Audio:
   `kAudioDevicePropertyDeviceIsRunningSomewhere` no default output device.
   Se há áudio a sair, é seguro pausar (já há um app a tocar — não vamos
   abrir Apple Music). Se silencioso, manter o skip.

Ordem de decisão actual:
- PID > 0 → pausar (caminho rápido e fiável)
- PID = 0 + output activo → pausar (cobre Chrome/web players)
- PID = 0 + output silencioso → skip (preserva fix anti-Apple-Music)

---

## 2026-04-22 — Alinhamento extenso com SPEC §3.6 · §4.1 · §7 · §8 (Histórico) · §4.7

**Ficheiros**: `Models/AppState.swift`, `Managers/CreditsManager.swift`, `Controllers/DictationController.swift`, `Services/TTSService.swift`, `UI/MenuBarPopoverView.swift`, `UI/SettingsView.swift`, `UI/AboutView.swift`, `SPEC.md`

**Contexto**: Auditoria minuciosa SPEC ↔ código revelou múltiplas divergências silenciosas. O utilizador tinha reescrito §3.6 Consumo e §4.2 Plano para definir 4 estados (BYOK / Trial ativo / Pro mensal / Trial expirado / Trial não iniciado) com rows 🎙 ditado + 🔊 leitura. O código mostrava apenas uma linha genérica, sem contador de TTS, sem CTA "Ative agora" para Trial não iniciado, e sem o CTA "Conheça os planos" literal.

**Mudanças**:

1. **CreditsManager** — adicionados counters `totalSecondsRead` / `monthlySecondsRead` + `recordTTS(seconds:)` + `recordTranscription(seconds:)` (este último estava a ser lido mas nunca escrito). Reset mensal com mesmo padrão YYYY-MM.
2. **TTSService** — regista `playbackStartedAt` no início de AI/native playback e chama `recordTTS(seconds:)` em `onAIPlaybackFinished` + `speechSynthesizer didFinish`. Aborts < 0.5s ignorados.
3. **DictationController** — `processRecording` agora chama `CreditsManager.recordTranscription(seconds:)` a seguir a `HistoryManager.add`.
4. **MenuBarPopoverView** — refactor completo do `creditsView` num state-machine de 5 estados (`ConsumoState`); `freeTrialCTAView` agora cobre `trialExpired` ("Conheça os planos") e `trialNotStarted` ("Ative agora" → `OnboardingWindowController.shared.show()`).
5. **SettingsView** — nova tab `Histórico` (SPEC-AUTH §9 posição 8) com lista dos 50 últimos ditados, copiar/apagar individual, botão limpar tudo.
6. **AppState** — `launchAtLogin` default `true` (SPEC §4.1) · `reviewHUDInitialSeconds` `10 → 5` (SPEC §7) · schema version bumped to v2.
7. **AboutView** — `© 2025` → `© 2026`.
8. **Localização** — banner de acessibilidade, `"Press shortcut…"`, `"Add a modifier…"`, tooltips Settings/Quit migrados para `String(localized:)`.

**Decisões registadas na SPEC**:
- Ícones 🎙 / 🔊 mantidos como SF Symbols (`mic.fill` / `speaker.wave.2.fill`) em vez de emojis literais — consistência com macOS. Documentado em §3.6.
- Separador `→` em vez de `=` na linha de value summary.
- Linha "trial termina em DD/MM" omitida até backend passar a devolver `trial_end_date` / `pro_renewal_date`. Linha marcada como pendente na spec.
- Limite de TTS para "minutos de leitura restantes": usa o mesmo cap do ditado (trial 60min, Pro 20h) enquanto backend não define quota dedicada.
- §4.2 Plano (SettingsView) mantém UI mais rica que a spec literal (progress bar) — spec atualizada para reflectir.

**Regra acrescentada ao `CLAUDE.md`**: qualquer spec nova ou alterada exige agora parar, avisar, pedir autorização, actualizar o `.md` **antes** do código. Evita alinhamentos silenciosos.

---

## 2026-04-22 — TextFormattingService aceitava truncagens do LLM como formatação

**Ficheiros**: `Services/TextFormattingService.swift`

**Sintoma**: Utilizador ditou um pedido de ~70 palavras começando por "ajude-me a montar texto super simples para eu colar na mensagem do WhatsApp..." com um template de duas linhas no fim. O "Texto final" no ReviewHUD veio com **apenas 16 palavras** — o template sem o pedido de ajuda.

**Causa raiz**: O LLM do proxy `/format` interpretou o texto como **instrução para si próprio** ("ajude-me a montar…") em vez de o formatar. Devolveu só o template final, descartando o contexto.

O `isSuspiciousOutput` tinha dois gates — (1) char ratio > 2.5× e (2) word count > input+3 — ambos focados em **expansão/alucinação**. Nenhum apanhava **truncamento**.

**Fix**: Adicionado terceiro gate — rejeita output com < 70% das palavras do input (só para inputs ≥ 10 palavras, para evitar falsos positivos em frases curtas). Neste caso 16/70 = 23% → rejeitado → `DictationController` usa o texto original do Whisper.

**Lição**: Gates anti-alucinação têm de ser **bi-direccionais** (expansão e contracção). Qualquer operação de "formatar / limpar / estruturar" LLM tem risco do modelo interpretar o input como prompt. Replicar este gate no `TranslationService` também (onde apenas temos gate de expansão 1.8×).

---

## 2026-04-21 — TranslationService aceitava alucinações do LLM como tradução

**Ficheiros**: `Services/TranslationService.swift`

**Sintoma**: Utilizador ditou "faz resumo das minhas acções, qual o preço médio…" (Português, 187 chars). O ReviewHUD mostrou "Traduzido:" com um resumo fabricado com números inventados (R$ 10.000,00, R$ 20.000,00, 100 acções — nada disto estava no áudio). Output veio em Português apesar do target ser `en`.

**Causa raiz**: O LLM do proxy `/translate` (Groq/servidor) por vezes ignora a instrução de tradução e interpreta o texto como **prompt**, gerando uma resposta. O cliente (`TranslationService.swift`) não tinha qualquer validação — aceitava qualquer string não-vazia como tradução válida.

Contraste: `TextFormattingService` já tinha guard de comprimento (rejeitou o seu próprio output de 550 chars neste mesmo ciclo — ver log), mas o padrão não tinha sido replicado no `TranslationService`.

**Fix**: Novo método `isPlausibleTranslation(source:translated:target:)` com dois guards:
1. **Length guard**: rejeita se `output.length / source.length > 1.8`. Traduções legítimas entre línguas Latinas raramente passam de 1.5×.
2. **Language guard**: `NLLanguageRecognizer` confirma que o output está na língua-alvo (confiança ≥ 0.75). Se detecta outra língua com alta confiança, rejeita.

Quando qualquer guard falha, `translate()` retorna `nil`. O `DictationController` trata isto como "serviço indisponível" — cola o texto original e mostra banner "Translation service unavailable" no ReviewHUD.

**Lição**: Qualquer chamada a LLM pode resultar em alucinação. Sempre validar o output do lado do cliente:
- Comprimento (output não deveria ser muito maior que input para tradução/formatação)
- Língua (para tradução)
- Conteúdo (para formatação: não pode introduzir factos novos)

Seguir o padrão do `TextFormattingService` quando se adicionar qualquer novo serviço baseado em LLM.

---

## 2026-04-21 — Globe abria Apple Music quando nada estava a tocar

**Ficheiros**: `Services/SystemAudioManager.swift`

**Sintoma**: Pressionar o Globe (🌐) para iniciar ditado lançava o Apple Music, mesmo sem nenhuma música a tocar.

**Causa raiz**: `SystemAudioManager.pauseMedia()` enviava sempre o sinal `NX_KEYTYPE_PLAY` (keyCode 16) via `NSEvent.otherEvent`. Quando nenhum app está registado como now-playing, o macOS captura a key e redirecciona-a para o app por defeito — o Apple Music — lançando-o.

O check anterior usava `MRMediaRemoteGetNowPlayingApplicationIsPlaying`, mas esse API **mente em Bluetooth HFP** (retorna `false` mesmo com música a tocar), o que nos forçou a removê-lo num commit anterior — reintroduzindo o bug de lançar o Music.

**Fix**: Usar `MRMediaRemoteGetNowPlayingApplicationPID` (também privado, MediaRemote framework). Retorna o PID do app registado como media controller ou `0` se não houver nenhum. **Este valor é fiável mesmo em Bluetooth.**

- PID = 0 → não enviar a key, skip pause.
- PID > 0 → enviar a key normalmente.

Timeout de 800ms na chamada assíncrona, igual ao antigo.

**Commit**: pendente de commit na data deste registo.

---

## 2026-04-21 — Crash `EXC_CRASH SIGABRT` em `installTapOnBus` após `setDeviceID`

**Ficheiros**: `Services/AudioRecorder.swift`

**Sintoma**: App crashava ~1s depois de iniciar ditado (antes do HUD aparecer). Diagnostic report mostrava `Exception Type: EXC_CRASH (SIGABRT)` com `Crashed Thread` a chamar `AVAudioIONodeImpl::InstallTap` via `handleEngineConfigChange → setupAndStartEngine`.

**Causa raiz**: Tentativa de forçar o built-in mic em cenário Bluetooth HFP. O código chamava `AUAudioUnit.setDeviceID()` no input node, que **dispara `AVAudioEngineConfigurationChange`** como notificação. O handler dessa notificação chamava `setupAndStartEngine()`, que por sua vez chama `installTap(onBus:...)` **num engine que já tinha um tap instalado ou estava em estado inconsistente** → crash.

**Fix**: Remover por completo (a) a tentativa de forçar built-in mic (`setDeviceID`, `findBuiltInInputDevice`, `forceBuiltInMicIfAvailable`) e (b) o observer de `AVAudioEngineConfigurationChange`. O `AVAudioEngine` já se adapta automaticamente a mudanças de device — não precisa de intervenção manual.

**Regra derivada** (ver `CLAUDE.md`): em Bluetooth HFP o sample rate do mic cai para 8-16 kHz, mas funciona. Não tentar forçar built-in mic.

**Commit**: rework completo do `AudioRecorder.swift` na mesma data.

---

## 2026-04-21 — `isMediaPlaying()` retornava false com música a tocar em Bluetooth

**Ficheiros**: `Services/SystemAudioManager.swift`

**Sintoma**: Com headphones Bluetooth, premir a hotkey não pausava a música. Log mostrava `SystemAudioManager — nada a tocar, skip pause`.

**Causa raiz**: `MRMediaRemoteGetNowPlayingApplicationIsPlaying` (MediaRemote privado) retorna `false` em cenários Bluetooth mesmo quando há áudio activo. É bug documentado no framework privado.

**Fix**: Removido o gate por `isPlaying`. `pauseMedia()` passou a enviar sempre a play/pause key. Isto introduziu **outro bug** (abrir Apple Music — ver entrada 2026-04-21 acima), que foi resolvido depois com `MRMediaRemoteGetNowPlayingApplicationPID`.

**Lição**: APIs privadas da Apple mentem em cenários específicos (BT, AirPlay). Sempre testar com setup real antes de confiar.

---

## 2026-04-21 — `resumeMedia()` chamado antes de `stopRecording` deixava burst de áudio no output

**Ficheiros**: `Controllers/DictationController.swift`

**Sintoma**: O final do ficheiro de áudio transcrito incluía fragmento da música, que o Whisper transcrevia como ruído/letras.

**Causa raiz**: `stopDictation()` chamava `SystemAudioManager.resumeMedia()` **antes** de `audioRecorder.stopRecording()`. A música retomava, entrava no mic, e era capturada nos últimos ~200ms de buffer antes do tap ser removido.

**Fix**: Mover `resumeMedia()` para **depois** de `stopRecording()` — só retomar quando o tap já não está activo.

---

## Template para novas entradas

Copiar este bloco quando adicionares uma entrada nova:

```markdown
## YYYY-MM-DD — <título curto do bug>

**Ficheiros**: `path/Ficheiro.swift`

**Sintoma**: O que o utilizador via.

**Causa raiz**: Porque acontecia. Ser específico — não "race condition" genérico.

**Fix**: O que foi mudado, em 1-2 frases.

**Commit**: `abc1234` (ou "pendente").

**Lição** (opcional): Regra geral derivada, se aplicável.
```

## Como usar este ficheiro

- **Antes de mexer em `AudioRecorder`, `SystemAudioManager`, `HotkeyManager`, ou `DictationController`** — faz `grep` neste ficheiro pelo nome do ficheiro. Se houver entradas, lê-as todas primeiro.
- **Ao propor um fix** — verificar se o mesmo bug (ou relacionado) já foi "resolvido" antes. Se sim, a solução anterior provavelmente introduziu este novo sintoma — pensar numa abordagem diferente.
- **Ao fechar um bug** — adicionar entrada aqui **antes** do commit. O commit message deve referenciar `CHANGELOG.md`.
