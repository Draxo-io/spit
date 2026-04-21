# Spit — Especificação de Produto v1.0

> App macOS de ditado e leitura por voz. Menu bar app. Funciona com trial gerido por nós (cloud) ou com chave de API própria (BYOK). Motor de transcrição local disponível (offline, gratuito, ilimitado).

| | |
|---|---|
| **Versão da spec** | v1.2 |
| **Última revisão** | 2026-04-21 |
| **Estado geral** | Fase 1 + 2 completas · Fase 3 em curso |
| **Docs relacionados** | [`ARCHITECTURE.md`](ARCHITECTURE.md) · [`SPEC-AUTH.md`](SPEC-AUTH.md) · [`CHANGELOG.md`](CHANGELOG.md) |

Cada secção tem tag de estado: **✅** implementado · **🚧** parcial · **📋** planeado.

---

## 0. Glossário

| Termo | Significado |
|---|---|
| **AX** | Accessibility API do macOS — usada para detectar campo em foco e injectar texto directamente. |
| **BYOK** | Bring Your Own Key — modo em que o utilizador fornece a sua própria chave de API (OpenAI, Groq, Cartesia, etc.) em vez de usar o proxy da Spit. |
| **HUD** | Heads-Up Display — overlay flutuante sobre o ecrã (ex.: HUD de gravação, HUD de leitura, ReviewHUD). |
| **LED (icon)** | Indicador visual no ícone do menu bar — verde/amarelo/vermelho consoante o estado do serviço. |
| **LLM** | Large Language Model — usado para formatação (parágrafo automático, email) e tradução em alguns providers. |
| **PTT** | Push-to-Talk — manter a hotkey pressionada enquanto fala, largar para parar. |
| **Proxy** | Backend da Spit que reencaminha pedidos para Groq; usado em trial e pro plans. |
| **ReviewHUD** | Painel de revisão pós-transcrição — permite copiar, editar, ou corrigir vocabulário. |
| **STT** | Speech-to-Text — transcrição de voz para texto (Whisper). |
| **Toggle** | Premir a hotkey uma vez para começar, outra para parar (oposto de PTT). |
| **TTS** | Text-to-Speech — leitura de texto em voz alta. |
| **Whisper** | Modelo da OpenAI para STT. Também disponível via Groq e localmente via WhisperKit. |

---

## 1. Posicionamento ✅

- Beta UI
- Excelente usabilidade
- Custo atrativo
- Versão Privacidade (offline / não-cloud disponível)
- Made in EU
- Ditado e leitura num único app
- Compatibilidade máxima: OpenAI, Groq

---

## 2. Planos 🚧

| Plano | Preço | Notas |
|-------|-------|-------|
| Mensal | $4.99/mês | — |
| Bi-anual | $49 (até 3 meses) | Promoção de lançamento |
| Licença Lifetime (BYOK) | API US$ | Utilizador paga apenas a API diretamente |

---

## 3. Menu Bar — Logomarca da Spit 🚧

Popup principal do app, acessível pelo ícone na barra de menus do macOS.

### 3.1 Ícone na Barra de Menus

| Estado | Significado |
|--------|-------------|
| Ponto vermelho | Mensagem urgente pendente |
| Ponto amarelo | Aviso importante pendente |
| Sem ponto | Estado normal |

---

### 3.2 Área de Alertas

#### 🔴 Vermelho — Urgente
- **Trial expirado**: "Clique aqui para ativar sua conta" *(aparece se expirado)*
- **Trial não ativado**: "Ative sem trial agora, sem cartão de crédito" *(se o utilizador saltou o onboarding)*
- **Sem API de ditado configurada** *(só BYOK)*
- **Sem API de TTS configurada** *(só BYOK)*
- **Sem API de tradução configurada** *(só BYOK)*

#### 🟡 Amarelo — Aviso
- Trial a terminar em breve
- A processar / ocupado

---

### 3.3 LED de Status — Ditado 🎙

Estado exibido com ícone colorido + explicação textual curta.

| LED | Estado |
|-----|--------|
| 🟢 Verde | Pronto |
| 🟡 Amarelo | A processar |
| 🔴 Vermelho | Trial terminado / API Key inválida / API Key não configurada / Offline *(exceto se IA local ativa)* |

