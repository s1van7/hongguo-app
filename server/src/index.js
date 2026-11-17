/**
 * 影屿同步服务（Cloudflare Worker + D1）
 *
 * 设计要点：
 * - 密码从不上传：客户端用 PBKDF2 把「用户名 + 密码」拉伸成 authKey，服务端只存
 *   SHA-256(authKey + pepper)。数据库泄露也拿不到可登录的凭据。
 * - 会话用随机 token，库里只存 token 的 SHA-256。
 * - 数据同步是整份快照（与 App 的备份文件同一份 JSON），用 rev 做乐观锁。
 */

const USERNAME_PATTERN = /^[a-zA-Z0-9_\u4e00-\u9fa5-]{2,24}$/;
const MAX_PAYLOAD_BYTES = 900 * 1024;
const SESSION_TTL_MS = 90 * 24 * 60 * 60 * 1000;

const encoder = new TextEncoder();

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    },
  });
}

function fail(message, status = 400) {
  return json({ error: message }, status);
}

function toHex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256(text) {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(text));
  return toHex(new Uint8Array(digest));
}

function equal(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i += 1) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function normalize(username) {
  return String(username ?? '').trim().toLowerCase();
}

async function verifier(authKey, username, pepper) {
  return sha256(`${authKey}|${username}|${pepper}`);
}

async function readBody(request) {
  const raw = await request.text();
  if (raw.length > MAX_PAYLOAD_BYTES + 4096) throw new Error('请求体过大');
  try {
    return JSON.parse(raw);
  } catch {
    throw new Error('请求格式不正确');
  }
}

async function authenticate(request, env) {
  const header = request.headers.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!token) return null;
  const tokenHash = await sha256(token);
  const row = await env.DB.prepare(
    'SELECT user_id, expires_at FROM sessions WHERE token_hash = ?',
  )
    .bind(tokenHash)
    .first();
  if (!row) return null;
  if (row.expires_at < Date.now()) {
    await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(tokenHash).run();
    return null;
  }
  return row.user_id;
}

async function issueToken(env, userId) {
  const token = toHex(crypto.getRandomValues(new Uint8Array(32)));
  const tokenHash = await sha256(token);
  const now = Date.now();
  await env.DB.prepare(
    'INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)',
  )
    .bind(tokenHash, userId, now, now + SESSION_TTL_MS)
    .run();
  return token;
}

async function handleRegister(request, env) {
  const body = await readBody(request);
  const username = String(body.username ?? '').trim();
  const key = normalize(username);
  const authKey = String(body.authKey ?? '');
  if (!USERNAME_PATTERN.test(username)) return fail('用户名需 2-24 位，只能包含中英文、数字、下划线和短横线');
  if (!/^[0-9a-f]{64}$/.test(authKey)) return fail('密码校验值格式不正确');
  const exists = await env.DB.prepare('SELECT id FROM users WHERE username_key = ?').bind(key).first();
  if (exists) return fail('这个用户名已经被占用', 409);
  const id = toHex(crypto.getRandomValues(new Uint8Array(16)));
  const now = Date.now();
  await env.DB.prepare(
    'INSERT INTO users (id, username, username_key, verifier, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
  )
    .bind(id, username, key, await verifier(authKey, key, env.PEPPER ?? ''), now, now)
    .run();
  const token = await issueToken(env, id);
  return json({ token, username, rev: 0, updatedAt: 0 });
}

async function handleLogin(request, env) {
  const body = await readBody(request);
  const key = normalize(body.username);
  const authKey = String(body.authKey ?? '');
  if (!key || !/^[0-9a-f]{64}$/.test(authKey)) return fail('用户名或密码不正确', 401);
  const user = await env.DB.prepare(
    'SELECT id, username, verifier FROM users WHERE username_key = ?',
  )
    .bind(key)
    .first();
  if (!user) return fail('用户名或密码不正确', 401);
  const expected = await verifier(authKey, key, env.PEPPER ?? '');
  if (!equal(expected, user.verifier)) return fail('用户名或密码不正确', 401);
  const token = await issueToken(env, user.id);
  const snapshot = await env.DB.prepare('SELECT rev, updated_at FROM snapshots WHERE user_id = ?')
    .bind(user.id)
    .first();
  return json({
    token,
    username: user.username,
    rev: snapshot?.rev ?? 0,
    updatedAt: snapshot?.updated_at ?? 0,
  });
}

