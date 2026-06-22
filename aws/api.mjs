// Lambda router — auth (login/registro), gestão de usuários, multi-mindmap.
// DynamoDB: usuários + índice de mapas. S3: blob JSON de cada mapa (via URL assinada).
// Sem libs de auth: scrypt (hash de senha) + JWT HMAC, ambos via crypto nativo.
import crypto from "crypto";
import { DynamoDBClient, GetItemCommand, PutItemCommand, QueryCommand,
         DeleteItemCommand, ScanCommand, UpdateItemCommand } from "@aws-sdk/client-dynamodb";
import { marshall, unmarshall } from "@aws-sdk/util-dynamodb";
import { S3Client, GetObjectCommand, PutObjectCommand, DeleteObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const ddb = new DynamoDBClient({});
const s3  = new S3Client({});
const BUCKET = process.env.BUCKET;
const USERS  = process.env.USERS_TABLE;
const MAPS   = process.env.MAPS_TABLE;
const SECRET = process.env.JWT_SECRET;
const ORIGIN = process.env.ALLOW_ORIGIN || "*";

const CORS = {
  "access-control-allow-origin": ORIGIN,
  "access-control-allow-methods": "GET,POST,PUT,PATCH,DELETE,OPTIONS",
  "access-control-allow-headers": "authorization,content-type",
  "access-control-max-age": "3000",
};
const res = (code, obj) => ({ statusCode: code, headers: { ...CORS, "content-type": "application/json" },
  body: obj === "" ? "" : JSON.stringify(obj) });
const body = (e) => { try { return JSON.parse(e.body || "{}"); } catch { return {}; } };

/* ---- senha (scrypt) ---- */
const hashPw = (pw) => { const s = crypto.randomBytes(16); return s.toString("hex") + ":" + crypto.scryptSync(pw, s, 64).toString("hex"); };
const verifyPw = (pw, stored) => { const [s, h] = String(stored).split(":");
  const dk = crypto.scryptSync(pw, Buffer.from(s, "hex"), 64); const hb = Buffer.from(h, "hex");
  return dk.length === hb.length && crypto.timingSafeEqual(dk, hb); };

/* ---- JWT HS256 ---- */
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const sign = (payload) => { const now = Math.floor(Date.now() / 1000);
  const h = b64({ alg: "HS256", typ: "JWT" });
  const p = b64({ ...payload, iat: now, exp: now + 60 * 60 * 24 * 30 });
  const sig = crypto.createHmac("sha256", SECRET).update(h + "." + p).digest("base64url");
  return `${h}.${p}.${sig}`; };
const verify = (t) => { if (!t) return null; const [h, p, s] = t.split(".");
  if (!h || !p || !s) return null;
  const sig = crypto.createHmac("sha256", SECRET).update(h + "." + p).digest("base64url");
  const a = Buffer.from(s), b = Buffer.from(sig);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  const payload = JSON.parse(Buffer.from(p, "base64url"));
  if (payload.exp < Math.floor(Date.now() / 1000)) return null;
  return payload; };
const auth = (e) => verify((e.headers?.authorization || e.headers?.Authorization || "").replace(/^Bearer /, ""));

/* ---- DynamoDB helpers ---- */
const getUser = async (email) => { const r = await ddb.send(new GetItemCommand({ TableName: USERS, Key: marshall({ email }), ConsistentRead: true }));
  return r.Item ? unmarshall(r.Item) : null; };
const putItem = (T, item) => ddb.send(new PutItemCommand({ TableName: T, Item: marshall(item) }));
const pub = (u) => ({ email: u.email, name: u.name, role: u.role, createdAt: u.createdAt, approved: u.approved !== false });
const tokenFor = (u) => sign({ email: u.email, name: u.name, role: u.role });

/* ---- handlers ---- */
async function register(b) {
  const email = (b.email || "").toLowerCase().trim();
  if (!email || !b.password) return res(400, { error: "email e senha são obrigatórios" });
  if (b.password.length < 6) return res(400, { error: "senha mínima de 6 caracteres" });
  if (await getUser(email)) return res(409, { error: "email já cadastrado" });
  const c = await ddb.send(new ScanCommand({ TableName: USERS, Select: "COUNT" }));
  const first = (c.Count || 0) === 0;                       // 1º usuário = admin já aprovado
  const role = first ? "admin" : "user";
  const u = { email, name: b.name || email, role, passwordHash: hashPw(b.password),
    createdAt: new Date().toISOString(), approved: first };
  await putItem(USERS, u);
  if (!first) return res(200, { pending: true });           // demais aguardam aprovação do admin
  return res(200, { token: tokenFor(u), user: pub(u) });
}
async function login(b) {
  const email = (b.email || "").toLowerCase().trim();
  const u = await getUser(email);
  if (!u || !verifyPw(b.password || "", u.passwordHash)) return res(401, { error: "email ou senha inválidos" });
  if (u.approved === false) return res(403, { error: "Conta aguardando aprovação do administrador." });
  return res(200, { token: tokenFor(u), user: pub(u) });
}
async function changePassword(user, b) {
  const u = await getUser(user.email);
  if (!u || !verifyPw(b.current || "", u.passwordHash)) return res(401, { error: "senha atual incorreta" });
  if (!b.new || b.new.length < 6) return res(400, { error: "nova senha mínima de 6 caracteres" });
  u.passwordHash = hashPw(b.new); await putItem(USERS, u);
  return res(200, { ok: true });
}

const DEFAULT_MAP = (title) => ({ name: title || "Novo mapa",
  nodeData: { id: "root", topic: title || "Tópico Central", children: [
    { id: "c1", topic: "Ideia 1" }, { id: "c2", topic: "Ideia 2" } ] } });
const s3key = (email, id) => `maps/${email}/${id}.json`;

async function listMaps(user) {
  const r = await ddb.send(new QueryCommand({ TableName: MAPS, ConsistentRead: true,
    KeyConditionExpression: "#o = :o", ExpressionAttributeNames: { "#o": "owner" },
    ExpressionAttributeValues: marshall({ ":o": user.email }) }));
  const items = (r.Items || []).map(unmarshall)
    .map(m => ({ id: m.mapId, title: m.title, updatedAt: m.updatedAt }))
    .sort((a, b) => (b.updatedAt || "").localeCompare(a.updatedAt || ""));
  return res(200, { maps: items });
}
async function createMap(user, b) {
  const id = crypto.randomUUID(); const title = (b.title || "Novo mapa").slice(0, 120);
  const now = new Date().toISOString();
  await putItem(MAPS, { owner: user.email, mapId: id, title, updatedAt: now });
  await s3.send(new PutObjectCommand({ Bucket: BUCKET, Key: s3key(user.email, id),
    ContentType: "application/json", Body: JSON.stringify({ ...DEFAULT_MAP(title) }) }));
  return res(200, { id, title, updatedAt: now });
}
async function ownMap(user, id) {
  const r = await ddb.send(new GetItemCommand({ TableName: MAPS, Key: marshall({ owner: user.email, mapId: id }), ConsistentRead: true }));
  return r.Item ? unmarshall(r.Item) : null;
}
async function delMap(user, id) {
  if (!(await ownMap(user, id))) return res(404, { error: "mapa não encontrado" });
  await ddb.send(new DeleteItemCommand({ TableName: MAPS, Key: marshall({ owner: user.email, mapId: id }) }));
  await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: s3key(user.email, id) })).catch(() => {});
  return res(200, { ok: true });
}
async function renameMap(user, id, b) {
  if (!(await ownMap(user, id))) return res(404, { error: "mapa não encontrado" });
  await ddb.send(new UpdateItemCommand({ TableName: MAPS, Key: marshall({ owner: user.email, mapId: id }),
    UpdateExpression: "SET title = :t", ExpressionAttributeValues: marshall({ ":t": (b.title || "Sem título").slice(0, 120) }) }));
  return res(200, { ok: true });
}
async function blobUrl(user, id, op) {
  if (!(await ownMap(user, id))) return res(404, { error: "mapa não encontrado" });
  const Key = s3key(user.email, id);
  const cmd = op === "put"
    ? new PutObjectCommand({ Bucket: BUCKET, Key, ContentType: "application/json" })
    : new GetObjectCommand({ Bucket: BUCKET, Key });
  if (op === "put")
    await ddb.send(new UpdateItemCommand({ TableName: MAPS, Key: marshall({ owner: user.email, mapId: id }),
      UpdateExpression: "SET updatedAt = :u", ExpressionAttributeValues: marshall({ ":u": new Date().toISOString() }) }));
  return res(200, { url: await getSignedUrl(s3, cmd, { expiresIn: 300 }) });
}

