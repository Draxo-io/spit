# Spit — Especificação de Produto v1.0

> App macOS de ditado e leitura por voz. Menu bar app. Distribuição exclusiva pela Mac App Store; monetização via In-App Purchase (StoreKit 2). Dois produtos: **Pro** (subscrição mensal, usa o proxy cloud) e **BYOK** (compra única vitalícia, chave própria do utilizador, sem proxy).

| | |
|---|---|
| **Versão da spec** | v1.4 |
| **Última revisão** | 2026-05-25 |
| **Estado geral** | Fase 1 + 2 ✅ · Fase 3 🚧 (9, 10 ✅; 11 a confirmar; 12 adiado pós-launch; 13 pendente) · Fase 4 📋 |
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
- Versão Privacidade opcional (offline / não-cloud disponível)
- Made in EU
- Ditado e leitura num único app
- Compatibilidade máxima: OpenAI, Groq

---

## 2. Planos 🚧

> **Distribuição e pagamento (v1.4, 2026-05-25):** exclusivamente Mac App Store, via
> In-App Purchase (StoreKit 2). **Não há** trial anónimo por device, magic-link, nem
> checkout externo (Lemon Squeezy descontinuado — sem utilizadores legados). O período
> grátis é o *introductory offer* da subscrição, gerido pela Apple.

| Produto | ID StoreKit | Tipo | Preço | Usa proxy? | Validação |
|---------|-------------|------|-------|-----------|-----------|
| **Pro** | `app.getspit.pro.monthly` | Auto-renovável + introductory offer | €4.90/mês | ✅ Sim (cloud) | Backend (App Store Server API) → `plan='pro'` + `pro_expires_at` no D1 |
| **BYOK** | `app.getspit.byok.lifetime` | Non-consumable (compra única) | $49 | ❌ Não | 100% local (`Transaction.currentEntitlements`) — desbloqueia o uso da chave própria |

Notas:
- **Pro** dá ditado e leitura ilimitados via proxy do Spit (limites em `wrangler.toml`:
  `PRO_LIMIT_SECONDS=0` = transcrição ilimitada; `PRO_TTS_CHARS` para TTS). A fonte de
  verdade do plano é sempre o D1 (`users.plan` + `pro_expires_at`), nunca o JWT.
- **BYOK** não toca no backend: a app valida a compra non-consumable via StoreKit e
  passa a usar a chave OpenAI/Groq do utilizador diretamente (áudio nunca passa pelo
  proxy). Por isso a licença vitalícia não tem custo recorrente para o Spit.
- Preços finais seguem o *price tier* da App Store (a Apple localiza por moeda).

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

### 3.3 LED de Status — Ditado 🎙

Estado exibido com ícone colorido + explicação textual curta.

| LED | Estado |
|-----|--------|
| 🟢 Verde | Pronto |
| 🔴 Vermelho | Trial não iniciado / Trial terminado (valiade)/ API Key inválida / API Key não configurada / Offline *(exceto se IA local ativa)* |

---

### 3.4 LED de Status — Leitura 🔊

| LED | Estado |
|-----|--------|
| 🟢 Verde | Pronto |
| 🟡 Amarelo | A reproduzir |
| 🔴 Vermelho | Trail não iniciado / Trial terminado (valiade ou limite atingido 60min)/ API Key inválida / API Key não configurada / Offline *(exceto se IA local ativa)*|

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

### 3.6 Layout do Popover

O popover divide-se em **dois blocos** separados por um divider, cada um com título em caps pequenos:

#### Bloco DIGITAÇÃO
1. Título `DIGITAÇÃO` (9px, semibold, secondary)
2. Linha de controlo: LED estado · seletor de idioma · toggle Traduzir (ou privacy pill)
3. Linha de stats (ver §3.6.1)
4. Se houver ditado recente (< 5 min): título `Última digitação` + preview de 3 linhas clicável para copiar

#### Bloco LEITURA
1. Título `LEITURA` (9px, semibold, secondary)
2. Linha de controlo: LED estado · seletor de idioma · toggle Traduzir (ou privacy pill)
3. Linha de stats (ver §3.6.1)