---

### 3.4 LED de Status — Leitura 🔊

| LED | Estado |
|-----|--------|
| 🟢 Verde | Pronto |
| 🟡 Amarelo | A reproduzir |
| 🔴 Vermelho | Trial terminado / API Key inválida / API Key não configurada / Offline |

---

### 3.5 Idiomas (Acesso Rápido)

#### Ditado
- Dropdown com todos os idiomas disponíveis. Default: idioma do sistema.
- Checkbox **"Tradutor automático"**: quando ativo, mostra `→` + segundo dropdown de idioma de destino. Default: inglês.
- *Sublabel compacto quando ativo: `PT → EN` (visível mesmo com secção colapsada)*

#### Leitura
- Dropdown com todos os idiomas disponíveis. Default: idioma do sistema.
- Checkbox **"Tradutor automático"**: mesma lógica do Ditado.
- *Sublabel compacto quando ativo: `PT → EN`*

---

### 3.6 Consumo

#### Se licença própria (BYOK):
- 🎙 `2.4k words = +45 min saved this month`
- 🔊 `~20 min`

#### Se trial ou plano mensal:
- `35 minutos restantes`

#### Preview do último texto
- 3 linhas de preview do último ditado.
- Clicável: copia o texto + feedback visual **"Copiado ✓"**

---

### 3.7 Último Ditado

- Preview de 3 linhas do texto mais recente.
- Clicável para copiar (com feedback "Copiado ✓").

---

## 4. Preferências (Settings) ✅

### 4.1 Geral ⚙️

#### Atalhos de Teclado

| Ação | Tecla padrão | Editar |
|------|-------------|--------|
| Ditado | `⌘ ⇧ D` | Botão Alterar |
| Leitura | `⌘ ⇧ L` | Botão Alterar |

> **Comportamento unificado (PTT + Toggle):** toque rápido (< 500 ms) = toggle de gravação; manter pressionado = PTT (grava enquanto a tecla estiver pressionada). Esta é a única opção disponível — explicada no Onboarding.

#### Interface
- **Idioma da interface**: Dropdown com todos os disponíveis. Default: idioma do OS.

---

### 4.2 Trial / Plano

#### Estado: Trial ativo
- `X min restantes`
- `Válido até DD/MM/AAAA` *(formatado conforme o idioma da interface)*
- Botão **Upgrade** → `getspit.app/account`

#### Estado: Plano Mensal ativo
- Label **Ativo**
- Link **Clique aqui para gerir** → `getspit.app/account`

#### Estado: Licença Vitalícia
- Data de aquisição: `DD/MM/AAAA`
- Nome completo do comprador
- Email do comprador

#### Estado: Expirado
- Label **Sem plano ativo**
- Botão **Ativar agora** → `getspit.app/account`

---

### 4.3 Comportamento

| Opção | Default |
|-------|---------|
| Mostrar painel de revisão após o ditado | ✅ Sim |
| Reproduzir som ao iniciar captura | ✅ Sim |
| Alertar quando não houver campo de texto ativo | ❌ Não |
| Interromper gravação em silêncio | ❌ Não |
| → Duração do silêncio para auto-stop | `2.0 s` *(visível apenas se ativo)* |

---

### 4.4 Ditado 🎙

#### Idioma
- Dropdown com todos os disponíveis. Default: idioma do sistema.
- Checkbox **"Tradutor automático"**: ativa segundo dropdown de destino. Default: inglês.
- *Sublabel quando ativo: `PT → EN`*

#### Formatação

- Checkbox **"Parágrafo automático"** *(default: ON)*
  - Pós-processa o texto transcrito com um LLM para inserir quebras de parágrafo semanticamente corretas
  - O LLM não altera palavras — apenas adiciona `\n\n` onde fizer sentido pelo conteúdo
  - Quando em contexto de email, o mesmo LLM aplica adicionalmente **formatação de email** *(ver abaixo)*
  - **Disponibilidade por plano** *(ver tabela na secção 4.7)*

##### Formatação de Email *(automática, sem configuração adicional)*

