#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# Deploy do MindMap na AWS (S3 + Lambda presign + HTTP API + site S3).
# Idempotente: pode rodar de novo. Usa o profile felipelageduarte / us-east-1.
#
# Uso:
#   bash aws/deploy.sh                 # deploy completo
#   AWS_PROFILE=outro bash aws/deploy.sh
# =============================================================================

REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE="${AWS_PROFILE:-felipelageduarte}"
export PATH="/opt/homebrew/bin:$PATH"

PROJECT="mindmap"
FUNC="${PROJECT}-presign"
ROLE="${PROJECT}-presign-role"
API_NAME="${PROJECT}-api"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log(){ echo -e "${BLUE}[mindmap]${NC} $1"; }
ok(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }
die(){ echo -e "${RED}[x]${NC} $1"; exit 1; }

command -v aws >/dev/null 2>&1 || die "AWS CLI não encontrado."
command -v zip >/dev/null 2>&1 || die "zip não encontrado."
ACCOUNT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
  || die "Credenciais AWS não configuradas (profile: $AWS_PROFILE)."
ok "Conta AWS: $ACCOUNT  |  profile: $AWS_PROFILE  |  região: $REGION"

DATA_BUCKET="${PROJECT}-data-${ACCOUNT}"
SITE_BUCKET="${PROJECT}-site-${ACCOUNT}"

# ── 1. Bucket de DADOS (privado) + CORS ──────────────────────────────────────
if aws s3api head-bucket --bucket "$DATA_BUCKET" >/dev/null 2>&1; then
  log "Bucket de dados já existe: $DATA_BUCKET"
else
  log "Criando bucket de dados: $DATA_BUCKET"
  aws s3api create-bucket --bucket "$DATA_BUCKET" --region "$REGION" >/dev/null
  ok "Bucket de dados criado."
fi
log "Aplicando CORS no bucket de dados..."
aws s3api put-bucket-cors --bucket "$DATA_BUCKET" --cors-configuration '{
  "CORSRules":[{"AllowedOrigins":["*"],"AllowedMethods":["GET","PUT"],
  "AllowedHeaders":["*"],"ExposeHeaders":["ETag"],"MaxAgeSeconds":3000}]}' >/dev/null
ok "CORS aplicado."

# ── 1b. DynamoDB (usuários + índice de mapas) ────────────────────────────────
USERS_TABLE="${PROJECT}-users"; MAPS_TABLE="${PROJECT}-maps"
if aws dynamodb describe-table --table-name "$USERS_TABLE" >/dev/null 2>&1; then
  log "Tabela $USERS_TABLE já existe."
else
  log "Criando tabela $USERS_TABLE..."
  aws dynamodb create-table --table-name "$USERS_TABLE" --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=email,AttributeType=S \
    --key-schema AttributeName=email,KeyType=HASH >/dev/null
  aws dynamodb wait table-exists --table-name "$USERS_TABLE"; ok "Tabela de usuários criada."
fi
if aws dynamodb describe-table --table-name "$MAPS_TABLE" >/dev/null 2>&1; then
  log "Tabela $MAPS_TABLE já existe."
else
  log "Criando tabela $MAPS_TABLE..."
  aws dynamodb create-table --table-name "$MAPS_TABLE" --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=owner,AttributeType=S AttributeName=mapId,AttributeType=S \
    --key-schema AttributeName=owner,KeyType=HASH AttributeName=mapId,KeyType=RANGE >/dev/null
  aws dynamodb wait table-exists --table-name "$MAPS_TABLE"; ok "Tabela de mapas criada."
fi

# ── 2. Segredo JWT ───────────────────────────────────────────────────────────
JWT_FILE="$SCRIPT_DIR/.deploy-jwt"
if [[ -f "$JWT_FILE" ]]; then JWT_SECRET="$(cat "$JWT_FILE")"; log "Reusando JWT secret."
else JWT_SECRET="$(openssl rand -hex 32)"; echo "$JWT_SECRET" > "$JWT_FILE"; ok "JWT secret gerado (aws/.deploy-jwt)."; fi

# ── 3. IAM role da Lambda ────────────────────────────────────────────────────
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  log "Role já existe: $ROLE"
else
  log "Criando role: $ROLE"
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version":"2012-10-17","Statement":[{"Effect":"Allow",
    "Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
  ok "Role criada. Aguardando propagação (10s)..."; sleep 10
fi
log "Aplicando policy (S3 + DynamoDB)..."
aws iam put-role-policy --role-name "$ROLE" --policy-name "${PROJECT}-access" --policy-document "{
  \"Version\":\"2012-10-17\",\"Statement\":[
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],
     \"Resource\":\"arn:aws:s3:::${DATA_BUCKET}/*\"},
    {\"Effect\":\"Allow\",\"Action\":[\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",
      \"dynamodb:DeleteItem\",\"dynamodb:Query\",\"dynamodb:Scan\"],
     \"Resource\":[\"arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${USERS_TABLE}\",
                   \"arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/${MAPS_TABLE}\"]}
  ]}" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
ok "Policy aplicada."

