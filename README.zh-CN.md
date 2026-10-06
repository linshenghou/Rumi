<p align="center">
  <img src="macos/Resources/Branding/RumiIcon.png" width="112" height="112" alt="Rumi 应用图标" />
</p>

<h1 align="center">Rumi</h1>

<p align="center">
  <strong>读懂论文，让知识更近。</strong><br />
  为 Mac 打造的论文阅读与翻译空间。
</p>

<p align="center">
  <a href="docs/rumi/INSTALL.md"><img src="https://img.shields.io/badge/macOS-14%2B-333333?style=flat-square" alt="macOS 14 及以上" /></a>
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-333333?style=flat-square" alt="Apple Silicon" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-6655a5?style=flat-square" alt="AGPL-3.0 开源许可" /></a>
  <a href="docs/rumi/BETA_RELEASE.md"><img src="https://img.shields.io/badge/community_beta-in_preparation-bb8536?style=flat-square" alt="社区 Beta 准备中" /></a>
</p>

<p align="center">
  <a href="#获取-rumi"><strong>获取 Rumi</strong></a> ·
  <a href="#用-rumi-做什么">功能介绍</a> ·
  <a href="docs/rumi/BUILD.md">从源码构建</a> ·
  <a href="https://github.com/linshenghou/Rumi/issues">问题反馈</a> ·
  <a href="README.md">English</a>
</p>

<br />

## 用 Rumi 做什么

### <img src="docs/rumi/images/native-import.png" width="32" height="32" alt="" /> 导入就能读

拖入 PDF，或粘贴 arXiv 链接。本地阅读与查找，离线也可用。

### <img src="docs/rumi/images/native-translate.png" width="32" height="32" alt="" /> 按需翻译

选好语言和页码，使用自己的 API 翻译需要的内容。

### <img src="docs/rumi/images/native-compare.png" width="32" height="32" alt="" /> 随时对照

原文、译文、双语 PDF 随时切换，按需导出对应版本。

### <img src="docs/rumi/images/native-service.png" width="32" height="32" alt="" /> 服务自己选

接入 DeepSeek 或 OpenAI 兼容服务，密钥保存在 macOS 钥匙串。

为 **Apple Silicon** 打造，支持 **简体中文与英文** 界面。内置翻译引擎，无需安装 Python。

## 获取 Rumi

> [!NOTE]
> **0.3.0 Beta 1 正在准备中，尚无公开 DMG。** 可关注 [Releases](https://github.com/linshenghou/Rumi/releases) 等待首个社区版本，或[从源码构建](docs/rumi/BUILD.md)。

| 平台 | 当前状态 |
| :--- | :--- |
| macOS 14 及以上 · Apple Silicon | 完成[发布验收](docs/rumi/RELEASE_CHECKLIST.md)后开放社区 Beta |

社区 DMG **未经过 Developer ID 签名和 Apple 公证**。首次打开请参照[安装说明](docs/rumi/INSTALL.md)，后续通过 Releases 手动更新。

### 从论文到译文，只需三步

1. **导入论文。** 拖入 PDF，或用 ⌘⇧O 添加 arXiv 链接。
2. **接入 API。** 在“设置 → 翻译服务”中填写服务地址、模型和密钥并保存。
3. **翻译对照。** 选择页码后按 ⌘↩ 开始翻译，切换版本阅读，用 ⌘⇧E 导出。

Rumi 本身免费。翻译和连接测试的 API 费用由你的服务商收取。翻译会向该服务发送文档文本，本地阅读无需 API。[查看隐私说明 →](PRIVACY.md)

<details>
<summary><strong>试用 Beta 前需要了解</strong></summary>

- 排版与翻译质量因文档而异，参见[已知问题](docs/rumi/KNOWN_ISSUES.md)。
- 首版不支持 Intel Mac、托管 API 或自动更新。
- Rumi 不加入遥测，文稿和设置保存在本地。
- 升级保留原有文稿记录。旧版密钥仅在点击“从旧版应用导入 Key”后读取，保存后写入 Rumi。导入失败不会删除旧密钥。[升级说明](docs/rumi/INSTALL.md#upgrading)。

</details>

## 一起改进 Rumi

遇到阅读问题、有功能建议，或想贡献代码？欢迎从 [Issues](https://github.com/linshenghou/Rumi/issues)、[贡献指南](CONTRIBUTING.md)和[路线图](docs/rumi/ROADMAP.md)开始。开发检查使用本地模拟 API，贡献者无需付费密钥。

[构建说明](docs/rumi/BUILD.md) · [行为守则](CODE_OF_CONDUCT.md) · [私密报告安全问题](SECURITY.md)

## 基于开源，回馈开源

Rumi 是独立维护的 [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next) fork，由 [BabelDOC](https://github.com/funstory-ai/BabelDOC) 提供翻译引擎。感谢上游项目的工作。Rumi 保留上游历史、版权声明与 [AGPL-3.0 许可](LICENSE)。

每个二进制版本必须提供匹配的完整源码、依赖信息、构建说明和校验值。第三方组件保留各自许可，[再分发核对](docs/rumi/LICENSE_REVIEW.md)完成前不公开二进制。上游原始文档保留在 [README-upstream.md](README-upstream.md)。