---

### 3.6.1 Stats por plano

> **Nota**: todos os valores são aproximações — usam `~` como prefixo sem exceção.
> Os ícones 🎙 e 🔊 são SF Symbols (`mic.fill` / `speaker.wave.2.fill`).

#### Se licença própria (BYOK):
- 🎙 `~2.4k words → ~45 min saved this month` + custo estimado (`$0.xx`)
- 🔊 `~20 min` *(minutos de leitura consumidos este mês)*

#### Se trial ou plano mensal:
- 🎙 `~2.4k words → ~45 min saved this month`
- 🔊 `~35 min restantes`

#### Se trial expirou:
- 🎙 `~2.4k words → ~45 min saved` *(histórico lifetime)*
- 🔊 `~35 min utilizados`
- CTA: **"Conheça os planos"** → abre Preferências → aba Plano

#### Se trial não foi ativo:
- Stats omitidas — apenas CTA: **"Ative agora"** → abre onboarding

#### Limite de TTS (🔊 restantes)
Enquanto o backend não definir quota própria de TTS, o cliente usa o mesmo
cap do ditado como proxy:
- Trial: 60 min
- Pro mensal: 20 h
A linha `~X min restantes` é calculada localmente a partir de
`CreditsManager.monthlySecondsRead` (atualizado em cada leitura
concluída por `TTSService`).

---

### 3.7 Último Ditado

- Preview de 3 linhas do texto mais recente, dentro do **bloco DIGITAÇÃO**.
- Precedido por título pequeno "Última digitação".
- Clicável para copiar (com feedback "Copiado ✓").
- Desaparece depois de 5 minutos (SPEC §3.7).

---

## 4. Preferências (Settings) ✅

### 4.1 Geral ⚙️

#### Atalhos de Teclado

| Ação | Tecla de ação | Editar |
|------|-------------|--------|
| Ditado/Leitura | `🌐` | Botão Alterar |

> **Comportamento unificado (PTT + Toggle):** toque rápido (< 500 ms) = toggle de gravação; manter pressionado = PTT (grava enquanto a tecla estiver pressionada). Esta é a única opção disponível — explicada no Onboarding.

#### Interface
- **Idioma da interface**: Dropdown com todos os disponíveis. Default: idioma do OS.

#### Sistema
- **Iniciar com o Mac**: Default: Sim.
- **Som de feedback ao iniciar/terminar gravação**: Default: Sim.
- **Pausar reprodução ao ditar/ler**: Default: Sim.
---

### 4.2 Plano

> **Nota de implementação**: a tab Plano mostra uma visualização mais
> rica do que a popover §3.6 — inclui **progress bar** do uso (minutos do
> trial ou horas do Pro mensal), cartão do plano ativo, e CTA de upgrade.
> Os campos abaixo que dependem de dados ainda não disponibilizados pelo
> backend estão marcados como pendentes.

#### Plano atual: <nome do plano atual> (Trial / Pro Mensal / Lifetime)
##### Se Lifetime (BYOK):
- *~~Data de aquisição: DD/MM/AAAA~~* — **pendente backend**
- *~~Nome completo do comprador~~* — **pendente backend**
- *~~Email do comprador~~* — parcialmente disponível via `LicenseManager.userEmail`
- 🎙 `~2.4k words → ~45 min saved this month`
- 🔊 `~20 min` *(leitura consumida este mês)*

##### Se trial ou plano mensal:
- Progress bar com minutos/horas usados vs. limite
- 🎙 `~2.4k words → ~45 min saved this month`
- 🔊 `~35 min restantes`

##### Se trial expirou:
- 🎙 `~2.4k words → ~45 min saved` *(lifetime)*
- 🔊 `~35 min utilizados`

- Botão **Mudar de plano** → `getspit.app/account`
- Link **Clique aqui para gerir** → `getspit.app/account`

### 4.3 Já compraste? (só quando o usuário não estiver autenticado)
**Login para ativar**

### 4.4 Desativar este dispositivo
**Logout**

