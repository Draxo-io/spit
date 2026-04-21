# Spit — Changelog de bugs e lições

Histórico de bugs corrigidos neste projeto. Cada entrada tem: **sintoma**, **causa raiz**, **fix**, **commit/data**.

Este ficheiro **não é** um changelog de features — para isso usa-se o git log. Aqui ficam **só lições** que valem a pena consultar antes de mexer em áreas sensíveis.

Ordem: mais recente em cima.

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
