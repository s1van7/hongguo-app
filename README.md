# 影屿

跨平台影视客户端，Android 手机 / 电视 / Windows 共用一套界面和同一份数据。

## 下载

所有安装包都在 [Releases](https://github.com/s1van7/yingyu/releases/latest)，点文件名直接下载：

| 设备 | 文件 |
| --- | --- |
| Android 手机（7.0+，arm64） | `yingyu-<版本>-arm64-v8a.apk` |
| 较老的 32 位手机 | `yingyu-<版本>-armeabi-v7a.apk` |
| 模拟器 / x86 设备 | `yingyu-<版本>-x86_64.apk` |
| Windows 10/11 x64 | `yingyu-<版本>-windows-x64-setup.exe`（安装包）或 `yingyu-<版本>-windows-x64.zip`（便携版） |

- 三个 Android 包签名相同，可以互相覆盖升级。
- 包名 `com.yingyu.app`。**从旧版本（`com.hongguo.app`）换过来需要先卸载旧应用**，系统会把它们当成两个不同的应用，本地数据不会自动带过来。
- Windows 便携版解压后运行 `yingyu.exe`，设置、记录、缓存和默认下载都在程序旁的 `userdata` 目录，升级时把旧 `userdata` 拷过去即可。

## 站源

- 站源随安装包内置，不提供模块商店，也不能从文件或地址安装其他站源。
- 站源支持热更新：启动时自动检查，也可以在 **设置 › 关于** 手动检查。更新只替换站源脚本，不用重新装应用。
- 站源接口随时可能变化。出现「暂不可用」时通常是上游接口或签名参数改了，需要更新 `modules_src/hongguo/main.js` 并把 `manifest.json` 的 `version` 往上调。

## 应用内更新

- 启动 2 秒后静默检查一次 GitHub Release，有新版本弹窗提示，点「去下载」打开发布页。
- 可以「忽略此版本」「不再提醒」；**设置 › 关于 › 检查更新** 可手动检查，「启动时检查更新」可随时关掉。

## 功能

发现（推荐 / 全部 / 榜单 / 题材）、搜索与联想、详情与选集、在线播放（弹幕、倍速、清晰度记忆）、追剧、观看记录、下载（解密后转 mp4）、多用户、备份恢复。

## 用 GitHub Actions 出包

推送到 `main` 即自动构建 Android（三个 ABI）与 Windows（安装包 + 便携版），并发布 Release；改文档不会触发构建。版本号取 `pubspec.yaml` 的 `version`（`1.0.0+1` → 产物名 `yingyu-1.0.0-1-...`）。

## 自己构建

```bash
export ANDROID_HOME=~/Android/Sdk
export PATH="$PATH:/path/to/flutter/bin"
# 可选：站源自动更新地址（默认指向本仓库）
export ONLY_SOURCE_UPDATE_BASE=https://raw.githubusercontent.com/<用户名>/yingyu/main/modules_src/hongguo

# Android
python3 scripts/build_android.py --abi arm64-v8a

# Windows（在 Windows 上执行）
python scripts/build_windows.py
```

签名默认用仓库内 `android/hongguo.jks`（密码 `hongguo2026`）。想换成自己的证书，在仓库 Settings › Secrets 里加 `ANDROID_KEYSTORE_BASE64`（keystore 的 base64）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，workflow 会优先用它们。

图标由 `scripts/generate_app_icons.py` 从 `scripts/brand/phone.png`（Android / iOS）和 `scripts/brand/desktop.png`（Windows / macOS）生成，换图后重跑即可。

## 验证情况

构建时用同一份 Go 核心做过接口级验证（`DuanjuRequest` 直连）：

| 检查 | 结果 |
| --- | --- |
| 站源列表 | 只有内置站源，手动塞入其他模块也不加载 |
| 模块商店 / 安装 / 卸载 | 返回「本版本只提供内置站源」 |
| 分类 / 目录 / 详情 | 正常，6 个分类、单页 144 条、31 集章节完整 |
| 站源自动更新 | 1.0.1 → 拉到 1.0.2 → 落盘 → 重启不回滚 → 再次检查为「已是最新」 |
| 取流（resolve） | 沙箱内被上游风控拦截：设备注册 HTTP 444（数据中心 IP、境外网络），需在国内网络或真机验证 |

## 说明与限制

- 本项目遵循 GPL-3.0，完整条款见 `LICENSE`。
- 应用不存储、不上传、不分发影视内容，内容全部来自第三方站点，版权归原权利人所有；不解除源站 VIP 限制。
- 与任何内容平台的运营方无关联，仅供个人学习与技术研究，请勿公开传播安装包，试看内容请于下载后 24 小时内删除。
