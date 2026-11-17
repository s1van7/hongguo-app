/**
 * 影屿同步服务（VPS / Node 版）
 *
 * 与 Cloudflare Worker 版（server/src/index.js）接口完全一致，方便自建：
 * 直接把 Node 跑在 127.0.0.1，前面挂 nginx 做 TLS 即可。
 *
 * - 密码从不上传：客户端用 PBKDF2 把「用户名 + 密码」拉伸成 authKey，服务端只存
 *   SHA-256(authKey + 用户名 + pepper)。数据库泄露也拿不到可登录的凭据。
 * - 会话用随机 token，库里只存 token 的 SHA-256。
 * - 数据同步是整份快照（与 App 的备份文件同一份 JSON），用 rev 做乐观锁。
 *
 * 环境变量：
 *   PORT    监听端口，默认 8790
 *   HOST    监听地址，默认 127.0.0.1
 *   DB      数据库文件路径，默认 ./data/yingyu.db
 *   PEPPER  密码校验盐，必须设置且不要外泄
 */

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

const PORT = Number(process.env.PORT || 8790);
const HOST = process.env.HOST || '127.0.0.1';
const DB_PATH = process.env.DB || path.join(__dirname, 'data', 'yingyu.db');
const PEPPER = process.env.PEPPER || '';

const USERNAME_PATTERN = /^[a-zA-Z0-9_\u4e00-\u9fa5-]{2,24}$/;
const MAX_PAYLOAD_BYTES = 900 * 1024;
const SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;

if (!PEPPER) {
  console.error('缺少 PEPPER 环境变量，拒绝启动');
  process.exit(1);
}

fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });
const db = new DatabaseSync(DB_PATH);
db.exec(`
  PRAGMA journal_mode = WAL;
  CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    username_key TEXT NOT NULL UNIQUE,
    verifier TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id);
  CREATE TABLE IF NOT EXISTS snapshots (
    user_id TEXT PRIMARY KEY,
    rev INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    device TEXT NOT NULL DEFAULT '',
    payload TEXT NOT NULL
  );
`);

const sha256 = (text) => crypto.createHash('sha256').update(text, 'utf8').digest('hex');
const randomHex = (bytes) => crypto.randomBytes(bytes).toString('hex');
const verifierOf = (authKey, username) => sha256(`${authKey}|${username}|${PEPPER}`);
const normalize = (username) => String(username ?? '').trim().toLowerCase();

function equal(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

function send(res, data, status = 200) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
  });
  res.end(body);
}

const fail = (res, message, status = 400) => send(res, { error: message }, status);

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_PAYLOAD_BYTES + 8192) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error('请求格式不正确'));
      }
    });
    req.on('error', reject);
  });
}

function authenticate(req) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!token) return null;
  const tokenHash = sha256(token);
  const row = db.prepare('SELECT user_id, expires_at FROM sessions WHERE token_hash = ?').get(tokenHash);
  if (!row) return null;
  if (Number(row.expires_at) < Date.now()) {
    db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(tokenHash);
    return null;
  }
  return row.user_id;
}

function issueToken(userId) {
  const token = randomHex(32);
  const now = Date.now();
  db.prepare('INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)')
    .run(sha256(token), userId, now, now + SESSION_TTL_MS);
  return token;
}

