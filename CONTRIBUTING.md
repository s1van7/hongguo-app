# 参与开发

本仓库是应用的界面与 Go 运行时，不含任何站源。环境、构建和架构见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 界面与运行时

按 DEVELOPMENT.md 编译 Go 核心，再把示例模块 `native/module_example/jsexample` 放进数据目录的 `modules` 下，目录、分类、搜索和详情都能走通，播放会提示不可用。

提交 PR 时：

- 用户能感知的改动在 `CHANGELOG.md` 当前版本一节补一条。
- 版本号按 `CHANGELOG.md` 顶部的规则走：修订位只到 9，第 10 个版本往前推一位（`1.1.10` → `1.2.0`）。
- 界面改动不写单元测试，在 PR 里写清楚在哪个平台、哪个页面验证过。
- 不新增解释性代码注释，靠命名和模块边界表达意图。
- 不要提交 `android/app/src/main/jniLibs` 里的核心库。

本仓库不接受具体站点的代码，站源请做成独立的站源模块。

## 站源模块

站源是运行时加载的 JS 模块，放在 GitHub 组织 [guoapp-modules](https://github.com/guoapp-modules) 里，一个仓库一个模块。写法见 DEVELOPMENT.md 的[站源模块](DEVELOPMENT.md#站源模块)，模板是 [guoapp-modules/template](https://github.com/guoapp-modules/template)，改进已有模块、新增模块和申请上架见组织的[贡献指南](https://github.com/guoapp-modules/.github/blob/main/CONTRIBUTING.md)。模块接口为第 1 版，不兼容的改动会升级 `api` 版本号。

官方安装包只内置红果模块（代码不在本仓库），其他模块由用户在应用内的模块商店安装，或用 zip 手动安装。商店读取 [guoapp-modules/index](https://github.com/guoapp-modules/index) 的索引，社区模块按其中的规则审核上架。模块的使用和分发责任由其作者和使用者承担。

自行出包时请设置环境变量 `PACKAGE_NAME` 为自己的包名，避免覆盖安装官方版本。

## 模块接口的改动

需要宿主提供新的接口或能力时，欢迎直接提 PR 到本仓库，并在 `CHANGELOG.md` 写明。

## 自建更新分发

应用内的「检查更新」优先读自建清单，拉不到再退回 GitHub Release。

- 清单地址：`https://yy.s1van.top:8448/dl/latest.json`（备用域名 `https://dl.s1van.top/`，走 Cloudflare 隧道）
- 服务器：`/var/www/yy/dl/`，安装包与清单同目录，由 nginx 直接静态分发
- 同步：`yy-update-sync.timer` 每 10 分钟拉一次 GitHub 最新 Release，把 `yingyu-<版本>-arm64-v8a.apk`
  和 `yingyu-<版本>-windows-x64-setup.exe` 镜像到本地，核对大小后把清单切到自建地址；
  镜像没下完时清单里先给加速代理地址，客户端不会因为「本地还没下完」而拿不到新版
- 手动触发：`systemctl start yy-update-sync.service`，日志 `journalctl -u yy-update-sync.service -n 50`
- 只保留最近 3 个版本的安装包，更早的自动清理（脚本里 `prune()`）
- 网盘链接写在 `/etc/yy-lanzou.json`，按平台配，形如 `{"android": "https://...", "windows": "https://..."}`

改了发布流程（产物名、平台）时，同步改 `PLATFORMS` 里的文件名模板，否则该平台会被跳过。