# ── 4. Empacotar + criar/atualizar Lambda ────────────────────────────────────
log "Empacotando Lambda (instala SDK)..."
BUILD="$SCRIPT_DIR/.build"; rm -rf "$BUILD"; mkdir -p "$BUILD"
cp "$SCRIPT_DIR/api.mjs" "$BUILD/"
command -v npm >/dev/null 2>&1 || { NB="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"; [[ -n "$NB" ]] && export PATH="$NB:$PATH"; }
command -v npm >/dev/null 2>&1 || die "npm não encontrado (Node.js necessário p/ empacotar a Lambda)."
printf '{"name":"api","version":"1.0.0","type":"module","private":true}\n' > "$BUILD/package.json"
( cd "$BUILD" && npm i --no-audit --no-fund \
    @aws-sdk/client-s3 @aws-sdk/s3-request-presigner @aws-sdk/client-dynamodb @aws-sdk/util-dynamodb ) \
  || die "npm install falhou (cheque a rede e tente de novo)."
( cd "$BUILD" && zip -qr function.zip api.mjs node_modules package.json ) || die "zip falhou."
ok "Pacote pronto."

LAMBDA_ENV="Variables={BUCKET=${DATA_BUCKET},ALLOW_ORIGIN=*,USERS_TABLE=${USERS_TABLE},MAPS_TABLE=${MAPS_TABLE},JWT_SECRET=${JWT_SECRET}}"
if aws lambda get-function --function-name "$FUNC" >/dev/null 2>&1; then
  log "Atualizando Lambda existente..."
  aws lambda update-function-code --function-name "$FUNC" \
    --zip-file "fileb://$BUILD/function.zip" >/dev/null
  aws lambda wait function-updated --function-name "$FUNC"
  aws lambda update-function-configuration --function-name "$FUNC" \
    --handler api.handler --runtime nodejs20.x --timeout 15 \
    --environment "$LAMBDA_ENV" >/dev/null
  aws lambda wait function-updated --function-name "$FUNC"
else
  log "Criando Lambda: $FUNC"
  aws lambda create-function --function-name "$FUNC" \
    --runtime nodejs20.x --handler api.handler --timeout 15 \
    --role "$ROLE_ARN" --zip-file "fileb://$BUILD/function.zip" \
    --environment "$LAMBDA_ENV" --region "$REGION" >/dev/null
  aws lambda wait function-active --function-name "$FUNC"
fi
LAMBDA_ARN="$(aws lambda get-function --function-name "$FUNC" --query Configuration.FunctionArn --output text)"
ok "Lambda pronta."

# ── 5. HTTP API (API Gateway v2) ─────────────────────────────────────────────
API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text)"
if [[ "$API_ID" == "None" || -z "$API_ID" ]]; then
  log "Criando HTTP API: $API_NAME"
  API_ID="$(aws apigatewayv2 create-api --name "$API_NAME" --protocol-type HTTP \
    --target "$LAMBDA_ARN" --query ApiId --output text)"
  # create-api --target já cria integração + rota default ($default) + stage.
  # Substituímos a rota default por ANY /presign:
  INTEG_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --query "Items[0].IntegrationId" --output text)"
  aws apigatewayv2 create-route --api-id "$API_ID" --route-key 'ANY /presign' \
    --target "integrations/${INTEG_ID}" >/dev/null 2>&1 || true
  ok "API criada: $API_ID"
else
  log "API já existe: $API_ID"
fi
# garante rota catch-all ($default → roteia tudo p/ a Lambda router)
INTEG_ID="$(aws apigatewayv2 get-integrations --api-id "$API_ID" --query "Items[0].IntegrationId" --output text)"
HAS_DEFAULT="$(aws apigatewayv2 get-routes --api-id "$API_ID" --query "Items[?RouteKey=='\$default'].RouteId | [0]" --output text)"
if [[ "$HAS_DEFAULT" == "None" || -z "$HAS_DEFAULT" ]]; then
  aws apigatewayv2 create-route --api-id "$API_ID" --route-key '$default' \
    --target "integrations/${INTEG_ID}" >/dev/null 2>&1 || true
  log "Rota \$default criada."