Ativada silenciosamente quando o app com foco for um cliente de email
*(Mail, Airmail, Spark, Mimestream, Superhuman — detetado via `bundleIdentifier`).*

O mesmo call LLM que faz os parágrafos trata também da saudação e despedida — sem regras manuais.

**Entrada de voz:**
> *"Olá Rafael bom dia fiquei sabendo de tal coisa espero notícias atenciosamente Rafael"*

**Saída formatada:**
```
Olá, Rafael,
Bom dia!

Fiquei sabendo de tal coisa. Espero notícias.

Atenciosamente,
Rafael
```

#### Outras configurações do API
*(expandível — ver secção 4.7)*

---

### 4.5 Leitura 🔊

#### Comportamento
- Toggle: **Mostrar painel de comandos** durante a reprodução

#### Idioma
- Dropdown com todos os disponíveis. Default: idioma do sistema.
- Checkbox **"Tradutor automático"**: segundo dropdown de destino. Default: inglês.
- *Sublabel quando ativo: `PT → EN`*

#### Outras configurações do API
*(expandível — ver secção 4.7)*

---

### 4.6 Vocabulário

#### Substituição
*Substitui palavras que o ditado reconhece incorretamente.*

- Botão **+ Novo** → campos `De:` / `Para:` → confirmar com `↵`
- Lista de substituições configuradas:
  - `[de]` → `[para]` — botão **Apagar**

#### Dicas
*Termos que o ditado deve reconhecer com mais facilidade (enviados como prompt ao modelo).*

- Botão **+ Novo** → campo `Termo:` → confirmar com `↵`
- Lista de termos:
  - `[termo]` — botão **Apagar**

---

### 4.7 APIs e Disponibilidade de Funcionalidades

#### Modelo de disponibilidade por plano

Cada funcionalidade depende de um serviço. Se o serviço não estiver configurado, a funcionalidade aparece **desativada com explicação** — nunca escondida.

| Funcionalidade | Trial / Mensal | BYOK — chave configurada | BYOK — chave em falta |
|---------------|---------------|--------------------------|----------------------|
| Ditado (cloud) | ✅ Incluído | ✅ Usa chave própria | 🔒 Desativado — *"Adiciona a tua chave de STT em APIs"* |
| Ditado (local) | ✅ Sempre disponível | ✅ Sempre disponível | ✅ Sempre disponível |
| Leitura / TTS | ✅ Incluído | ✅ Usa chave própria | 🔒 Desativado — *"Adiciona a tua chave de TTS em APIs"* |
| Tradução automática | ✅ Incluído | ✅ Usa chave própria | 🔒 Desativado — *"Adiciona a tua chave de Tradução em APIs"* |
| Parágrafo automático | ✅ Incluído | ✅ Reutiliza chave STT (OpenAI/Groq) ou chave LLM separada | 🔒 Desativado — *"Requer chave STT cloud ou chave LLM"* |

> **Nota sobre Parágrafo automático em BYOK:** se o serviço de ditado for OpenAI ou Groq, a mesma chave é reutilizada para o LLM de formatação (GPT-4o-mini / Llama). Zero configuração extra. Só precisa de chave separada se o ditado for local.

#### Comportamento de funcionalidade desativada

- O toggle/checkbox aparece visível mas **acinzentado e não interativo**
- Sublabel a cinzento: *"Requer [nome do serviço] — configura em APIs"*
- Clique no toggle → abre diretamente a secção APIs relevante (scroll + highlight)

---

#### Configuração de APIs *(secção visível apenas em plano BYOK)*

##### Ditado (STT)

| Campo | Tipo | Notas |
|-------|------|-------|
| Tipo de IA | Toggle **Cloud** / **Local** | Local = WhisperKit (offline, gratuito, ilimitado) |
| **▸ Se Cloud:** | | |
| Serviço | Dropdown | OpenAI Whisper, Groq, … |
| Modelo | Dropdown | Auto-populado: `whisper-1`, `whisper-large-v3-turbo`, … |
| API Key | Input mascarado | Botões: **Apagar**, **Testar** |
| **▸ Se Local:** | | |
| Modelo local | Dropdown | Tiny (75 MB) / Base (140 MB) / Small (466 MB) / Large Turbo (1.5 GB) |
| Estado | Label | "Descarregado" / "[X MB] — Descarregar" |

