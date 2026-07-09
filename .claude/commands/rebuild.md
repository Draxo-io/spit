---
description: Kill Spit, rebuild VoiceFlow em Debug, relançar o app
---

Executa a sequência de rebuild definida em `CLAUDE.md`:

1. Mata **só a build de dev** (Spit Dev, bundle `app.getspit.dev`) — nunca a produção
2. Corre `xcodebuild` em Debug/macOS
3. Se o build falhar, mostra os últimos 40 linhas de erro e **pára** (não tenta relançar)
4. Se o build passar, abre o `.app` do DerivedData

> **A build de Debug é a "Spit Dev"** — bundle `app.getspit.dev`, ícone de martelo 🔨
> na barra, hotkey ⌥ Option direito (keyCode 61). Coexiste com a produção
> (`app.getspit`, Globe). São apps distintas: container, definições, logs e
> hotkey totalmente isolados. Por isso o kill tem de ser **específico da Dev**
> (por path do DerivedData), senão mata a produção do utilizador.

Paths canónicos (não alterar):
- Projeto: `/Users/rafaellopes/Library/CloudStorage/GoogleDrive-rafa@rafamail.com/Meu Drive/Empreendedorismo/Spit`
- DerivedData app (Dev): `~/Library/Developer/Xcode/DerivedData/VoiceFlow-hfayfoyiaxzwzjdermhtiguqxtnn/Build/Products/Debug/Spit Dev.app`
- Log da Dev: `~/Library/Containers/app.getspit.dev/Data/Library/Logs/Spit/spit-debug.log`

Comando a correr (em bloco único):

```bash
pkill -f "DerivedData/VoiceFlow-hfayfoyiaxzwzjdermhtiguqxtnn/Build/Products/Debug/Spit Dev.app" 2>/dev/null
cd "/Users/rafaellopes/Library/CloudStorage/GoogleDrive-rafa@rafamail.com/Meu Drive/Empreendedorismo/Spit" && \
  xcodebuild -project VoiceFlow.xcodeproj -scheme VoiceFlow -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -40
```

Se aparecer `** BUILD SUCCEEDED **`, então:

```bash
open "$HOME/Library/Developer/Xcode/DerivedData/VoiceFlow-hfayfoyiaxzwzjdermhtiguqxtnn/Build/Products/Debug/Spit Dev.app"
```

Após relançar, ler os últimos 30 linhas do log da Dev para confirmar startup limpo:

```bash
tail -30 ~/Library/Containers/app.getspit.dev/Data/Library/Logs/Spit/spit-debug.log
```

Reportar ao utilizador:
- ✅ Build OK + app relançado → uma linha, sem verbosidade
- ❌ Build falhou → mostrar os erros com path:linha e sugerir fix