fi
# permissão p/ API GW invocar a Lambda (idempotente)
aws lambda add-permission --function-name "$FUNC" --statement-id apigw-invoke \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT}:${API_ID}/*/*" >/dev/null 2>&1 || true
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
ok "Endpoint da API: $API_URL"

# ── 6. Bucket do SITE + hospedar mindmap.html ────────────────────────────────
[[ -f "$ROOT_DIR/mindmap.html" ]] || die "mindmap.html não encontrado (rode 'node build.mjs' antes)."
if aws s3api head-bucket --bucket "$SITE_BUCKET" >/dev/null 2>&1; then
  log "Bucket do site já existe: $SITE_BUCKET"
else
  log "Criando bucket do site: $SITE_BUCKET"
  aws s3api create-bucket --bucket "$SITE_BUCKET" --region "$REGION" >/dev/null
fi
log "Liberando acesso público + website hosting..."
aws s3api put-public-access-block --bucket "$SITE_BUCKET" --public-access-block-configuration \
  "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" >/dev/null
aws s3api put-bucket-policy --bucket "$SITE_BUCKET" --policy "{
  \"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PublicRead\",\"Effect\":\"Allow\",
  \"Principal\":\"*\",\"Action\":\"s3:GetObject\",\"Resource\":\"arn:aws:s3:::${SITE_BUCKET}/*\"}]}" >/dev/null
aws s3 website "s3://${SITE_BUCKET}" --index-document index.html >/dev/null
log "Injetando URL da API + enviando index.html..."
TMP_HTML="$SCRIPT_DIR/.site-index.html"
CFG="window.__MINDMAP_API__=\"${API_URL}\";"
sed "s|/\*__CLOUD_CONFIG__\*/|${CFG}|" "$ROOT_DIR/mindmap.html" > "$TMP_HTML"
grep -q "__MINDMAP_API__=" "$TMP_HTML" || die "Falha ao injetar API no HTML."
aws s3 cp "$TMP_HTML" "s3://${SITE_BUCKET}/index.html" \
  --content-type "text/html; charset=utf-8" --cache-control "no-cache" >/dev/null
rm -f "$TMP_HTML"
# PWA: manifest, service worker e ícones
log "Enviando assets PWA (manifest/sw/ícones)..."
aws s3 cp "$ROOT_DIR/manifest.webmanifest" "s3://${SITE_BUCKET}/manifest.webmanifest" \
  --content-type "application/manifest+json" --cache-control "no-cache" >/dev/null
aws s3 cp "$ROOT_DIR/sw.js" "s3://${SITE_BUCKET}/sw.js" \
  --content-type "application/javascript" --cache-control "no-cache" >/dev/null
for ic in icon-192.png icon-512.png apple-touch-icon-180.png; do
  [[ -f "$ROOT_DIR/$ic" ]] && aws s3 cp "$ROOT_DIR/$ic" "s3://${SITE_BUCKET}/$ic" \
    --content-type "image/png" --cache-control "public,max-age=604800" >/dev/null
done
SITE_URL="http://${SITE_BUCKET}.s3-website-${REGION}.amazonaws.com"
ok "Site + PWA publicados."

# ── 7. CloudFront (HTTPS) na frente do site ──────────────────────────────────
ORIGIN_DOMAIN="${SITE_BUCKET}.s3-website-${REGION}.amazonaws.com"
CF_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${PROJECT}'].Id | [0]" --output text 2>/dev/null)"
if [[ "$CF_ID" == "None" || -z "$CF_ID" ]]; then
  log "Criando distribuição CloudFront (HTTPS)..."
  CF_CFG="$SCRIPT_DIR/.cf.json"
  cat > "$CF_CFG" <<JSON
{
  "CallerReference": "${PROJECT}-$(date +%s)",
  "Comment": "${PROJECT}",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": { "Quantity": 1, "Items": [ {
    "Id": "site",
    "DomainName": "${ORIGIN_DOMAIN}",
    "CustomOriginConfig": { "HTTPPort": 80, "HTTPSPort": 443,
      "OriginProtocolPolicy": "http-only",
      "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] } }
  } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "site",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "Compress": true,
    "AllowedMethods": { "Quantity": 2, "Items": ["GET","HEAD"] }
  }
}
JSON
  read -r CF_ID CF_DOMAIN < <(aws cloudfront create-distribution --distribution-config "file://$CF_CFG" \
    --query "[Distribution.Id, Distribution.DomainName]" --output text)
  rm -f "$CF_CFG"
  ok "CloudFront criado: $CF_ID (propaga em ~5-10 min)."
else
  CF_DOMAIN="$(aws cloudfront get-distribution --id "$CF_ID" --query Distribution.DomainName --output text)"
  log "CloudFront já existe: $CF_ID"
  aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/*" >/dev/null 2>&1 || true
  log "Cache invalidado (/*)."
fi
CF_URL="https://${CF_DOMAIN}"
ok "URL HTTPS: $CF_URL"

# ── Resumo ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}========================  DEPLOY OK  ========================${NC}"
echo -e "Site HTTPS (use este):   ${BLUE}${CF_URL}${NC}"
echo -e "Site HTTP (S3 direto):   ${BLUE}${SITE_URL}${NC}"
echo ""
echo -e "API: ${BLUE}${API_URL}${NC}  (injetada no HTML; o app usa login/senha)"
echo -e "Primeiro cadastro vira ${YELLOW}admin${NC}."
echo ""
echo -e "Recursos criados (conta ${ACCOUNT}):"
echo -e "  Lambda : ${FUNC}"
echo -e "  API    : ${API_NAME} (${API_ID})"
echo -e "  Bucket dados : ${DATA_BUCKET} (privado)"
echo -e "  Bucket site  : ${SITE_BUCKET} (público)"
echo -e "  CloudFront : ${CF_ID} → ${CF_DOMAIN}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${YELLOW}Nota:${NC} use a URL HTTPS (CloudFront). Mudanças no HTML propagam em ~5-10 min na 1ª vez."
rm -rf "$BUILD"