> Notificação do sistema ao terminar download: *"Modelo pronto — podes começar a ditar offline."*

---

##### Leitura / TTS

| Campo | Tipo | Notas |
|-------|------|-------|
| Serviço | Dropdown | Cartesia, OpenAI TTS, ElevenLabs, … |
| Modelo / Qualidade | Dropdown | Auto-populado: `sonic-2`, `sonic-2-mini`, `tts-1`, `tts-1-hd`, … |
| Voz | Dropdown | Vozes do serviço filtradas por idioma. Botão ▶ para preview. |
| Velocidade padrão | Segmented | `0.75×` · `1×` · `1.25×` · `1.5×` · `2×` |
| API Key | Input mascarado | Botões: **Apagar**, **Testar** |

---

##### Tradução

| Campo | Tipo | Notas |
|-------|------|-------|
| Serviço | Dropdown | DeepL, OpenAI, … |
| Modelo / Versão | Dropdown | Auto-populado: `deepl-pro`, `gpt-4o-mini`, … |
| Formalidade | Dropdown | Formal / Informal / Auto *(visível apenas com DeepL)* |
| API Key | Input mascarado | Botões: **Apagar**, **Testar** |

---

##### Formatação / LLM *(visível apenas se ditado for Local)*

| Campo | Tipo | Notas |
|-------|------|-------|
| Serviço | Dropdown | OpenAI, Groq, … |
| Modelo | Dropdown | `gpt-4o-mini`, `llama-3.1-8b-instant`, … |
| API Key | Input mascarado | Botões: **Apagar**, **Testar** |

> Se o ditado for Cloud (OpenAI ou Groq), esta secção não aparece — a chave STT é reutilizada automaticamente.

---

### 4.8 Sobre