async function handleState(userId, env) {
  const user = await env.DB.prepare('SELECT username, created_at FROM users WHERE id = ?')
    .bind(userId)
    .first();
  if (!user) return fail('账号不存在', 401);
  const snapshot = await env.DB.prepare(
    'SELECT rev, updated_at, device, length(payload) AS bytes FROM snapshots WHERE user_id = ?',
  )
    .bind(userId)
    .first();
  return json({
    username: user.username,
    createdAt: user.created_at,
    rev: snapshot?.rev ?? 0,
    updatedAt: snapshot?.updated_at ?? 0,
    device: snapshot?.device ?? '',
    bytes: snapshot?.bytes ?? 0,
  });
}

async function handlePull(userId, env) {
  const snapshot = await env.DB.prepare(
    'SELECT rev, updated_at, device, payload FROM snapshots WHERE user_id = ?',
  )
    .bind(userId)
    .first();
  if (!snapshot) return json({ rev: 0, updatedAt: 0, device: '', payload: '' });
  return json({
    rev: snapshot.rev,
    updatedAt: snapshot.updated_at,
    device: snapshot.device ?? '',
    payload: snapshot.payload,
  });
}

async function handlePush(request, userId, env) {
  const body = await readBody(request);
  const payload = typeof body.payload === 'string' ? body.payload : '';
  const baseRev = Number(body.rev ?? 0);
  const device = String(body.device ?? '').slice(0, 60);
  if (!payload) return fail('同步内容为空');
  if (encoder.encode(payload).length > MAX_PAYLOAD_BYTES) return fail('同步内容过大', 413);
  const current = await env.DB.prepare('SELECT rev FROM snapshots WHERE user_id = ?')
    .bind(userId)
    .first();
  const rev = current?.rev ?? 0;
  if (rev !== baseRev) return json({ error: '云端已有更新', rev }, 409);
  const next = rev + 1;
  const now = Date.now();
  await env.DB.prepare(
    `INSERT INTO snapshots (user_id, rev, updated_at, device, payload) VALUES (?, ?, ?, ?, ?)
     ON CONFLICT(user_id) DO UPDATE SET rev = excluded.rev, updated_at = excluded.updated_at,
       device = excluded.device, payload = excluded.payload`,
  )
    .bind(userId, next, now, device, payload)
    .run();
  return json({ rev: next, updatedAt: now });
}

async function handleLogout(request, env) {
  const header = request.headers.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (token) {
    await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await sha256(token)).run();
  }
  return json({ ok: true });
}

async function handleDelete(userId, env) {
  await env.DB.batch([
    env.DB.prepare('DELETE FROM snapshots WHERE user_id = ?').bind(userId),
    env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(userId),
    env.DB.prepare('DELETE FROM users WHERE id = ?').bind(userId),
  ]);
  return json({ ok: true });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';
    if (request.method === 'OPTIONS') {
      return new Response(null, {
        status: 204,
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-headers': 'authorization, content-type',
          'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
        },
      });
    }
    try {
      if (path === '/' || path === '/v1/health') {
        return json({ ok: true, service: 'yingyu-sync' });
      }
      if (path === '/v1/register' && request.method === 'POST') {
        return await handleRegister(request, env);
      }
      if (path === '/v1/login' && request.method === 'POST') {
        return await handleLogin(request, env);
      }
      if (path === '/v1/logout' && request.method === 'POST') {
        return await handleLogout(request, env);
      }
      const userId = await authenticate(request, env);
      if (!userId) return fail('登录已过期，请重新登录', 401);
      if (path === '/v1/state' && request.method === 'GET') {
        return await handleState(userId, env);
      }
      if (path === '/v1/sync' && request.method === 'GET') {
        return await handlePull(userId, env);
      }
      if (path === '/v1/sync' && request.method === 'PUT') {
        return await handlePush(request, userId, env);
      }
      if (path === '/v1/account' && request.method === 'DELETE') {
        return await handleDelete(userId, env);
      }
      return fail('接口不存在', 404);
    } catch (error) {
      return fail(error instanceof Error ? error.message : '服务器错误', 500);
    }
  },
};