/* ---- admin ---- */
async function listUsers() {
  const r = await ddb.send(new ScanCommand({ TableName: USERS }));
  return res(200, { users: (r.Items || []).map(unmarshall).map(pub).sort((a,b)=>(a.createdAt||"").localeCompare(b.createdAt||"")) });
}
async function adminCreate(b) {
  const email = (b.email || "").toLowerCase().trim();
  if (!email || !b.password) return res(400, { error: "email e senha são obrigatórios" });
  if (await getUser(email)) return res(409, { error: "email já cadastrado" });
  const u = { email, name: b.name || email, role: b.role === "admin" ? "admin" : "user",
    passwordHash: hashPw(b.password), createdAt: new Date().toISOString() };
  await putItem(USERS, u); return res(200, { user: pub(u) });
}
async function adminDelete(email) {
  await ddb.send(new DeleteItemCommand({ TableName: USERS, Key: marshall({ email }) }));
  return res(200, { ok: true });
}
async function adminUpdate(email, b) {
  const u = await getUser(email); if (!u) return res(404, { error: "usuário não encontrado" });
  if (b.role) u.role = b.role === "admin" ? "admin" : "user";
  if (b.password) u.passwordHash = hashPw(b.password);
  if (b.name) u.name = b.name;
  if (b.approved !== undefined) u.approved = !!b.approved;
  await putItem(USERS, u); return res(200, { user: pub(u) });
}

