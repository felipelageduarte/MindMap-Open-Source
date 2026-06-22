# Hospedar no S3 + sync com URL assinada

Dois passos: **(A)** servir o `mindmap.html` e **(B)** persistir os dados num objeto JSON no S3 via API que assina URLs. O browser nunca recebe credencial AWS.

Região nos exemplos: `sa-east-1` (São Paulo). Ajuste.

## A) Servir o HTML

1. Crie um bucket p/ o site (ex.: `meu-mindmap-app`).
2. Suba `mindmap.html` (renomeie p/ `index.html` se quiser raiz).
3. **HTTPS** é necessário (File System Access, clipboard). Use **CloudFront** na frente do bucket:
   - Origin = o bucket (use OAC, bucket privado).
   - Default root object = `index.html`.
   - Anote o domínio `https://xxxx.cloudfront.net` → é a origem do app.

(Alternativa rápida sem HTTPS: S3 “Static website hosting”, mas perde recursos que exigem contexto seguro.)

## B) Persistência (dados) — bucket + Lambda + API

### B1. Bucket de dados (pode ser o mesmo, key separada)
Bucket privado, ex.: `meu-mindmap-dados`. Guarda `mindmap.json`.

**CORS do bucket** (Permissions → CORS) — libera o browser a fazer GET/PUT na URL assinada:
```json
[
  {
    "AllowedOrigins": ["https://xxxx.cloudfront.net"],
    "AllowedMethods": ["GET", "PUT"],
    "AllowedHeaders": ["*"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```
(Em teste local pode usar `"*"` em AllowedOrigins.)

### B2. Lambda (`aws/presign.mjs`)
- Runtime Node 20.x, handler `presign.handler`.
- Empacote com as deps:
  ```bash
  cd aws && npm init -y && npm i @aws-sdk/client-s3 @aws-sdk/s3-request-presigner
  zip -r presign.zip presign.mjs node_modules
  ```
- Variáveis de ambiente:
  - `BUCKET=meu-mindmap-dados`
  - `ALLOW_ORIGIN=https://xxxx.cloudfront.net`
  - `TOKEN=<um segredo opcional>` (se setar, o app deve enviar o mesmo no campo Token)
- IAM role da Lambda: permissão mínima
  ```json
  { "Effect": "Allow", "Action": ["s3:GetObject","s3:PutObject"],
    "Resource": "arn:aws:s3:::meu-mindmap-dados/*" }
  ```

### B3. API Gateway (HTTP API)
- Crie uma HTTP API.
- Rota: `ANY /presign` → integra na Lambda.
- CORS pode ficar todo na Lambda (já responde OPTIONS). Deploy → anote a URL `https://xxxx.execute-api.sa-east-1.amazonaws.com`.

### B4. Configurar no app
No MindMap, botão **☁️ Nuvem**:
- **Endpoint da API**: a URL do API Gateway (sem `/presign` no fim — o app acrescenta).
- **Token**: só se você setou `TOKEN` na Lambda.
- **Chave do objeto**: `mindmap.json` (ou outra; cada chave = um mapa).
- **Conectar**: carrega do S3 (ou cria) e passa a salvar a cada mudança.

## Como funciona
- App → `GET {API}/presign?op=get|put&key=...` → recebe `{url}` assinada (expira 5 min).
- App → `GET url` (lê) ou `PUT url` com o JSON (grava) **direto no S3**.
- Sem limite de payload de API/Lambda (vai direto pro S3) — bom p/ imagens embutidas.

## Segurança
- A Lambda é a única que tem credencial. O browser só vê URLs temporárias.
- Sem `TOKEN`, qualquer um com a URL da API consegue assinar (ler/gravar o objeto). Para uso pessoal, defina um `TOKEN` (lembre: ele fica no navegador/localStorage, então não é segredo forte — para segurança real, troque por login Cognito).
- Conflito entre dispositivos: **último a salvar vence** (sem merge). Evite editar o mesmo mapa em dois lugares ao mesmo tempo.
