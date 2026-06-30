# MindMap — guia de desenvolvimento

> ## 🚨 REGRA INVIOLÁVEL — NUNCA APAGAR DADOS DE PRODUÇÃO
>
> **Em hipótese alguma** apague, sobrescreva ou trunque dados de produção. Isto vale para:
> - Tabelas DynamoDB: `mindmap-users`, `mindmap-maps` (nenhum `delete-item`, `scan→delete`, `delete-table`, `batch-write` destrutivo).
> - Objetos no bucket de dados `mindmap-data-*` no S3 (nenhum `s3 rm`, `delete-object`, overwrite de `maps/...` ou `mindmap.json`).
>
> **PROIBIDO** para teste/limpeza/conveniência. Os "resets" que apagavam todas as linhas das tabelas e o prefixo `maps/` **causaram perda de dados reais — jamais repetir.**
>
> **Antes de QUALQUER alteração no banco/S3 de produção (mesmo não-destrutiva):**
> 1. **Confirmação explícita do usuário** (Felipe) para aquela operação específica.
> 2. **Backup completo no S3 ANTES** de executar (export das duas tabelas + cópia dos objetos para um prefixo `backups/<data>/`).
>
> Para testar: use **dados/recursos separados** (tabelas/bucket de teste, prefixo distinto, ou conta/stack à parte) — **nunca** os de produção. O teardown (`aws/teardown.sh`) só pode rodar em stacks de teste, **nunca** no prefixo `mindmap` de produção sem confirmação + backup.
>
> Recomendado habilitar (com confirmação): versionamento no bucket de dados e PITR nas tabelas DynamoDB.

Editor de mindmap para notas. Roda 100% offline no browser, sem build de framework, sem servidor. Motor: **Mind-Elixir** (MIT). Dados persistem em `localStorage` e exportam para Markdown/JSON.

## ✅ FLUXO OBRIGATÓRIO DE TODA MODIFICAÇÃO

Toda alteração (feature/bug/ajuste) **DEVE** seguir, nesta ordem, sem pular etapas:

1. **Testar** — validar no Chrome headless (puppeteer-core), capturar `pageerror`, conferir o comportamento. Não entregar nada sem teste passando.
2. **Build** — `node build.mjs` (regenera `mindmap.html`).
3. **Commit** — `git commit` com mensagem clara (Conventional-ish), incluindo o `Co-Authored-By` do Claude.
4. **Push** — `git push` para o repositório (`origin` = `git@github.com:felipelageduarte/MindMap-Open-Source.git`, branch `main`).
5. **Deploy** — `bash aws/deploy.sh` (sobe HTML + Lambda e invalida o CloudFront).

Ou seja: **teste → build → commit → push → deploy** em toda mudança. Nada de deploy sem commit+push; nada de commit sem teste.

## Arquitetura de arquivos (IMPORTANTE)

Dois "modos" do mesmo app:

| Arquivo | Papel | Editar à mão? |
|---------|-------|---------------|
| `index.html` | **Fonte.** HTML + CSS + JS do app. Referencia a lib via `vendor/`. | **SIM — edite aqui.** |
| `vendor/MindElixir.iife.js` `vendor/MindElixir.css` | Lib Mind-Elixir (vendorizada p/ offline). | Não (só trocar versão). |
| `mindmap.html` | **Build.** Arquivo único auto-contido (lib inline). Para usar/compartilhar/e-mail. | **NÃO — é gerado.** |

### Regra de ouro do fluxo

1. Toda mudança de feature/bug → editar **`index.html`** (e/ou `vendor/`).
2. Regenerar o single-file: **`node build.mjs`**.
3. **Nunca editar `mindmap.html` direto** — é artefato; qualquer mudança manual se perde no próximo build.

`build.mjs` faz inline do CSS e JS do `vendor/` dentro do HTML e valida que não sobrou nenhuma referência a `vendor/`.

## Testar (obrigatório antes de entregar)

Sem browser interativo aqui → testar headless com Chrome do sistema via `puppeteer-core`. Padrão usado em todas as features:

```bash
npm init -y >/dev/null 2>&1 && npm i puppeteer-core@23 >/dev/null 2>&1
node teste.mjs        # script ad-hoc com puppeteer-core
rm -f teste.mjs *.png package.json package-lock.json && rm -rf node_modules   # limpar
```

