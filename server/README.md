# 影屿同步服务

Cloudflare Worker + D1，免费额度足够个人用（每天 10 万次请求、5 GB 存储）。

## 当前线上实例

应用默认连的是**自建 VPS 版**（国内直连，比 Cloudflare 稳）：

| 项 | 值 |
| --- | --- |
| 地址 | `https://yy.s1van.top:8448/yingyu` |
| 运行时 | Node 24 + 内置 `node:sqlite`，systemd 服务 `yingyu-sync` |
| 代码 | `/opt/yingyu-sync/server.js`，数据库 `/opt/yingyu-sync/data/yingyu.db` |
| 配置 | `/etc/yingyu-sync.env`（`PEPPER` 等，权限 600） |
| 反代 | nginx `yy.s1van.top:8448` 下的 `location /yingyu/` → `127.0.0.1:8790` |

运维命令：

```bash
systemctl status yingyu-sync      # 看状态
systemctl restart yingyu-sync     # 重启
journalctl -u yingyu-sync -n 50   # 看日志
```

> 为什么不用 80/443：这台机器 443 被 xray 占着，且国内云服务器对未备案域名会在 80 端口直接返回 403，
> 所以用独立子域 `yy.s1van.top` + 8448 端口，证书走 Cloudflare DNS 验证签发。

另有 Cloudflare Worker 版（`server/src/index.js`）作为备选，部署后是
`https://yingyu-sync.<子域>.workers.dev`。国内访问 `workers.dev` 常被拦，所以默认没走它。

客户端默认值在 `lib/account/account_store.dart` 的 `defaultSyncServer`，用户也可以在应用里改。

## 自己部署一套（VPS / Node）

```bash
# 1. 拷代码
mkdir -p /opt/yingyu-sync && cp node/server.js /opt/yingyu-sync/

# 2. 配密钥
echo "PEPPER=$(openssl rand -hex 32)" > /etc/yingyu-sync.env && chmod 600 /etc/yingyu-sync.env

# 3. systemd（见本目录 node/yingyu-sync.service）
cp node/yingyu-sync.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now yingyu-sync

# 4. nginx 反代（记得配 TLS）
#    location /yingyu/ { proxy_pass http://127.0.0.1:8790/; }
```

## 自己部署一套（Cloudflare Worker）

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
