-- 影屿同步服务数据库结构
-- 用法：npx wrangler d1 execute yingyu --remote --file=server/schema.sql

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