- `executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"`, `headless:"new"`.
- Carregar `file://` do `index.html`; `localStorage.clear()` + `reload` p/ estado limpo.
- Capturar `pageerror` e `requestfailed`. Tirar screenshot e ler com a ferramenta Read p/ conferir visual.
- Validar o single-file numa pasta isolada (sem `vendor/`) p/ garantir auto-contenção.
- **Não entregar código não testado.** Bugs reais aqui foram achados só rodando no browser.

## Modelo de dados

- Fonte da verdade: árvore do Mind-Elixir `{ nodeData: { id, topic, children:[...] } }`.
- `localStorage`: `mindmap.data.v4` (Markdown) + `mindmap.name.v4` (nome do doc). Sempre gravado (rascunho/conveniência).
- **Auto-save em arquivo** (opcional): File System Access API. Botão `💾 Arquivo` vincula um `.json` em disco; `save()` grava nele a cada mudança via `writeFile()`. Handle persiste no IndexedDB (`mindmap-fs`/`handle`) e reconecta no boot (`restoreFile()`). Formato do arquivo = `docJSON()` = `{name, ...mind.getData()}`. Quando vinculado, no boot o arquivo é a fonte (sobrescreve o localStorage via `loadFromFile`).
- **Sync S3** (opcional): botão `☁️ Nuvem`. App pede URL pré-assinada à sua API (`GET {api}/presign?op=get|put&key=`), depois faz `GET`/`PUT` do JSON **direto no S3**. Zero credencial no browser. `cloudSave()` em `save()`, `cloudLoad()` no boot. Config em `mindmap.cloud.v1`. Backend + setup em `aws/` (`presign.mjs` Lambda + `HOSTING.md`). Contrato: API devolve `{url}`. Conflito = último a salvar vence.
- Export `.md` (lista aninhada, p/ e-mail) e `.json` (`docJSON()`, re-importável, preserva imagens).
- Import: `.md`, `.json`, `.svg` (mindmap exportado do **Miro** — reconstrução por geometria).

## Features (camadas próprias sobre o Mind-Elixir)

- **CRUD/edição/drag/undo/context-menu/toolbar**: nativos do Mind-Elixir.
- **Duplo-clique p/ editar**: adicionado (ME só tem F2).
- **Checkbox**: texto começando com `[]`/`[ ]`/`[x]` vira checkbox. `topic` guarda o marcador cru (persiste); DOM é decorado pós-render via `MutationObserver`. Clique alterna.
- **Datas**: `DD/MM` ou `DD/MM/AAAA` no fim do texto = prazo. `parseDue()` extrai a última data válida.
- **Sidebar TODO** (esquerda): lista checkboxes não-marcados, agrupados por seção (= nó nível-1), ordenados por data (atrasado→hoje→futuro→sem data). Badge colorido. Clique foca o nó; checkbox conclui.
- **Imagens**: colar (`Ctrl/⌘+V`) ou botão; downscale via canvas; vira `nodeObj.image` (data URL). Só no `.json`.
- **Modal de atalhos**: tecla `?` (fora de digitação).
- **Expandir/recolher subárvore**: nó selecionado + `+`/`-` → `mind.expandNodeAll(currentNode, expand)` (recursivo, preserva posição). Handler em captura. ME usa `=`/`0`/`z`/`y` no teclado (não `+`/`-`). Reaplicar `setMapTheme()` depois (expandNodeAll faz `refresh` que reseta o tema).
- **Texto rico** (estilo/cor/tamanho, misturável no mesmo nó): editor in-place próprio (`beginRichEdit`) substitui o editor do ME no `Shift+Enter`/duplo-clique. Barra `#fmt` (B/I/U, cor, tamanho, 🔗 link) aplica via `execCommand` na seleção. Link: `createLink` + `target=_blank rel=noopener` (preserva seleção após o `prompt`); CSS `.map-container me-tpc a{pointer-events:auto!important}` torna o link clicável no nó (ME bloqueia filhos). `hasFmt` inclui `a` (senão link-only seria descartado). Commit grava `nodeObj.dangerouslySetInnerHTML` (HTML, ME renderiza) + `topic` (texto plano, p/ TODO/markdown/checkbox). ME pula seu editor quando o nó tem `dangerouslySetInnerHTML`. `decorate()` ignora nós rich (sem `span.text`). `.md` perde formatação; `.json`/blob preservam.
- **Tema claro/escuro**: botão `🌙/☀️`. `applyTheme()` usa `mind.changeTheme(MindElixir.THEME|DARK_THEME, true)` p/ o mapa + classe `body.dark` p/ o chrome. Default claro. Persiste em `mindmap.theme.v4`. `recenter()` reaplica o tema após `refresh` (ME reseta p/ default).
- **Bolinha de ramificação**: `drawJunctions()` (em `decorate()`) injeta `<circle class="mm-jx">` no **início de cada path** (`M x y` = cruzamento onde as linhas se abrem) dentro de `svg.lines`/`svg.subLines`. Miolo = `--map-bg` (vazio), anel = cor do ramo (atributo `stroke` do path). Dedup por coord. NÃO usar markers (svg tem área zero). NÃO usar borda do nó (junção fica deslocada do nó pelo gap do ME). Para evitar loop do observer, `decorate()` faz `cbObs.disconnect()` no início e re-`observe` no fim.
- **Atualizar pela reunião (IA / Bedrock)**: menu `🛠 Ferramentas → 🤖 Atualizar pela reunião` (só no modo nuvem). Modal com textarea p/ resumo/transcrição. Front serializa o mapa em markdown anotado com ids (`dataToMdIds`: `- [#id] texto`) e faz `POST /ai/analyze {markdown, transcript}`. Lambda chama **Claude Sonnet 4.6 no Bedrock** (`us.anthropic.claude-sonnet-4-6`, env `BEDROCK_MODEL`); system prompt pede JSON `{summary, ops}`. **Sem prefill** (Sonnet 4.6 no Bedrock rejeita assistant-message prefill) → parse por extração do 1º `{...}`. Ops: `add` (com `children` p/ sub-hierarquia), `edit`, `done`, `date`, `move`, `delete`. Painel de **revisão por mudança** (checkbox por op; `delete` em vermelho, desmarcado por padrão); `applyOps` muta um clone da árvore (`JSON.parse(JSON.stringify(getData()))`), preserva imagens/HTML rico dos nós não tocados e faz `refresh` único. `aiAnalyze` é **stateless** (não lê DB/S3). IAM: `bedrock:InvokeModel` em `foundation-model/*` + `inference-profile/*`. Timeout da Lambda = 60s.

