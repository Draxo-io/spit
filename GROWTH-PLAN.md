# Spit — Plano de Crescimento

> Objetivo: conquistar muitos utilizadores **sem apelar ao hype**. A confiança
> é o canal de distribuição. Quem quiser saber quem está por trás descobre
> com um clique — **Draxo.io** (o estúdio) e **Rafael Lopes** (solo founder) —
> mas nunca lho empurramos à cara.

---

## 0. Princípio orientador

A categoria "ditado por voz no Mac" está cheia de apps caras, por subscrição, que
mandam o teu áudio para a cloud (Wispr Flow, superwhisper, MacWhisper, Dragon).
O Spit ganha por **oposição a tudo isso**, e essa oposição é a mensagem:

| Eles | Spit |
|---|---|
| Subscrição mensal | Grátis, para sempre |
| Áudio vai para a cloud | 100% no teu Mac, zero rede |
| Código fechado | Open-source (MIT), lês cada linha |
| Empresa anónima / VC | Uma pessoa real + um estúdio pequeno |

Regra de voz em **tudo** o que escrevermos: factual, técnico, sem superlativos,
sem "revolucionário", sem countdown timers, sem "junta-te a 10.000 users". A
credibilidade *é* o marketing. O público-alvo (devs, gente de privacidade,
utilizadores Mac avançados, pessoas com RSI/dislexia) tem alergia a vendedores.

---

## 1. Pilar A — Identidade & atribuição (Draxo + Rafael descobríveis)

O teste: **um estranho curioso, em 1 clique a partir do site ou do GitHub,
consegue chegar ao Rafael e à Draxo.** Sem CTA, sem "sobre nós" gigante — só
os sinais discretos que a comunidade indie reconhece.

### Ações
- [x] **Página `/about` no site** — publicada em getspit.app/about. **Ainda tem
      `[RASCUNHO]`** — o texto pessoal (porquê construíste o Spit, o que é a
      Draxo, factos biográficos) precisa da tua revisão antes de ser definitivo.
- [x] **Footer do site** — "Um projeto Draxo.io, por Rafael Lopes" em todas as
      15 línguas, com links.
- [x] **`humans.txt`** na raiz do site.
- [ ] **Consistência de identidade** — mesma foto/handle/bio no GitHub, site, X,
      HN, Product Hunt. Ainda por fazer — depende de teres esses perfis definidos.
- [ ] **GitHub profile README** (`rafaellopes/rafaellopes`) — 1 parágrafo: quem
      és, Draxo.io, os teus projetos. É a página que abre quando clicam no teu nome.
- [ ] Link "Made by Draxo.io" dentro do *About* nativo da app (`AboutView.swift`)
      — o About do site já tem, o About do **app** ainda não foi tocado.

---

## 2. Pilar B — Website getspit.app

**Problema atual:** o site ainda tem resquícios do modelo pago (BYOK, planos,
"prova gratuita 60 min"). A mensagem tem de virar 100% para **grátis + open +
privado**. O ficheiro local `spit-landing.html` está ainda mais desatualizado
que a versão live — não usar como base sem rever.

### Ações
- [x] **Reescrever o hero** — feito em 15 línguas: grátis/open/on-device,
      sem trial/subscrição/App Store.
- [ ] **Secção "Porquê confiar"** dedicada — hoje há links dispersos (footer,
      pricing_note) ao código/MIT, mas não uma secção própria com essa promessa
      em destaque. Ainda por fazer.
- [ ] **Comparação honesta** — tabela vs superwhisper / Wispr Flow / MacWhisper.
      Ainda não existe no site. Isto capta quem já procura "superwhisper alternative".
- [~] **SEO** — meta description + OpenGraph feitos. Falta o conteúdo dedicado
      por query (`superwhisper alternative`, `wispr flow alternative`, etc.) —
      a comparação acima resolveria isto ao mesmo tempo.
- [x] **`/about`** — ver Pilar A.
- [ ] **Changelog público** — ainda não existe no site.
- [x] **OpenGraph / Twitter cards** — feito, com `og.png` existente.
- [x] **Botão download único e óbvio** → GitHub Releases, em toda a UI.

