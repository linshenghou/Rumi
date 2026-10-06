# Rumi privacy / 隐私说明

Rumi has no account service, analytics, telemetry, crash-upload service or automatic update check. It does not operate a translation server. This describes the standalone macOS community beta; upstream CLI/Web UI behavior can differ.

| Action | Data flow |
| --- | --- |
| Open/read/import a local PDF | PDFKit reads the local file. Import alone does not call a translation API. |
| Translate | Local Python/BabelDOC performs layout analysis and typesetting. Extracted text, paragraph/terminology context, language instructions and your selected model are sent to your chosen API endpoint using your API key. Treat the selected document content as disclosed to that provider; its retention, region and billing policies apply. |
| Test connection | A short test prompt and your API credential go to the configured endpoint. This may be billed. |
| arXiv download | An HTTPS request for the paper identifier/version goes directly to arxiv.org / www.arxiv.org. arXiv receives ordinary request metadata, including your network address and Rumi user-agent. API keys are not sent to arXiv. “Download and Translate” additionally starts the translation flow. |
| Open help, source or Releases links | Your browser connects to GitHub (or the linked upstream site), whose own privacy policy applies. Updates are manual. |

HTTPS is required for remote API endpoints; loopback HTTP is allowed for local servers. The selected provider receives the API credential. Check the endpoint before saving; an OpenAI-compatible endpoint is operated by its URL owner, not necessarily OpenAI.

## Local storage and removal

- Preferences and paper history: `~/Library/Application Support/PDFTranslate/preferences.json` and `jobs.json`. These contain service/model settings and local paper/output paths, never the API key. The historic directory name remains to preserve upgrades.
- Downloaded papers: `~/Library/Application Support/PDFTranslate/Downloads/`. Original local imports remain at their selected paths.
- Results: the output folder selected in Settings. Translation creates separate run directories; previous successful results survive a failed retry. Working data and generated terminology files can contain document text.
- Engine assets and translation caches: `~/Library/Caches/PDFTranslate/Engine/`. Cache databases and working files can contain source/translated text; these are local, not encrypted by Rumi. Bundled assets restore a missing asset cache without downloading models.
- API keys: this Mac's Keychain, under the independent service `io.github.linshenghou.rumi.api-key` (search for this in Keychain Access). Keys pass to the child engine through an anonymous stdin pipe, not command-line arguments. They exist in process memory while in use. Raw third-party diagnostics are suppressed by the desktop bridge.
- Legacy configuration/keychain: read only after an explicit import action. Imported credentials stay in the settings draft until Save. No legacy key is automatically read or deleted. Old migration backups are retained.

Removing a sidebar entry only removes the record, not files. Quitting or uninstalling the app does not delete papers, output, caches or Keychain items. To erase data, first back up anything needed, quit Rumi, remove the named data/cache directories and selected outputs/downloads, and remove the Rumi API-key entry using Keychain Access. Review the old preview's separate entry if you imported it. OS backups, Keychain security prompts and Gatekeeper checks are controlled by macOS.

## 中文摘要

本版不收集遥测，不提供账户或托管翻译服务。打开本地 PDF 不调用 API；翻译时，本地处理版面，将待翻译文本、术语和上下文发送到你设置的服务地址，费用与数据保留规则由服务商决定。“测试连接”也会发出一次简短请求。arXiv 下载直接连接 arXiv，不向其发送 API Key。

文稿记录、下载、输出和缓存保存在本机，可能包含论文正文；Rumi 不额外加密这些文件。Key 保存在 macOS 钥匙串，通过匿名管道传给引擎。旧配置与旧 Key 仅在主动导入时读取，保存前不会写入新的钥匙串条目。移除列表记录或卸载 App 不会删除原文、译文或 Key。路径和清理方式见上文。

Questions: [Issues](https://github.com/linshenghou/Rumi/issues). Sensitive reports: [SECURITY.md](SECURITY.md).
