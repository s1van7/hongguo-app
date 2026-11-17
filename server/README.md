# 影屿同步服务

Cloudflare Worker + D1，免费额度足够个人用（每天 10 万次请求、5 GB 存储）。

## 当前线上实例

| 项 | 值 |
| --- | --- |
| 地址 | `https://yingyu-sync.s1van70525.workers.dev` |
| Worker | `yingyu-sync` |
| D1 数据库 | `yingyu`（APAC 区，`9f77e58c-d222-4327-be7c-d353940705be`） |
| 客户端默认值 | `lib/account/account_store.dart` 里的 `defaultSyncServer` |

应用默认就用这个地址，用户不用填。想换自建实例，改那个常量重新打包即可。

## 自己部署一套

```bash
cd server
npx wrangler login                       # 浏览器里点一下授权
npx wrangler d1 create yingyu            # 建库，把 database_id 填进 wrangler.toml
npx wrangler d1 execute yingyu --remote --file=schema.sql
npx wrangler secret put PEPPER           # 随便一串长随机字符串，别外传
npx wrangler deploy
```

部署完会得到一个地址，形如 `https://yingyu-sync.<你的账号>.workers.dev`。
把这个地址填进应用 **我的 › 账号与同步 › 同步服务器**，就能注册账号、跨设备同步了。

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/v1/register` | `{username, authKey}` → `{token, rev}` |
| POST | `/v1/login` | `{username, authKey}` → `{token, rev}` |
| GET | `/v1/state` | 当前账号状态：rev、更新时间、数据大小 |
| GET | `/v1/sync` | 拉取快照 `{rev, updatedAt, device, payload}` |
| PUT | `/v1/sync` | 上传快照 `{rev, payload, device}`，rev 不匹配返回 409 |
| POST | `/v1/logout` | 注销当前 token |
| DELETE | `/v1/account` | 删除账号和全部数据 |

## 安全说明

- **密码不出设备**：客户端用 PBKDF2-SHA256（40000 次，盐取「用户名」）把密码拉伸成
  `authKey`，服务端只存 `SHA-256(authKey|用户名|pepper)`。库被拖走也拿不到能直接登录的凭据。
- 会话 token 是 32 字节随机数，库里只存它的 SHA-256，90 天过期。
- 数据快照是应用自己的备份 JSON（含多用户、追剧、观看记录、偏好设置），按用户隔离。
- 换 `PEPPER` 会让所有已注册账号无法登录，等于全员重注册。

## 本地调试

```bash
cd server
npx wrangler d1 execute yingyu --local --file=schema.sql
npx wrangler dev
```
