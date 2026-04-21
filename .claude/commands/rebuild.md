---
description: Kill Spit, rebuild VoiceFlow em Debug, relançar o app
---

Executa a sequência de rebuild definida em `CLAUDE.md`:

1. Mata o processo Spit em execução (se houver)
2. Corre `xcodebuild` em Debug/macOS
3. Se o build falhar, mostra os últimos 40 linhas de erro e **pára** (não tenta relançar)
4. Se o build passar, abre o `.app` do DerivedData

Paths canónicos (não alterar):
- Projeto: `/Users/rafaellopes/projects/VoiceFlow`
- DerivedData app: `~/Library/Developer/Xcode/DerivedData/VoiceFlow-aolpcvsxnunafqfwlrkmiotqesgm/Build/Products/Debug/Spit.app`

Comando a correr (em bloco único):

```bash
kill $(pgrep Spit) 2>/dev/null
cd /Users/rafaellopes/projects/VoiceFlow && \
  xcodebuild -scheme VoiceFlow -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -40
```

Se aparecer `** BUILD SUCCEEDED **`, então:

```bash
open ~/Library/Developer/Xcode/DerivedData/VoiceFlow-aolpcvsxnunafqfwlrkmiotqesgm/Build/Products/Debug/Spit.app
```

Após relançar, ler os últimos 30 linhas do log para confirmar startup limpo:

```bash
tail -30 ~/Library/Containers/app.getspit/Data/tmp/spit-debug.log
```

Reportar ao utilizador:
- ✅ Build OK + app relançado → uma linha, sem verbosidade
- ❌ Build falhou → mostrar os erros com path:linha e sugerir fix