## Mind-Elixir — peculiaridades descobertas (não regredir)

- Construtor fica em `MindElixir.default` (IIFE expõe namespace). Constantes (`SIDE`…) no namespace.
- ME força `position:relative` inline no `#map` → usar wrapper `#mapwrap` p/ dar altura total.
- ME põe `.map-container me-tpc>*{pointer-events:none}` → checkbox precisa de `pointer-events:auto!important`.
- ME usa **pointer events** e re-renderiza o nó na seleção → toggle do checkbox em `pointerdown` (captura).
- Edição acontece em `<div contenteditable="plaintext-only">` separado, seeded com `topic` cru (marcador preservado). `Esc` cancela edição (reverte); `Enter`/clique-fora confirma.
- `mind.setNodeTopic(el,t)` NÃO dispara evento `operation` → chamar `save()`/`renderTodo()` manualmente.
- `mind.findEle(id)` **LANÇA exceção** se o nó não existe/está recolhido (não retorna null) → sempre usar `findEleSafe` (try/catch). `selectNode(el)`, `scrollIntoView(el,true)`, `toCenter()`, `refresh(data)`, `getData()`, `getDataString()`, `expandNodeAll(el,bool)`, `bus.addListener("operation",cb)`.
- Clicar item da TODO de nó recolhido: `focusNode` acha o caminho (`pathToNode`), `expandNodeAll(true)` no 1º ancestral recolhido, depois `selectNode`+`scrollIntoView`.
- Balanceamento esquerda/direita ao adicionar filho da raiz: nativo do ME (conta `.lhs`/`.rhs`, empate vai p/ esquerda). Confirmado alternando.
- DOM do nó: `<me-tpc data-nodeid><span class="text">topic</span></me-tpc>`; `tpc.nodeObj` acessível (tem `children`, `expanded`).
- Linhas em `<svg class="lines">`/`<svg class="subLines">` (path `M parentX parentY ... childX childY`, stroke = cor do ramo). Esses SVG têm **área zero** (paths vazam via `overflow:visible`) → **`marker-start`/markers SVG não pintam** ali. Para artefatos na junção, usar overlay CSS no `me-tpc`, não markers.

## Deploy AWS