function handleRegister(res, body) {
  const username = String(body.username ?? '').trim();
  const key = normalize(username);
  const authKey = String(body.authKey ?? '');
  if (!USERNAME_PATTERN.test(username)) return fail(res, '用户名需 2-24 位，只能包含中英文、数字、下划线和短横线');
  if (!/^[0-9a-f]{64}$/.test(authKey)) return fail(res, '密码校验值格式不正确');
  const exists = db.prepare('SELECT id FROM users WHERE username_key = ?').get(key);
  if (exists) return fail(res, '这个用户名已经被占用', 409);
  const id = randomHex(16);
  const now = Date.now();
  db.prepare('INSERT INTO users (id, username, username_key, verifier, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
    .run(id, username, key, verifierOf(authKey, key), now, now);
  return send(res, { token: issueToken(id), username, rev: 0, updatedAt: 0 });
}

function handleLogin(res, body) {
  const key = normalize(body.username);
  const authKey = String(body.authKey ?? '');
  if (!key || !/^[0-9a-f]{64}$/.test(authKey)) return fail(res, '用户名或密码不正确', 401);
  const user = db.prepare('SELECT id, username, verifier FROM users WHERE username_key = ?').get(key);
  if (!user) return fail(res, '用户名或密码不正确', 401);
  if (!equal(verifierOf(authKey, key), user.verifier)) return fail(res, '用户名或密码不正确', 401);
  const snapshot = db.prepare('SELECT rev, updated_at FROM snapshots WHERE user_id = ?').get(user.id);
  return send(res, {
    token: issueToken(user.id),
    username: user.username,
    rev: snapshot ? Number(snapshot.rev) : 0,
    updatedAt: snapshot ? Number(snapshot.updated_at) : 0,
  });
}

function handleState(res, userId) {
  const user = db.prepare('SELECT username, created_at FROM users WHERE id = ?').get(userId);
  if (!user) return fail(res, '账号不存在', 401);
  const snapshot = db
    .prepare('SELECT rev, updated_at, device, length(payload) AS bytes FROM snapshots WHERE user_id = ?')
    .get(userId);
  return send(res, {
    username: user.username,
    createdAt: Number(user.created_at),
    rev: snapshot ? Number(snapshot.rev) : 0,
    updatedAt: snapshot ? Number(snapshot.updated_at) : 0,
    device: snapshot ? snapshot.device || '' : '',
    bytes: snapshot ? Number(snapshot.bytes) : 0,
  });
}

function handlePull(res, userId) {
  const snapshot = db.prepare('SELECT rev, updated_at, device, payload FROM snapshots WHERE user_id = ?').get(userId);
  if (!snapshot) return send(res, { rev: 0, updatedAt: 0, device: '', payload: '' });
  return send(res, {
    rev: Number(snapshot.rev),
    updatedAt: Number(snapshot.updated_at),
    device: snapshot.device || '',
    payload: snapshot.payload,
  });
}

function handlePush(res, userId, body) {
  const payload = typeof body.payload === 'string' ? body.payload : '';
  const baseRev = Number(body.rev ?? 0);
  const device = String(body.device ?? '').slice(0, 60);
  if (!payload) return fail(res, '同步内容为空');
  if (Buffer.byteLength(payload) > MAX_PAYLOAD_BYTES) return fail(res, '同步内容过大', 413);
  const current = db.prepare('SELECT rev FROM snapshots WHERE user_id = ?').get(userId);
  const rev = current ? Number(current.rev) : 0;
  if (rev !== baseRev) return send(res, { error: '云端已有更新', rev }, 409);
  const next = rev + 1;
  const now = Date.now();
  db.prepare(
    `INSERT INTO snapshots (user_id, rev, updated_at, device, payload) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET rev = excluded.rev, updated_at = excluded.updated_at,
       device = excluded.device, payload = excluded.payload`,
  ).run(userId, next, now, device, payload);
  return send(res, { rev: next, updatedAt: now });
}

function handleLogout(res, req) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (token) db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(sha256(token));
  return send(res, { ok: true });
}

function handleDelete(res, userId) {
  db.prepare('DELETE FROM snapshots WHERE user_id = ?').run(userId);
  db.prepare('DELETE FROM sessions WHERE user_id = ?').run(userId);
  db.prepare('DELETE FROM users WHERE id = ?').run(userId);
  return send(res, { ok: true });
}

const server = http.createServer(async (req, res) => {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-headers', 'authorization, content-type');
  res.setHeader('access-control-allow-methods', 'GET, POST, PUT, DELETE, OPTIONS');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }
  const pathname = new URL(req.url, 'http://localhost').pathname.replace(/\/+$/, '') || '/';
  try {
    if (pathname === '/' || pathname === '/v1/health') {
      return send(res, { ok: true, service: 'yingyu-sync', runtime: 'node' });
    }
    if (pathname === '/v1/register' && req.method === 'POST') {
      return handleRegister(res, await readBody(req));
    }
    if (pathname === '/v1/login' && req.method === 'POST') {
      return handleLogin(res, await readBody(req));
    }
    if (pathname === '/v1/logout' && req.method === 'POST') {
      return handleLogout(res, req);
    }
    const userId = authenticate(req);
    if (!userId) return fail(res, '登录已过期，请重新登录', 401);
    if (pathname === '/v1/state' && req.method === 'GET') return handleState(res, userId);
    if (pathname === '/v1/sync' && req.method === 'GET') return handlePull(res, userId);
    if (pathname === '/v1/sync' && req.method === 'PUT') return handlePush(res, userId, await readBody(req));
    if (pathname === '/v1/account' && req.method === 'DELETE') return handleDelete(res, userId);
    return fail(res, '接口不存在', 404);
  } catch (error) {
    console.error('[error]', pathname, error && error.message);
    return fail(res, error instanceof Error ? error.message : '服务器错误', 500);
  }
});

server.listen(PORT, HOST, () => {
  console.log(`影屿同步服务已启动 http://${HOST}:${PORT}  db=${DB_PATH}`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => {
      try {
        db.close();
      } catch {}
      process.exit(0);
    });
  });
}
