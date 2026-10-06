# Rumi · 原生 macOS 论文翻译

Rumi 面向 Apple Silicon、macOS 14 或更新系统。应用内阅读 PDF，确认后翻译；用户提供自己的 DeepSeek 或 OpenAI 兼容 API。独立版本内置 Python、翻译引擎、字体与版面模型，用户无需配置 Python，也不需要首次下载本地模型。

界面默认跟随 macOS 的语言顺序，支持英文与简体中文，其他语言环境回退到英文。阅读版本切换与更多操作合并为一组原生玻璃控件。翻译中彩色图标的光泽每 2.8 秒柔和呼吸一次；开启“减少动态效果”时保持静止。

## 使用

1. 将 PDF 或文件夹拖入窗口，或按 `⌘O` 添加。本地导入只打开原文，不会调用 API。
   也可以点击“从链接添加…”或按 `⌘⇧O`，粘贴 arXiv 的 HTTPS `/pdf/` 或 `/abs/` 论文链接（包括版本号与旧版论文编号）。“下载并翻译”会下载并加入翻译队列；“仅下载”只打开原文。下载支持进度、取消和失败重试，单份文件上限为 100 MB。
2. 在“设置 → 翻译服务”中填写服务、模型和 API Key，保存后生效。也可主动导入已有 pdf2zh 配置；导入内容先进入草稿，保存后才写入钥匙串。
3. 选择目标语言和页码，点击“翻译”或按 `⌘↩`。支持多选文稿依次翻译；队列暂停会在当前任务结束后生效。
4. 在“原文 / 译文 / 双语”之间切换，按 `⌘F` 查找，底部可跳页与缩放。每个版本分别记住页码和缩放。
5. 从导出菜单保存副本、用“预览”打开，或在 Finder 中显示。`⌘⇧E` 导出当前版本。

翻译中可以继续阅读，关闭主窗口不会中断任务；退出应用会先停止引擎。每次重新翻译创建新的结果目录，失败不会丢失之前的成功结果。移除侧栏记录不删除文件，原文移动后可以通过右键菜单重新定位。

设置和历史记录保存在 `~/Library/Application Support/PDFTranslate/`，不含 API Key。Rumi 沿用此数据路径及缓存以保留设置和文稿记录。bundle ID 与钥匙串服务改为独立的 Rumi 标识；旧 Key 仅在主动点击“从旧版应用导入 Key”后读取，保存后复制到 Rumi，旧数据不删除。从旧版迁移时会保留 `.v1.backup` 文件，已中断和等待中的任务不会自动重启。API Key 只保存在 macOS 钥匙串，并通过匿名管道传给翻译引擎；测试连接本身也会向所选服务发起一次简短请求。

通过链接下载的原文保存在应用数据目录的 `Downloads/` 中，重启后仍可阅读；取消或失败的下载会清理临时文件。未配置 API Key 时，论文会先保留在文稿列表，并提示打开设置。下载本身不会调用翻译服务。

## 独立社区 Beta