---

### 4.3 Ditado 🎙
- HUD: Durante o ditado um pequeno HUD mostra de forma animada quando a captura de voz está sendo capturada, depois está em processamento. Dentro desse mesmo HUD, utilizando o modelo de transcrição offline mostra uma prévia da transcrição em tempo real só para exemplificar o que está acontecendo. Essa transcrição não precisa ser armazenada, pois não terá uso prático


#### 4.3.1 Comportamento
Painel e revisão: Desligado / Sempre / Inteligente (padrão)


#### 4.3.2 Aprimoramento do texto
| Opção | Default |
|-------|---------|
| Paragrafo automático | ✅ Sim |
  - Pós-processa o texto transcrito com um LLM para inserir quebras de parágrafo semanticamente corretas
  - O LLM não altera palavras — apenas adiciona `\n\n` onde fizer sentido pelo conteúdo
  - Quando em contexto de email, o mesmo LLM aplica adicionalmente **formatação de email** *(ver abaixo)*
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
---

### 4.4 Leitura 🔊

#### Leitura por você
- Toggle: Ativa leitura por voz (padrão ativo)

#### Voz
- o usuário pode substituir a voz do modelo em um dropdown list

### 4.5 Privacidade

#### Modo privaciade
- Toggle: processa tudo localmente (por padrão desativado)
Ao ativar essa função, o sistema para e utilizar os modelos cloude e passa a utilizar os recursos nativos de ditado e leitura da Apple locais, bem como não utilizada nenhum modelo para realizar o pós-processamento.
Ao desativar, a configuração deve voltar exatamente como está antes.

#### Contribuição
- Toggle: partilhar preferências, configurações e estatísticas de uso para melhorar guiar a evolução do produto

### 4.6 APIs *(visível apenas para plano Lifetime/BYOK)*
- Tab só aparece quando o plano é BYOK. Trial e Pro não vêem esta tab (vêem Privacidade em vez disso).
- As api keys não podem ser visualizadas após salvas — guardadas no Keychain do sistema.

#### Ditado
- Seletor do motor (IA) - OpenAI/Groq/Local (MacOS)
- api key

#### Leitura - OpenAI/Local (macOS)
- Seletor do motor: OpenAI / Local (macOS)
- api key (apenas quando OpenAI; Local usa vozes nativas, sem chave)

#### Tradução e pós-tratamento
- Seletor do motor (IA)
- api key
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

