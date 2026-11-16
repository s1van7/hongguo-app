# 红果影视（只播放红果）

基于 [Xanerix/guoapp](https://github.com/Xanerix/guoapp)（小果影视，GPL-3.0）改造：**只保留红果一个站源**，去掉模块商店、站源切换和匿名统计，应用内更新提示改为查 GitHub Release，红果源支持自动更新，Android 与 Windows 由 GitHub Actions 自动构建。

## 下载

| 平台 | 文件 |
| --- | --- |
| Android 手机（7.0+，arm64） | `hongguo-<版本>-arm64-v8a.apk` |
| 较老的 32 位手机 | `hongguo-<版本>-armeabi-v7a.apk` |
| 模拟器 / x86 设备 | `hongguo-<版本>-x86_64.apk` |
| Windows 10/11 x64 | `hongguo-<版本>-windows-x64-setup.exe`（安装包）或 `hongguo-<版本>-windows-x64.zip`（便携版） |

安装包在 [Releases](https://github.com/s1van7/hongguo-app/releases/latest)，直接点文件名下载：

- [hongguo-1.0.0-1-arm64-v8a.apk](https://github.com/s1van7/hongguo-app/releases/latest/download/hongguo-1.0.0-1-arm64-v8a.apk)
- [hongguo-1.0.0-1-armeabi-v7a.apk](https://github.com/s1van7/hongguo-app/releases/latest/download/hongguo-1.0.0-1-armeabi-v7a.apk)
- [hongguo-1.0.0-1-x86_64.apk](https://github.com/s1van7/hongguo-app/releases/latest/download/hongguo-1.0.0-1-x86_64.apk)
- [hongguo-1.0.0-1-windows-x64-setup.exe](https://github.com/s1van7/hongguo-app/releases/latest/download/hongguo-1.0.0-1-windows-x64-setup.exe)
- [hongguo-1.0.0-1-windows-x64.zip](https://github.com/s1van7/hongguo-app/releases/latest/download/hongguo-1.0.0-1-windows-x64.zip)
Android 三个包签名相同，可互相覆盖升级；与小果影视官方版签名不同，**不能覆盖安装官方版**，需先卸载。Windows 便携版解压后运行 `hongguo.exe`，设置、记录、缓存和默认下载都在程序旁的 `userdata` 目录，升级时把旧 `userdata` 拷过去即可。

## 播放取流说明（重要）

红果在 2026-11 中旬把 App 取流接口迁到了 `api5-normal-sinfonlinea.fqnovel.com` 的 `multi_video_model/player/v1`，并换了整套 V5 签名；同时网页端 `/player/...` 改成受保护播放，`videoList` 恒为空。

因此 **1.0.0 版内置的模块（1.0.1）必然报「红果 App 接口未返回有效数据；网页取流失败：该集未提供公开播放地址」**。1.0.1+2 起内置模块升到 **1.0.2**，改走新接口，实测可取到 5 个清晰度的真实 MP4 流。

已经装了旧版的话不用重装：启动时会自动热更新到 1.0.2，也可以在 **设置 › 关于 › 红果源** 手动点一次。再不行就装 1.0.1+2 的新包。

以后再遇到同类报错，优先去模块商店的同源仓库 [guoapp-modules/hongguo](https://github.com/guoapp-modules/hongguo) 看有没有新版本，比等应用更新快。

## 红果源自动更新

站源是运行时加载的 JS 模块，**更新它不需要重新安装应用**：

- 应用启动时会静默检查一次，也可以在 **设置 › 关于 › 红果源** 手动检查。
- 更新地址在构建时写进原生核心，指向本仓库的 `modules_src/hongguo/`：优先 `raw.githubusercontent.com`，失败回退 `cdn.jsdelivr.net`。
- 只有远端 `manifest.json` 的 `version` 比本地新时才会下载 `main.js`，校验能正常解析后写入数据目录并热加载；比本地旧或相同的版本会被忽略，内置版本也不会在下次启动时回滚已更新的模块。

**要让更新生效，改完 `main.js` 记得同时把 `modules_src/hongguo/manifest.json` 的 `version` 往上调**（如 `1.0.1` → `1.0.2`），否则客户端会认为没有新版本。

更新地址只在编译期注入，客户端不接受任意 URL，也不允许换成红果以外的模块。

## 与原项目的差异

| 项目 | 小果影视 | 红果影视 |
| --- | --- | --- |
| 站源 | 内置红果，其余模块商店安装 | 只有红果，模块商店已移除 |
| 站源切换 | 发现页左上角地球按钮 | 单站源，按钮自动隐藏 |
| 我的 › 模块 | 有 | 已移除 |
| 红果源更新 | 随应用版本 | 启动自动检查 + 手动检查，热更新 |
| 检查更新 | 有开关，走自建更新服务器 | 改为查 GitHub Release：启动静默查一次 + 设置里手动查，弹窗直接给下载页 |
| 匿名统计 | 有开关 | 已移除，不发任何请求 |
| 应用名 / 包名 | 小果影视 · `com.guoapp.app` | 红果影视 · `com.hongguo.app` |
| 图标 | 蓝色小果 | 红底白「果」 |

功能保留：发现（推荐 / 全部 / 榜单 / 题材）、搜索与联想、详情与选集、在线播放（弹幕、倍速、清晰度记忆）、追剧、观看记录、下载（解密后转 mp4）、多用户、备份恢复。

## 代码改动

原生核心（Go，站源与请求都在这层，改动即硬约束）：

- `native/core/app_source_list.go`：`sourceList()` 只返回 `hongguo`。
- `native/core/module_loader.go`：只从数据目录加载 `hongguo`，手工放进其他模块也不会加载。
- `native/core/app_runtime.go`：`moduleIndex` / `installModule` / `uninstallModule` / `prepareModule` 直接返回「本版本只提供红果」；新增 `updateSource` 只走红果源更新。
- `native/core/module_index.go`：模块索引与模块文件地址清空，不会访问模块仓库。
- `native/core/only_source_update.go`（新增）：拉取并校验红果源更新，写入数据目录后热加载。

界面（Flutter）：

- `lib/app_build.dart`：应用名「红果影视」。
- `lib/ui/mine/mine_page.dart`、`lib/ui/explore/source_actions.dart`：删除「模块」「管理站源」入口。
- `lib/ui/widgets/source_bar.dart`：新增 `showSwitcher`，单站源时隐藏地球按钮。
- `lib/ui/settings/settings_sections.dart`：删除统计开关，新增「红果源」检查项、「检查更新」「启动时检查更新」开关。
- `lib/main.dart`：启动后静默检查红果源更新。
- `lib/ui/terms_page.dart`：条款改为单站源版本。
- `lib/app_update.dart`、`lib/ui/update_prompt.dart`、`lib/ui/device_registration.dart`：应用内更新提示。启动 2 秒后静默读 `releases/latest` 的重定向拿到最新 tag（不占 GitHub 接口配额，失败再退回 API），比构建号决定是否弹窗；可「忽略此版本」「不再提醒」，设置里能手动检查。
- `android/app/src/main/kotlin/com/guoapp/TextInputBridge.kt`、`lib/native_text_input.dart`、`lib/ui/widgets/search_field.dart`：电视端搜索输入法兼容。隐藏输入框改为布局完成后再弹键盘并自动重试，输入法浮窗抢焦点不再误关，搜索框右侧键盘图标可切换输入法；系统里没有输入法时自动退回内置字母键盘。

内置站源：`modules_src/hongguo/`（`manifest.json` + `main.js`），构建时由 `scripts/build_native.py --bundle modules_src/hongguo` 复制进 `native/core/bundled/`，再由 `go:embed` 编进 `libduanju_core.so`。

## 用 GitHub Actions 出包

`.github/workflows/build.yml`：

- push 到 `main`：自动构建 Android 三个 APK + Windows 安装包/便携版，成功后**直接发布到 Release**（标签 `v<版本号>`，同名标签会覆盖附件）。
- 手动 Run workflow：同样流程，用于重跑。
- 只改 `modules_src/hongguo/main.js` 时不必重新出包，客户端会热更新（记得提升 `manifest.json` 的 `version`）。

签名默认用仓库内 `android/hongguo.jks`（密码 `hongguo2026`）。想换成自己的证书，在仓库 Settings › Secrets 里加 `ANDROID_KEYSTORE_BASE64`（keystore 的 base64）、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，workflow 会优先用它们。

> 仓库内的 keystore 是公开的，只适合自用。若打算分发给别人，请换成 Secrets 里的私有证书。

## 自己构建

环境：Flutter 3.47.9、Dart 3.13、Go 1.26、JDK 17+、Android SDK 36、NDK 28.2.13676358；Windows 版还需要 Visual Studio C++ 桌面组件、MinGW-w64 x64、Inno Setup 6。

```sh
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358
export GOROOT=/path/to/go
# 可选：红果源自动更新地址
export ONLY_SOURCE_UPDATE_BASE=https://raw.githubusercontent.com/<用户名>/<仓库>/main/modules_src/hongguo

# Android
python3 scripts/build_native.py --platform android \
  --abi arm64-v8a --abi armeabi-v7a --abi x86_64 --bundle modules_src/hongguo
flutter pub get
flutter build apk --release --split-per-abi

# Windows（在 Windows 上执行）
python scripts/build_windows.py
```

产物分别在 `build/app/outputs/flutter-apk/` 和 `dist/windows/`。

## 验证情况

构建时用同一份 Go 核心做过接口级验证（`DuanjuRequest` 直连）：

| 检查 | 结果 |
| --- | --- |
| 站源列表 | 只有 `hongguo`，手动塞入其他模块也不加载 |
| 模块商店 / 安装 / 卸载 | 返回「本版本只提供红果」 |
| 分类 / 目录 / 详情 | 正常，6 个分类、单页 144 条、31 集章节完整 |
| 红果源自动更新 | 1.0.1 → 拉到 1.0.2 → 落盘 → 重启不回滚 → 再次检查为「已是最新」 |
| 取流（resolve） | 沙箱内被红果风控拦截：设备注册 HTTP 444（数据中心 IP、境外网络），需在国内网络或真机验证 |

## 说明与限制

- 遵循 GPL-3.0，改造后的源码同样以 GPL-3.0 提供。
- 红果站源模块（`modules_src/hongguo/`）来自小果影视官方安装包内置的模块，**不是公开仓库里的开源代码**，作者未单独开源；它只随本应用一起打包，请勿单独分发。
- 应用不存储、不上传、不分发影视内容，内容全部来自红果短剧站点，版权归原权利人所有；不解除源站 VIP 限制。
- 与红果短剧运营方无任何关联，仅供个人学习与技术研究，请勿公开传播安装包，试看内容请于下载后 24 小时内删除。
- 电视端搜索默认用系统输入法。装了第三方输入法（搜狗、讯飞等）却没弹出，点搜索框右侧的键盘图标选「切换输入法」，或到 设置 › 外观 › 输入法 里切换；遥控器只按字母数字时也可以打开「搜索用字母键盘」。
- 站源接口随时可能变化，出现「红果暂不可用」时通常是上游接口或签名参数改了，需要更新 `modules_src/hongguo/main.js` 并提升版本号。
