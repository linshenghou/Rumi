# Rumi

**让知识更近。** 免费开源的原生 macOS 论文阅读与翻译 App，使用你自己的 API。

[English](README.md) · [Releases（Beta 准备中）](https://github.com/linshenghou/Rumi/releases) · [安装说明](docs/rumi/INSTALL.md) · [隐私说明](PRIVACY.md) · [贡献指南](CONTRIBUTING.md)

<p align="center">
  <img src="docs/rumi/images/translate-action.png" width="300" alt="Rumi 的再次翻译按钮" />
</p>

**读论文，按需翻译，随时对照。**

- **导入论文**：拖入 PDF，或粘贴 arXiv 链接。
- **按需翻译**：选好 API、语言与页码，点击“翻译”。
- **双语对照**：原文、译文、双语随时切换，需要时导出副本。

## 社区 Beta

首版 **Rumi 0.3.0 Beta 1 正在准备中，尚无公开二进制下载**。只下载正式公开的 Release 附件；草稿和本机构建尚未完成公开验收。社区测试版**未经过 Developer ID 签名和 Apple 公证**，首次打开可能出现系统提示，请按[安装说明](docs/rumi/INSTALL.md)操作。

支持 Apple Silicon（M1 及更新芯片）、macOS 14 及以上，不支持 Intel。内置 Python、字体与版面模型，无需安装 Python 或首次下载模型；本地 PDF 可离线阅读。

支持 PDF / 文件夹导入、arXiv 链接下载、翻译队列、原文 / 译文 / 双语切换、查找、缩放和导出。界面支持英文和简体中文。Rumi 本身免费，DeepSeek 或 OpenAI 兼容 API 的费用由你选择的服务商收取；翻译内容会发送至该服务商。

首版不提供账户、支付、托管 API、遥测或自动更新，也不上架 Mac App Store。排版与翻译仍有限制，参见[已知问题](docs/rumi/KNOWN_ISSUES.md)。

## 三步入门

1. 从 [Releases](https://github.com/linshenghou/Rumi/releases) 下载 arm64 DMG 与 SHA-256 校验文件，验证后拖入 Applications。
2. 在“设置 → 翻译服务”填写自己的服务地址、模型和 API Key 并保存。“测试连接”会产生一次简短 API 请求，可能计费。
3. 拖入 PDF（⌘O）或添加 arXiv 链接（⌘⇧O），先阅读，选择页码后翻译（⌘↩），切换版本或导出（⌘⇧E）。

升级保留原有文稿记录；旧版钥匙串凭据仅在点击“从旧版应用导入 Key”后读取，保存后写入 Rumi。失败可重新填写，不删除旧数据。更多操作见[macOS 文档](macos/README.md)。

## 参与和许可

欢迎提交 [Issues](https://github.com/linshenghou/Rumi/issues) 和 PR，参见[贡献指南](CONTRIBUTING.md)与[路线图](docs/rumi/ROADMAP.md)。安全问题按 [SECURITY.md](SECURITY.md) 私密报告，切勿公开 API Key 或私人论文。

Rumi 是独立维护的 [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next) fork，基于 [BabelDOC](https://github.com/funstory-ai/BabelDOC)，保留上游历史、署名与 [AGPL-3.0](LICENSE)。每个二进制发布必须提供匹配的完整源码、构建说明、依赖与许可清单、SHA-256。第三方资源保留各自许可，[再分发核对](docs/rumi/LICENSE_REVIEW.md)未完成前不公开二进制。
