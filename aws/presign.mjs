// Lambda (Node 20, ESM) — devolve URL pré-assinada de GET/PUT p/ um objeto no S3.
// O browser NUNCA recebe credenciais AWS; só a URL assinada (expira em 5 min).
//
// Deps no zip: @aws-sdk/client-s3 @aws-sdk/s3-request-presigner
// Env: BUCKET (obrigatório), ALLOW_ORIGIN (ex.: https://seu-dominio), TOKEN (opcional)
// Rota API Gateway (HTTP API): ANY /presign  ->  esta Lambda
import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const s3 = new S3Client({});
const BUCKET = process.env.BUCKET;
const TOKEN = process.env.TOKEN || "";
const ORIGIN = process.env.ALLOW_ORIGIN || "*";

const cors = {
  "access-control-allow-origin": ORIGIN,
  "access-control-allow-methods": "GET,OPTIONS",
  "access-control-allow-headers": "authorization,content-type",
  "access-control-max-age": "3000",
};
const reply = (statusCode, obj) => ({
  statusCode,
  headers: { ...cors, "content-type": "application/json" },
  body: JSON.stringify(obj),
});

export const handler = async (event) => {
  const method = event?.requestContext?.http?.method || "GET";
  if (method === "OPTIONS") return { statusCode: 204, headers: cors, body: "" };

  if (TOKEN) {
    const auth = event?.headers?.authorization || event?.headers?.Authorization || "";
    if (auth !== "Bearer " + TOKEN) return reply(401, { error: "unauthorized" });
  }

  const q = event?.queryStringParameters || {};
  const op = q.op;
  const key = q.key || "mindmap.json";
  if (op !== "get" && op !== "put") return reply(400, { error: "op deve ser get|put" });

  const cmd = op === "put"
    ? new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: "application/json" })
    : new GetObjectCommand({ Bucket: BUCKET, Key: key });

  const url = await getSignedUrl(s3, cmd, { expiresIn: 300 });
  return reply(200, { url });
};
