# Install and update Rumi / 安装与更新

Requires Apple Silicon and macOS 14 or newer. No Python installation is required. Beta 1 is free and open source; bring your own API and pay your provider for usage.

No public binary is available while Beta 1 acceptance is pending.

## Download and verify

Download the arm64 community DMG and `SHA256SUMS.txt` from a published [Rumi Release](https://github.com/linshenghou/Rumi/releases). The source archive, build record, release notes and known issues accompany it. A draft release is awaiting acceptance and is not a public download.

In Terminal, change to the download directory and verify the DMG against its line in the checksum file:

```sh
shasum -a 256 Rumi-0.3.0-beta.1-arm64-community.dmg
```

Compare the entire digest with `SHA256SUMS.txt`. If you downloaded all listed files, use `shasum -a 256 -c SHA256SUMS.txt`. Open the DMG and drag Rumi to Applications; eject the disk and open the installed copy.

## First open on macOS

**This community beta is ad-hoc signed only. It has no Developer ID signature and has not been notarized by Apple.** macOS may block its first launch. We do not promise a prompt-free installation.

After attempting to open a trusted, verified download, Apple documents System Settings → Privacy & Security → Open Anyway, then confirming Open. See [Apple's current instructions](https://support.apple.com/en-us/102445). Managed Macs may prevent this. Do not disable Gatekeeper or remove quarantine as an installation step. If macOS reports malware or a damaged app, stop and report the exact warning; do not treat it as the ordinary unidentified-developer prompt.

中文：将 Rumi 拖入 Applications 后从该位置打开。本社区版未经过 Developer ID 签名与 Apple 公证。核对来源与校验和后，如出现未识别开发者提示，按 [Apple 官方说明](https://support.apple.com/zh-cn/102445)在“系统设置 → 隐私与安全”处理。不要关闭 Gatekeeper；“损坏”或“恶意软件”提示应停止安装并反馈。

## Upgrading

Quit the old app and back up `~/Library/Application Support/PDFTranslate/` plus your output folders. Replace the app in Applications. The independent Rumi bundle ID does not move or delete the existing history/preferences/download directory. Interrupted jobs do not automatically restart. Unknown or unreadable data formats are preserved instead of overwritten.

The new Keychain service `io.github.linshenghou.rumi.api-key` is separate from the preview's `org.pdfmathtranslate.next.desktop.api-key`. Startup and normal key loading never fall back to that entry. In Settings, select the same provider/endpoint and choose **Import Key from Previous App**. macOS may ask permission. Review and Save to copy into Rumi. The old entry is retained. If the import is denied, missing or times out, enter a new key. Existing pdf2zh TOML configuration can also be explicitly imported into a draft.

Downloads and updates are manual through Releases. Read release notes before replacing the app. For a rollback, quit Rumi and restore your backup and previous application; don't run two versions against the same history simultaneously.