构建机需要 Apple Silicon、完整的 Xcode 26 或更新版本（提供分层图标编译器 `actool`）、Python 3.11+ 和 [uv](https://docs.astral.sh/uv/)。首次构建需要联网下载固定的 CPython 3.13.11 与 hash 锁定依赖；所有构建环境位于 `macos/.build/`。运行时不依赖 uv、Homebrew、开发机 venv 或 checkout。

```sh
python3 macos/scripts/build_app.py --dmg
```

产物位于 `artifacts/macos/`：`Rumi.app`、`Rumi-0.3.0-beta.1-arm64-community.dmg`、`Rumi-0.3.0-beta.1-source.tar.gz` 和 `SHA256SUMS.txt`。DMG 卷名为 Rumi，包含应用、Applications 链接与中文说明；校验文件列出本次 DMG 与对应源码包的 SHA-256。**社区 Beta 采用 ad-hoc 签名，未经过 Developer ID 签名和 Apple 公证。** 首发不要求购买 Apple Developer Program；公开分发前必须完成许可核对及真实独立 Mac 验收。首次打开按 [Apple 官方说明](https://support.apple.com/102445)操作，不关闭 Gatekeeper。

仅迭代 Swift 界面时，可复用源码指纹一致的 helper：

```sh
python3 macos/scripts/build_engine.py
python3 macos/scripts/build_app.py --reuse-engine --dmg
```

Rumi 的 bundle ID 由 `Release.json` 中的仓库所有者派生，当前为 `io.github.linshenghou.rumi`，内部可执行文件保持 `Contents/MacOS/PDFTranslate`。helper 位于 `Contents/Helpers/pdftranslate-engine/pdftranslate-engine`，使用 PyInstaller `onedir`，不在启动时解压 runtime。依赖与资源放在 `Contents/Resources/Engine`，通过 helper 旁的 `_internal` 相对符号链接访问，以符合 macOS 的代码与资源签名目录要求。构建过程保留符号链接，检查 helper 的源码指纹，并对嵌套 Mach-O 代码与主应用逐层签名。

应用图标的构建源是 `macos/Resources/Branding/RumiIcon.icon`：铺满画布的紫色背景与独立的扁平蓝莓前景共同组成原生玻璃图标。`build_icon.py` 使用 Apple 的 `actool` 编译 `Assets.car`，并生成兼容旧系统的 `RumiIcon.icns`；编译器提供的 `CFBundleIconName` 和 `CFBundleIconFile` 会合并到 App 的 Info.plist。macOS 26 使用分层图标，避免给旧式图标额外套上白色底板。`BlueberryForeground.png` 保存原始生成图稿，`.icon/Assets/Blueberry.png` 是保留透明通道的 1024 像素导入层，`RumiIcon.png` 仅用作兼容图标预览。源图和生成提示词随对应源码包提供。产品版本、构建号、渠道和仓库归属集中在 `Sources/PDFTranslate/Resources/Release.json`；App、arXiv user-agent、DMG 与源码包共用这份信息。界面语言资源位于 `macos/Sources/PDFTranslate/Resources/`，随 SwiftPM 处理并复制到 App 的资源目录。

## 资源、隐私与许可

构建只按照 BabelDOC 0.6.2 的资源清单收集 182 个资源，约 336 MiB 未压缩，并验证每项 SHA3-256。已有 `~/.cache/babeldoc` 可作为只读的资源种子；只读取清单中的 fonts、models、cmap、tiktoken，**不会复制 working 文档、翻译数据库、配置、API Key 或译文**。也可通过 `--asset-cache` 指定另一资源缓存；缺失资源由构建机下载并验 hash。

首次启动从内置资源恢复本地缓存，位置为 `~/Library/Caches/PDFTranslate/Engine/`，不修改签名后的应用包。每次检查会校验缓存；缓存损坏时从内置资源修复。测试可以设置 `PDFTRANSLATE_CACHE_DIR` 指向独立目录。运行时不下载模型。原项目的旧配置只通过用户主动导入迁移，独立引擎不默认读取开发者的配置。

`Contents/Resources/ThirdPartyNotices` 包含依赖清单、软件许可、实际字体的嵌入式版权声明和资源许可原文。Go Noto 的脚本使用 Unlicense，其字体仍是 OFL。资源许可原文保存在 `macos/packaging/licenses/`，有来源及内容 hash；更新这些文件后需审阅许可证变化。

对应源码包包含应用、构建脚本、依赖锁、适配后的 BabelDOC 源码，以及 copyleft 依赖的上游源码分发包。它必须和对应应用一起提供。整合版本维持 AGPL-3.0，各第三方资源保留各自许可。再分发核对见 [LICENSE_REVIEW.md](../docs/rumi/LICENSE_REVIEW.md)，未解决项阻止公开二进制；许可证收集不等于完成核对。

## 开发与验证

保留使用当前 checkout/Python 的快速开发构建，它不具备可搬移性：

```sh
python3 macos/scripts/build_app.py --development --python .venv/bin/python
swift test --disable-sandbox --package-path macos
.venv/bin/python -m pytest tests/test_desktop_bridge.py
```

独立引擎构建后可执行不计费的验收：

```sh
python3 macos/scripts/verify_engine.py macos/.build/standalone/dist/pdftranslate-engine
macos/.build/standalone/venv/bin/python macos/scripts/smoke_engine.py macos/.build/standalone/dist/pdftranslate-engine/pdftranslate-engine --work artifacts/macos/frozen-fixture-smoke
```

前者检查所有 Mach-O 的 arm64 架构、最低系统版本、动态链接与签名，并验证中文及空格路径搬移、空缓存启动与损坏修复；后者通过本地 OpenAI 协议测试服务完成真实版面分析、子进程翻译与中文 PDF 输出，不调用外部付费 API。

发布验收必须覆盖：无 Python/项目路径的独立机器、带空格和中文的应用路径、离线首次本地资源准备、真实 API 翻译、取消及子进程退出、损坏缓存修复、已签名 bundle 不写入、`codesign --verify --deep --strict` 及 Gatekeeper 首次打开行为。社区版没有公证票据；正式签名、公证与 stapling 留待后续。当前 Intel 不支持；其 ONNX Runtime 版本需单独解析和验证。

`desktop_bridge.py` 通过 stdout 输出 JSON 行。独立 helper 接收 `--check` 或 `--request-stdin`；后者首行是带 `operation` 的 JSON 请求，之后的 `cancel` 用于停止任务。凭据通过 stdin 传递，永不进入命令行。冻结入口先执行 `multiprocessing.freeze_support()`，runtime hook 在每个 spawn worker 的重依赖导入之前隔离 cache/config 路径并关闭 worker 的原始输出。

## 可复核的发布

公开仓库是独立维护的 Rumi fork，保留上游 Git 历史。先完成源码安全扫描和 PR 检查，再提交版本并打与 `Release.json` 匹配的 tag。源码包只收集 Git 已跟踪的输入，不读取任意未跟踪文件；因此首次构建前必须提交 macOS 代码。生成产物全部放在忽略的 `artifacts/` 或 `macos/.build/` 中。

```sh
python3 macos/scripts/install_gitleaks.py
python3 macos/scripts/audit_source.py --history
python3 macos/scripts/release_metadata.py --check-release
python3 macos/scripts/build_app.py --release --dmg
python3 macos/scripts/audit_source.py --history --archive artifacts/macos/Rumi-0.3.0-beta.1-source.tar.gz
python3 macos/scripts/draft_release.py artifacts/macos --dry-run
```

`--release` 拒绝脏工作区或不匹配的 tag。`BUILD.json` 记录提交、Swift/Xcode/macOS/uv 版本、依赖锁摘要与签名状态；引擎另记录固定 Python 版本、依赖摘要与源码指纹。各次构建的字节不承诺完全相同；这些记录用于确认输入与追踪构建环境。

GitHub `Rumi draft release` 工作流只创建草稿，不会公开。完整流程、手工验收表及发布门槛见 [RELEASE_CHECKLIST.md](../docs/rumi/RELEASE_CHECKLIST.md)。不要给上游 PyPI/Docker 发布流程配置凭据；它们已经归档在 `.github/upstream-workflows/`。