- Logótipo / Logomarca
- Versão: `1.0.0 (build X)`
- Slogan
- [`getspit.app`](https://getspit.app)
- [Política de Privacidade](https://getspit.app/privacy)
- [Termos de Uso](https://getspit.app/terms)
- [Suporte](https://getspit.app/support)
- `© 2025 Spit — all rights reserved`

---

## 5. HUD de Ditado ✅

*Overlay flutuante exibido enquanto o app está a gravar.*

- Ícone animado (waveform) → a ouvir
- Barra de progresso de processamento
- Tempo decorrido (ex: `0:47`)
- **Alerta de áudio longo** *(aparece ao atingir 2 minutos)*:
  > *"Áudio longo — termine este e comece um novo para melhor resultado"*

---

## 6. HUD de Leitura ✅

*Overlay flutuante exibido enquanto o app está a reproduzir.*

- Ícone animado de reprodução
- Botão **Pausar**
- Botão **Parar**
- Controlo de velocidade: `0.75×` · `1×` · `1.25×` · `1.5×` · `2×`

---

## 7. Painel de Confirmação de Ditado ✅

*Painel sobreposto ao ecrã, exibido após a transcrição ser concluída.*

### Conteúdo

| Elemento | Detalhe |
|----------|---------|
| Header | **"Spit — Transcrição"** |
| Duração | `Xs` ou `X min Xs` |
| Botão fechar | ✕ |
| Texto transcrito | Texto completo. Substituições automáticas **a vermelho e clicáveis** |
| Botão copiar | Copia o texto para o clipboard |

### Substituições clicáveis
- Clicar numa substituição vermelha → abre popover de edição
- Se confirmada → adicionada automaticamente à lista em **Vocabulário → Substituição**
- Popover fecha após **5 s sem interação**

### Timeout do painel
- Fecha automaticamente após **5 s**
- **O contador reinicia a cada interação do utilizador com o painel** (clicar, selecionar texto, editar substituição)

---

## 8. Onboarding ✅

*Sequência exibida na primeira abertura do app.*

### Ecrã 1 — Boas-vindas
> *"O ditado mais rápido do Mac."*

- CTA: **Continuar**

### Ecrã 2 — Permissão de Microfone
- Explicação de 1 linha
- Pedido nativo macOS
- CTA: **Conceder acesso** / **Continuar** (se já concedido)

### Ecrã 3 — Permissão de Acessibilidade
> *"Para inserir texto onde quer que estejas a escrever."*

- Abre Preferências do Sistema automaticamente
- CTA: **Continuar**

### Ecrã 4 — Ativar Trial
- Campo: email
- CTA: **Enviar link mágico**
- Estado pós-envio: *"Confirma o teu email — verifica a caixa de [email]"*
- Ao clicar no link → app reabre → animação ✓ → **"60 min ativados"**

### Ecrã 5 — O teu Atalho
- Mostra atalho padrão (ex: `⌘ ⇧ D`)
- Texto:
  > *"Toque rápido para gravar. Mantém pressionado para falar enquanto seguras a tecla."*
- Link: Alterar nas Preferências
- CTA: **Continuar**

### Ecrã 6 — Primeiro Ditado
- *"Experimenta agora — dita algo"*
- Inicia gravação diretamente

### Ecrã 7 — Pronto
- `X min usados — ficam Y min de trial`
- CTA: **Começar**

---

## 9. Regras de Negócio e Notas de Implementação ✅

### Motor Local (WhisperKit)
- Não consome minutos de trial
- Não requer internet
- O alerta de **Offline** não se aplica quando `transcriptionEngine == .local`

### Alerta Offline
- Ícone de status fica 🔴 quando sem internet
- **Excepção**: se o motor de transcrição for local (`transcriptionEngine == .local`), o ícone mantém 🟢

### Hotkey unificada (PTT + Toggle)
- Comportamento padrão, não configurável
- Toque < 500 ms = toggle de gravação
- Manter pressionado = PTT (grava enquanto a tecla estiver pressionada)
- Explicado no Onboarding (Ecrã 5)

### Notificação de Modelo Local
- Quando o modelo é descarregado e fica pronto: notificação do sistema
  > *"Modelo [nome] pronto — podes começar a ditar offline."*

### URLs de Produção
| Destino | URL |
|---------|-----|
| Conta / Upgrade | `getspit.app/account` |
| Gestão de plano | `getspit.app/account` |
| Site | `getspit.app` |
| Privacidade | `getspit.app/privacy` |
| Termos | `getspit.app/terms` |
| Suporte | `getspit.app/support` |

---

## 10. Plano de Implementação

> **Status actual (2026-04-21):** Fase 1 ✅ · Fase 2 ✅ · Fase 3 🚧 · Fase 4 📋

### Fase 1 — Pré-lançamento *(sem isto não vende)*
1. **Onboarding** — substituir fluxo atual (API key) pelo novo de 7 passos com magic link
2. **Hotkey PTT + Toggle** — comportamento unificado < 500 ms
3. **Menu bar — alertas BYOK** — banners para serviços não configurados; LEDs separados para Ditado e Leitura
4. **Settings — estados de plano** — trial / mensal / licença vitalícia / expirado

### Fase 2 — Polimento v1.0
5. **HUD de Leitura** — pause / stop / controlo de velocidade
6. **Alerta de áudio longo** — banner no HUD ao atingir 2 min
7. **ReviewHUD** — timeout com reset por interação + substituições clicáveis em vermelho
8. **NetworkMonitor** — deteção de offline + LED de status

### Fase 3 — Feature complete
9. **Parágrafo automático** — pós-processamento LLM com reutilização de chave STT
10. **Idiomas na popup** — dropdowns de acesso rápido + sublabel `PT → EN`
11. **APIs BYOK expandidas** — modelo, voz, formalidade, chave LLM separada (se local)
12. **TranslationService** — integração DeepL / OpenAI
13. **Secção Sobre** — links e versão dinâmica

### Fase 4 — Design de produção *(última etapa)*
14. **Protótipo visual das telas principais** — gerado com skill especializada de frontend design (`/frontend-design`), cobrindo: popup do menu bar, Settings, Onboarding, HUD de ditado, HUD de leitura, painel de confirmação. Serve de referência visual para refinar o SwiftUI com qualidade de produto comercial.