- Região `us-east-1`, profile via env `AWS_PROFILE`. Prefixo `mindmap` (nomes de recurso derivados do account em runtime via `sts`). Rode `node build.mjs && bash aws/deploy.sh`.
- Recursos criados: Lambda `mindmap-presign` (handler `api.handler`, router), HTTP API `mindmap-api` (rota `$default`), DynamoDB `mindmap-users` + `mindmap-maps` (PAY_PER_REQUEST), bucket dados `mindmap-data-<account>` (blobs em `maps/{email}/{mapId}.json`), bucket site `mindmap-site-<account>`, CloudFront (HTTPS). IDs/URLs específicos saem no fim do `deploy.sh`.
- Teardown: `PREFIX=mindmap bash aws/teardown.sh` (buckets, lambda, role, api, tabelas, CloudFront).

## Auth + multi-usuário + multi-mapa

- Backend: `aws/api.mjs` (Lambda router). Auth própria: senha com `scrypt` (crypto nativo), sessão via **JWT HS256** (segredo `aws/.deploy-jwt`, env `JWT_SECRET`). Sem libs de auth.
- **DynamoDB**: `mindmap-users` (PK email; passwordHash, name, role, createdAt) e `mindmap-maps` (PK owner=email, SK mapId; title, updatedAt). Blob JSON de cada mapa no **S3** (`maps/{email}/{id}.json`) — evita o limite de 400KB do Dynamo (imagens).
- **1º cadastro = admin.** Rotas: `POST /auth/register|login`, `GET /me`, `GET|POST /maps`, `DELETE|PATCH /maps/{id}`, `GET|PUT /maps/{id}/blob` (URL assinada S3), `POST /ai/analyze` (IA Bedrock, stateless), admin `GET|POST /users`, `DELETE|PATCH /users/{email}`.
- **Isolamento**: mapas são keyed por `owner` (email do JWT); `ownMap` valida posse → usuário só acessa os próprios. `ConsistentRead:true` nos GetItem/Query (evita eventual-consistency logo após criar mapa).
- Frontend (módulo Auth+API no `index.html`): gate `#auth` (login/registro), `#maps` (lista/criar/abrir/excluir), `#users` (admin), `#userMenu` (logout). `window.__MINDMAP_API__` injetada no deploy define modo nuvem; sem ela = modo local (só localStorage, botões de conta ocultos). `save()` → PUT blob do mapa atual; `openMap()` no login/troca.
- **Auto-persist**: `aws/deploy.sh` injeta `window.__MINDMAP_CLOUD__={api,token,key}` no HTML servido (placeholder `/*__CLOUD_CONFIG__*/`); o app auto-conecta no boot. Repo fica sem token (só a cópia no S3 tem). Token em `aws/.deploy-token` (gitignored).
- Redeploy: `node build.mjs && bash aws/deploy.sh` (idempotente; invalida CloudFront).
- Detalhes/setup manual: `aws/HOSTING.md`.

## Patch no vendor (Mind-Elixir)

- `vendor/MindElixir.iife.js` tem **1 patch manual** na detecção de drop do drag: o bloco original (`const r=12*e.scaleVal,a=document.elementFromPoint(...)...`) foi trocado por uma versão mais tolerante — **centro do nó = vira filho (`in`); topo/base do nó ou espaço entre nós = reordena (`before`/`after`)**, usando `closest("me-tpc")` e raio `24*scaleVal` p/ pegar o nó no gap. **Se re-vendorizar (npm) o ME, reaplicar esse patch.** `build.mjs` inclui o vendor no `mindmap.html`.

## Limitações conhecidas

- `localStorage` ~5MB: muitas imagens estouram → usar `.json` como backup (há guarda de quota). O auto-save em arquivo não tem esse limite.
- **Auto-save em arquivo**: só Chromium desktop (Chrome/Edge) — `Firefox/Safari` não têm a API (degrada p/ localStorage + export manual). Vincular exige gesto do usuário (botão). No boot, se a permissão estiver "prompt" (comum após reabrir), o botão fica laranja "🔌 Reconectar" e pede 1 clique p/ retomar.
- `mailto:` não anexa arquivo → botão E-mail baixa `.md` + abre rascunho; anexo manual.
- Import `.svg` é específico do **Miro** (outros exports têm estrutura diferente).
- `.md` é texto puro: imagens e (data URLs) não vão no Markdown.