export const handler = async (event) => {
  const method = event?.requestContext?.http?.method || "GET";
  const path = event?.rawPath || "/";
  if (method === "OPTIONS") return res(204, "");
  try {
    if (method === "POST" && path === "/auth/register") return await register(body(event));
    if (method === "POST" && path === "/auth/login") return await login(body(event));

    const user = auth(event);
    if (!user) return res(401, { error: "não autenticado" });
    const seg = path.split("/").filter(Boolean);

    if (method === "GET" && path === "/me") return res(200, { email: user.email, name: user.name, role: user.role });
    if (method === "POST" && path === "/auth/password") return await changePassword(user, body(event));

    if (seg[0] === "maps") {
      if (seg.length === 1) {
        if (method === "GET") return await listMaps(user);
        if (method === "POST") return await createMap(user, body(event));
      }
      if (seg.length === 2) {
        if (method === "DELETE") return await delMap(user, seg[1]);
        if (method === "PATCH") return await renameMap(user, seg[1], body(event));
      }
      if (seg.length === 3 && seg[2] === "blob") {
        if (method === "GET") return await blobUrl(user, seg[1], "get");
        if (method === "PUT") return await blobUrl(user, seg[1], "put");
      }
    }
    if (seg[0] === "users") {
      if (user.role !== "admin") return res(403, { error: "acesso restrito a admin" });
      if (seg.length === 1) {
        if (method === "GET") return await listUsers();
        if (method === "POST") return await adminCreate(body(event));
      }
      if (seg.length === 2) {
        const em = decodeURIComponent(seg[1]);
        if (method === "DELETE") return await adminDelete(em);
        if (method === "PATCH") return await adminUpdate(em, body(event));
      }
    }
    return res(404, { error: "rota não encontrada" });
  } catch (e) {
    console.error(e);
    return res(500, { error: String(e?.message || e) });
  }
};