### 4.7 Sobre
- Logótipo / Logomarca
- Versão: `1.0.0 (build X)`
- Slogan
- [`getspit.app`](https://getspit.app)
- [Política de Privacidade](https://getspit.app/privacy)
- [Termos de Uso](https://getspit.app/terms)
- [Suporte](https://getspit.app/support)
- `© 2026 Spit — all rights reserved`

---

## 5. HUD de Leitura ✅
*Overlay flutuante exibido enquanto o app está a reproduzir.*
- Status: Lendo/Processando/Traduzindo
- Botão Play/Pause (hotkey espaço)
- Hotkey para sair da leitura (Esc)
- Velocidade de reprodução: padrãp 100%
- Hotkey para acelerar a velocidade em 25% (seta para cima e seta para direita)
- Hotkey para reduzir a velocidade em 25% (seta para baixo ou seta para a esquerda)

---

## 6. HUD de Ditado ✅
*Overlay flutuante exibido enquanto o app está a gravar.*
- Ícone animado (waveform) → a ouvir
- Status: A ouvir/Processando/Traduzindo/Apromorando
- Tempo decorrido (ex: `0:47`)
- **Alerta de áudio longo** *(aparece ao atingir 2 minutos)*:
  > *"Áudio longo — termine este e comece um novo para melhor resultado"*

---

## 7. Painel de Revisão de Ditado ✅

*Painel sobreposto ao ecrã, exibido após a transcrição ser concluída.*
### Conteúdo

| Elemento | Detalhe |
|----------|---------|
| Header | **"Spit — Transcrição"** |
| Duração | `Xs` ou `X min Xs` |
| Botão fechar | ✕ |
| Área de alertas | ´Não foi possível identificar local para colar o texto. Cole-o com command + V no local desejado|
| Texto transcrito | Texto completo (sem tradução e antes do pós-processamento).|
| Texto tratado | Texto final, traduzido e processado. Substituições automáticas **a vermelho e clicáveis** |
| Botão copiar | Copia o texto para o clipboard |

### Substituições clicáveis
- Clicar numa substituição vermelha → abre popover de edição
- Se confirmada → adicionada automaticamente à lista em **Vocabulário → Substituição**
- Popover fecha após **5s sem interação**

### Timeout do painel
- Fecha automaticamente após **5s**
- **O contador reinicia a cada interação do utilizador com o painel** (clicar, selecionar texto, editar substituição)

---

## 8. Onboarding ✅

*Sequência exibida na primeira abertura do app.*

### Ecrã 1 — Boas-vindas
> *"O ditado com leitura integrada mais prático do Mac."*

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
- Mostra atalho padrão (ex: `globe`)
- Texto:
  > *"Toque rápido para gravar. Mantém pressionado para falar enquanto seguras a tecla."*
  - Mostre o resultado 2 outros idiomas para o usuário entener que pode traduzir de forma integrada 
- Link: Alterar nas Preferências
- CTA: **Continuar**

### Ecrã 6 — Primeiro Ditado
- *"Experimenta agora — dita algo"*
- Inicia gravação diretamente

### Ecrã 7 — Primeiro Ditado
- *Animação selecindo texto ('Spit lê o que você quiser, inclusive em outras idiomas traduzino tudo para você ganhar praticidade´, botão globe, e reproduz a leitura do texto*

### Ecrã 8 — Pronto
- `X min usados — ficam Y min de trial`
- CTA: **Começar**

---

## 9. Regras de Negócio e Notas de Implementação ✅

### Motor Local (WhisperKit)
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

> **Status actual (2026-04-24):** Fase 1 ✅ · Fase 2 ✅ · Fase 3 🚧 (9 ✅, 10 ✅, 11 a confirmar, 12 adiado, 13 pendente) · Fase 4 📋

### Fase 1 — Pré-lançamento *(sem isto não vende)* ✅
1. **Onboarding** — substituir fluxo atual (API key) pelo novo de 7 passos com magic link
2. **Hotkey PTT + Toggle** — comportamento unificado < 500 ms
3. **Menu bar — alertas BYOK** — banners para serviços não configurados; LEDs separados para Ditado e Leitura
4. **Settings — estados de plano** — trial / mensal / licença vitalícia / expirado

### Fase 2 — Polimento v1.0 ✅
5. **HUD de Leitura** — pause / stop / controlo de velocidade
6. **Alerta de áudio longo** — banner no HUD ao atingir 2 min
7. **ReviewHUD** — timeout com reset por interação + substituições clicáveis em vermelho
8. **NetworkMonitor** — deteção de offline + LED de status

### Fase 3 — Feature complete 🚧
9. **Parágrafo automático** ✅ — pós-processamento LLM com reutilização de chave STT
10. **Idiomas na popup** ✅ — dropdowns de acesso rápido + sublabel `PT → EN`
11. **APIs BYOK — minimalista** — manter apenas: chave Whisper (STT) + chave LLM (formatação/tradução). Sem dropdowns de modelo, voz, ou formalidade — defaults sensatos no código.
12. ~~**TranslationService — DeepL / OpenAI**~~ — **adiado pós-launch.** O LLM já cobre tradução com qualidade equivalente via BYOK e proxy `/translate`. Reavaliar pós-MVP se houver feedback de qualidade.
13. **Secção Sobre** — links e versão dinâmica

### Fase 4 — Design de produção *(última etapa)* 📋
14. **Protótipo visual das telas principais** — gerado com skill especializada de frontend design (`/frontend-design`), cobrindo: popup do menu bar, Settings, Onboarding, HUD de ditado, HUD de leitura, painel de confirmação. Serve de referência visual para refinar o SwiftUI com qualidade de produto comercial.