---

## 3. Pilar C — GitHub (`Draxo-io/spit`)

O README já é bom. Falta transformá-lo de "documentação" em **montra + prova
social + porta de entrada para a pessoa por trás**.

### Ações
- [ ] **GIF/vídeo no topo do README** — **fica para ti** (é o teu Mac, o teu
      fluxo real). TODO já marcado no README. É o maior multiplicador de
      conversão num repo — o item mais valioso ainda em aberto.
- [ ] **Screenshots** — HUD, menu bar, settings. Também precisa de correr no
      teu Mac.
- [x] **Topics do repo** — definidos: macos, dictation, speech-to-text, whisper,
      swift, privacy, on-device, open-source, accessibility, menubar, voice-recognition.
- [ ] **`FUNDING.yml`** — **bloqueado**: precisa de teres uma conta GitHub
      Sponsors ou Ko-fi criada primeiro (não crio contas por ti).
- [x] **`SECURITY.md`**.
- [x] **`CONTRIBUTING.md`**.
- [ ] **Release notes ricas** — a v2.0 ainda só tem notas genéricas a apontar
      para o CHANGELOG. Ainda por fazer.
- [x] **Autor visível** — crédito Draxo/Rafael no README.
- [~] **Entrar em awesome-lists**:
      - [x] `awesome-mac` — PR aberto: [jaywcjlove/awesome-mac#2248](https://github.com/jaywcjlove/awesome-mac/pull/2248)
      - [ ] `awesome-whisper` — texto pronto, **bloqueado**: exigem 100+ stars, Spit tem 0
      - [ ] `awesome-voice-typing` — **bloqueado**: exigem ~50 stars
      - `awesome-swift` e `awesome-privacy` — descartados, fora de scope (confirmado)

---

## 4. Pilar D — Momento de lançamento

Um produto grátis + open-source + privacy-first + on-device é **exatamente** o
que certas comunidades adoram. Um único lançamento bem feito pode trazer os
primeiros milhares. Ordenado por fit:

### 4.1 Show HN (Hacker News) — canal nº 1 para este produto
- [x] Rascunho pronto em `SHOW-HN-DRAFT.md` — título, URL a submeter, primeiro
      comentário completo, notas de timing.
- [ ] **Falta**: tu leres/ajustares e publicares (tem de ser da tua conta).
- [ ] **Não** pedir upvotes. Não fazer astroturfing. HN deteta e pune.

### 4.2 Product Hunt
- [ ] Página com a *maker story*, GIF, screenshots. Posicionamento: indie, grátis,
      privado. Escolher uma 3.ª-feira.
- [ ] Responder a todos os comentários pessoalmente.

### 4.3 Reddit (cada um com post nativo, sem copy-paste)
- [ ] r/macapps (o mais quente para isto), r/apple, r/macOS, r/opensource
- [ ] r/rsi, r/dysgraphia, r/dyslexia, r/accessibility — ditado é **genuinamente**
      transformador para estas pessoas. Abordagem 100% de serviço, nunca venda.

---

## 5. Pilar E — Distribuição contínua (o trabalho de fundo)

- [ ] **alternativeTo.net** — listar Spit como alternativa a superwhisper, Wispr
      Flow, MacWhisper, Dragon. Fonte enorme de tráfego de intenção alta.
- [ ] **Diretórios Mac**: MacUpdate, Mac App directories, "menu bar apps" lists.
- [ ] **SEO de comparação** — artigos "Spit vs superwhisper", "melhor alternativa
      grátis ao Wispr Flow". Captam quem já está a decidir.
- [ ] **Comunidade de acessibilidade** — RSI, dislexia, mobilidade reduzida.
      Parcerias/menções com criadores desse nicho. É o público onde o Spit muda
      vidas, não só poupa cliques — e onde a autenticidade é obrigatória.
- [ ] **Homebrew Cask** — formula pronta e testada (`brew style` limpo, SHA256
      confirmado). **Bloqueado**: regra escrita deles exige 75+ stars (225+ para
      auto-submissão, que é o nosso caso). Submeter assim que houver tracção.

---

## 6. Pilar F — Build in public (sustentado, discreto)

- [ ] **Changelog como conteúdo** — cada release = 1 post curto (site + X/Mastodon)
      a explicar o que mudou e porquê. Constrói audiência ao longo do tempo.
- [ ] **X/Mastodon** com a identidade Rafael/Draxo — dev logs honestos, não
      promoção. Mostrar o processo (ex.: "corrigi hoje um death-loop de memória
      com o Jetsam" — a comunidade dev adora estas histórias técnicas reais).
- [ ] **Responder a quem menciona** superwhisper/Wispr no X e Reddit, com utilidade,
      não spam.

---

## 6.5 Monetização — decisão open-core faseado (2026-07-05)

**Decisão do Rafael:** não vender agora; lançar grátis e introduzir um tier pago
mais tarde, por cima do core gratuito. Racional: vender hoje rende ~€0 (sem
audiência) e queima a narrativa "grátis para sempre" acabada de publicar em 15
línguas; o código core já é MIT/público de qualquer forma.

**Modelo:** open-core (à VoiceInk/Obsidian/Raycast)
- **Core MIT, grátis para sempre** — ditado local. A promessa pública nunca é revertida.
- **Spit Pro (closed-source, pago)** — features que não competem com a promessa:
  vozes TTS premium, sync de vocabulário entre Macs, modelos maiores geridos,
  integrações. Infra de licenças (LicenseManager/JWT/Worker) já existe, fica em espera.

**Critérios para activar o Pro (avaliar aos 3-6 meses):**
- [ ] ≥ 500 stars GitHub **ou** ≥ 2.000 downloads acumulados
- [ ] Sinais de procura orgânica (issues/emails a pedir features premium)
- [ ] Retenção 30 dias > 25% (Sparkle check-ins)

Enquanto os critérios não se cumprirem: só doações (Ko-fi) + foco em distribuição.

---

## 7. Métricas (sem vaidade)

Medir o que indica adoção real, não aplausos:
- Downloads do `.dmg` (GitHub Releases API) + instalações ativas (Sparkle appcast hits)
- Stars do GitHub (proxy de confiança dev, não objetivo em si)
- Tráfego getspit.app por fonte (Plausible já está instalado — `analytics.draxo.io`)
- Cliques no `/about` e no link Draxo (queremos que a curiosidade converta em descoberta)
- Retenção: % que ainda usa após 7/30 dias (Sparkle check-ins)

---

## 8. Sequência recomendada (4 semanas)

**Semana 1 — Fundações (não lançar nada ainda).**
Website: virar mensagem para grátis/open + `/about` + footer Draxo + humans.txt.
GitHub: GIF, screenshots, topics, FUNDING/SECURITY/CONTRIBUTING, autor visível.
→ *Só se lança quando a "casa" está pronta para o curioso que chega.*

**Semana 2 — Descoberta passiva.**
PRs a awesome-lists, alternativeTo, diretórios, Homebrew Cask. SEO no ar.

**Semana 3 — Lançamento.**
Show HN (dia âncora) → Product Hunt → Reddit nativo. Autor presente e a responder.

**Semana 4 — Sustentar.**
Primeiro post de build-in-public. Responder, iterar, próxima release com changelog
público. Repetir o ciclo release→post indefinidamente.

---

## 9. O que dá para executar já (com o teu OK)

Estas eu faço agora no repo/site sem esperar por nada externo:
1. Reescrever o hero + mensagem do site para grátis/open/privado.
2. Criar a página `/about` (rascunho — tu revês o texto pessoal).
3. Footer Draxo + `humans.txt`.
4. Enriquecer README (autor, badges, secção "porquê confiar") + `FUNDING.yml`,
   `SECURITY.md`, `CONTRIBUTING.md`.
5. Definir topics do repo via `gh`.

O que **fica para ti** (por serem contas/publicações pessoais, e por regra não
publico em teu nome sem autorização explícita, post a post):
- Postar no HN / Product Hunt / Reddit (a voz tem de ser tua).
- Gravar o GIF de demo (é o teu Mac, o teu fluxo real).
- Criar GitHub Sponsors / Ko-fi se quiseres o botão de apoio.
