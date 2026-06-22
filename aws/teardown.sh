#!/usr/bin/env bash
set -uo pipefail
# Remove um stack do MindMap. Uso: PREFIX=mindmap-old bash aws/teardown.sh
REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE="${AWS_PROFILE:-felipelageduarte}"
export PATH="/opt/homebrew/bin:$PATH"
PREFIX="${PREFIX:?defina PREFIX, ex.: PREFIX=mindmap-old}"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
FUNC="${PREFIX}-presign"; ROLE="${PREFIX}-presign-role"; API_NAME="${PREFIX}-api"
DATA_BUCKET="${PREFIX}-data-${ACCOUNT}"; SITE_BUCKET="${PREFIX}-site-${ACCOUNT}"
echo "Teardown de '${PREFIX}' na conta ${ACCOUNT}…"

# API
API_ID="$(aws apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null)"
if [[ -n "$API_ID" && "$API_ID" != "None" ]]; then aws apigatewayv2 delete-api --api-id "$API_ID" && echo "  api $API_ID removida"; fi

# Lambda
aws lambda delete-function --function-name "$FUNC" 2>/dev/null && echo "  lambda removida" || true

# DynamoDB
for T in "${PREFIX}-users" "${PREFIX}-maps"; do
  aws dynamodb delete-table --table-name "$T" >/dev/null 2>&1 && echo "  tabela $T removida" || true
done

# Role (inline policy + managed + role)
aws iam delete-role-policy --role-name "$ROLE" --policy-name "${PREFIX}-s3" 2>/dev/null || true
aws iam detach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "  role removida" || true

# Buckets (esvazia + deleta)
for B in "$DATA_BUCKET" "$SITE_BUCKET"; do
  if aws s3api head-bucket --bucket "$B" >/dev/null 2>&1; then
    aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true
    aws s3api delete-bucket --bucket "$B" >/dev/null 2>&1 && echo "  bucket $B removido" || true
  fi
done

# CloudFront (por Comment == PREFIX): desabilita, espera, deleta
CF_ID="$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='${PREFIX}'].Id | [0]" --output text 2>/dev/null)"
if [[ -n "$CF_ID" && "$CF_ID" != "None" ]]; then
  echo "  CloudFront $CF_ID: desabilitando…"
  TMP="$(mktemp -d)"
  aws cloudfront get-distribution-config --id "$CF_ID" > "$TMP/full.json"
  ETAG="$(python3 -c "import json;print(json.load(open('$TMP/full.json'))['ETag'])")"
  python3 -c "import json;d=json.load(open('$TMP/full.json'))['DistributionConfig'];d['Enabled']=False;json.dump(d,open('$TMP/cfg.json','w'))"
  aws cloudfront update-distribution --id "$CF_ID" --distribution-config "file://$TMP/cfg.json" --if-match "$ETAG" >/dev/null
  echo "  aguardando propagar (pode levar ~10-15 min)…"
  aws cloudfront wait distribution-deployed --id "$CF_ID"
  ETAG2="$(aws cloudfront get-distribution-config --id "$CF_ID" --query ETag --output text)"
  aws cloudfront delete-distribution --id "$CF_ID" --if-match "$ETAG2" && echo "  CloudFront removido"
  rm -rf "$TMP"
fi
echo "Teardown de '${PREFIX}' concluído."
