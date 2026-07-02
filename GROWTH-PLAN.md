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
- [ ] **Página `/about` no site** — a história em 1.ª pessoa: porque construí o
      Spit, quem sou, o que é a Draxo.io (estúdio de software indie). Foto real,
      nome real, links (GitHub, X/Mastodon, email). É *a* peça central da
      atribuição. (Modelo: páginas "about" de indie devs Mac — curtas, humanas.)
- [ ] **Footer do site** — linha discreta: `A Draxo.io project · made by Rafael Lopes`
      com links. Aparece em todas as páginas.
- [ ] **`humans.txt`** na raiz do site — sinal clássico de dev ("/humans.txt").
      Nome, papel, contacto, stack. Custa 2 min, fala com a tribo certa.
- [ ] **Consistência de identidade** — mesma foto/handle/bio no GitHub, site, X,
      HN, Product Hunt. Um curioso que salte entre plataformas reconhece a mesma
      pessoa. Isto sozinho constrói mais confiança que qualquer copy.
- [ ] **GitHub profile README** (`rafaellopes/rafaellopes`) — 1 parágrafo: quem
      és, Draxo.io, os teus projetos. É a página que abre quando clicam no teu nome.
- [ ] Já feito no app: nome real no *About*. Adicionar link "Made by Draxo.io".

---

## 2. Pilar B — Website getspit.app

**Problema atual:** o site ainda tem resquícios do modelo pago (BYOK, planos,
"prova gratuita 60 min"). A mensagem tem de virar 100% para **grátis + open +
privado**. O ficheiro local `spit-landing.html` está ainda mais desatualizado
que a versão live — não usar como base sem rever.

### Ações
- [ ] **Reescrever o hero** para a nova realidade: "Ditado por voz no teu Mac.
      Grátis. Privado. Open-source." Remover qualquer menção a planos/subscrição/BYOK
      como requisito.
- [ ] **Secção "Porquê confiar"** — não "features", mas provas: 100% on-device
      (link ao código que o prova), MIT (link ao LICENSE), sem telemetria, sem conta.
- [ ] **Comparação honesta** — tabela vs superwhisper / Wispr Flow / MacWhisper.
      Factual, sem trash-talk. Isto capta quem já procura "superwhisper alternative".
- [ ] **SEO** — meta tags + conteúdo para as queries reais:
      `free dictation mac`, `open source voice to text mac`, `superwhisper alternative`,
      `whisper dictation mac`, `private speech to text mac`, `wispr flow alternative`.
      Cada uma é uma landing/secção com intenção clara.
- [ ] **`/about`** (ver Pilar A).
- [ ] **Changelog público** (`/changelog` ou reusa o `CHANGELOG.md`) — sinal de
      projeto vivo. Cada release nova = uma razão para voltar + conteúdo indexável.
- [ ] **OpenGraph / Twitter cards** — quando alguém partilha o link, aparece um
      cartão bonito com screenshot. Barato, multiplica cliques.
- [ ] **Botão download único e óbvio** → GitHub Releases (`.dmg` notarizado).

---

## 3. Pilar C — GitHub (`rafaellopes/spit`)

O README já é bom. Falta transformá-lo de "documentação" em **montra + prova
social + porta de entrada para a pessoa por trás**.

### Ações
- [ ] **GIF/vídeo no topo do README** — 10s a mostrar ditado real numa app. É o
      maior multiplicador de conversão num repo. (Grava com o próprio Spit + Kap.)
- [ ] **Screenshots** — HUD, menu bar, settings.
- [ ] **Topics do repo** — `macos`, `dictation`, `speech-to-text`, `whisper`,
      `swift`, `privacy`, `on-device`, `open-source`, `accessibility`, `menubar`.
      É como o GitHub te encontra em Explore/Topics.
- [ ] **`FUNDING.yml`** — GitHub Sponsors / Ko-fi. Não para monetizar, mas porque
      é o sinal universal de "há uma pessoa real que podes apoiar". Reforça a
      atribuição sem ser comercial.
- [ ] **`SECURITY.md`** — como reportar vulnerabilidades. Sinal de maturidade e
      de que levas a privacidade a sério (coerente com a proposta).
- [ ] **`CONTRIBUTING.md`** — já há uma secção no README; extrair para ficheiro.
- [ ] **Release notes ricas** — cada release do GitHub com changelog legível
      (não só "build 11"). É a primeira coisa que um avaliador lê.
- [ ] **Autor visível** — badge/linha no README: "Built by [Rafael Lopes](.) at
      [Draxo.io](https://draxo.io)". Fecha o loop de atribuição.
- [ ] **Entrar em awesome-lists** (PRs): `awesome-macos`, `awesome-swift`,
      `awesome-privacy`, `awesome-selfhosted`-adjacentes, `awesome-macos-command-line`.
      Cada merge = backlink permanente + descoberta orgânica.

---

## 4. Pilar D — Momento de lançamento

Um produto grátis + open-source + privacy-first + on-device é **exatamente** o
que certas comunidades adoram. Um único lançamento bem feito pode trazer os
primeiros milhares. Ordenado por fit:

### 4.1 Show HN (Hacker News) — canal nº 1 para este produto
- [ ] Título: `Show HN: Spit – On-device voice dictation for Mac, free and open source`
- [ ] Primeiro comentário do autor: a história curta (porque o construí, porque é
      on-device, o que é a Draxo). HN premeia o solo founder honesto.
- [ ] Postar 3.ª/4.ª de manhã (horário US ET). Estar disponível 4-6h para responder.
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
- [ ] **Homebrew Cask** — `brew install --cask spit`. Sinal de legitimidade para
      devs + canal de instalação sem fricção.

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
