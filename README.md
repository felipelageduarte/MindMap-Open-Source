# MindMap Open-Source

Editor de mapas mentais **offline-first**, em um único arquivo HTML, com sincronização opcional na nuvem (AWS serverless) e multiusuário. Motor de render: [Mind-Elixir](https://github.com/SSShooter/mind-elixir-core) (MIT).

## Recursos

- **CRUD completo** de nós: `Tab` filho, `Enter` irmão, `Del` apagar, drag-and-drop tolerante (reordenar / reparentar / trocar de lado).
- **Texto rico**: negrito, itálico, sublinhado, cor e tamanho — misturáveis no mesmo nó. Links que abrem em nova aba.
- **Checkbox**: nó começando com `[]` ou `[x]` vira checkbox clicável.
- **Datas/prazos**: `DD/MM` ou `DD/MM/AAAA` no fim do texto.
- **Sidebar TODO**: lista os checkboxes pendentes, agrupados por seção (nó de nível 1) e ordenados por data. Clicar foca o nó (expande se recolhido).
- **Imagens** nos nós (colar `Ctrl/⌘+V` ou arquivo).
- **Busca**: barra no topo + paleta central estilo Spotlight (`Cmd/Ctrl+K` ou `/`).
- **Expandir/recolher tudo**, tema claro/escuro, expandir/recolher subárvore (`+`/`-`).
- **Import/Export**: `.md` (Markdown), `.json` (completo), import de `.svg` exportado do Miro.
- **Persistência**: `localStorage` (offline) e, com o backend, **multiusuário** (login/senha) com **vários mapas por usuário**, isolados.

## Como rodar (offline, sem backend)

Abra o **`mindmap.html`** no navegador. Funciona 100% offline, salvando no `localStorage`. Sem login.

## Desenvolvimento

- `index.html` é a **fonte** (referencia `vendor/`).
- `mindmap.html` é o **build** auto-contido (lib embutida) — gere com:

```bash
node build.mjs
```

Não edite `mindmap.html` à mão; é gerado.

## Backend opcional (AWS serverless)

Login/senha, gestão de usuários (com aprovação por admin) e múltiplos mapas por usuário, usando **API Gateway + Lambda + DynamoDB + S3 + CloudFront**. Nenhuma credencial fica no navegador (URLs S3 são pré-assinadas pela Lambda; sessão via JWT).

```bash
bash aws/deploy.sh        # cria/atualiza toda a infra (usa AWS CLI + seu AWS_PROFILE)
PREFIX=mindmap bash aws/teardown.sh   # remove tudo
```

Detalhes em [`aws/HOSTING.md`](aws/HOSTING.md). O 1º usuário cadastrado vira **admin**; os demais aguardam aprovação.

## Atalhos

`Tab` filho · `Enter` irmão · `Shift+Enter`/2× clique editar · `Del` apagar · `+`/`-` expandir/recolher subárvore · `Cmd/Ctrl+K` ou `/` buscar · `Ctrl/⌘+V` colar imagem · `?` ajuda.

## Licença

[MIT](LICENSE).
