# Rumi 0.3.0 Beta 1

Release candidate: acceptance pending. Do not publish until the release checklist is complete.

A free, open-source macOS paper reader and translator for Apple Silicon, macOS 14+. Bring your own DeepSeek or OpenAI-compatible API; your provider bills usage.

## Changes

- Native PDF and arXiv import, translation queues, original/translated/bilingual reading and export.
- Standalone Python engine with bundled fonts and layout model; no Python install or first-run model download.
- English and Simplified Chinese interface and community documentation.
- Independent Rumi identity; compatible paper history and explicit, non-destructive legacy-key import.
- Central release metadata, reproducible build inputs, PR checks using a local API, and draft-first releases.

## Installation and limitations

This community beta is **not Developer ID signed or Apple notarized**. Follow [installation instructions](https://github.com/linshenghou/Rumi/blob/main/docs/rumi/INSTALL.md) and [known issues](https://github.com/linshenghou/Rumi/blob/main/docs/rumi/KNOWN_ISSUES.md). No Intel support or automatic updater. Layout and translation need human review.

Assets: arm64 DMG, matching complete source archive, `BUILD.json`, `RELEASE_NOTES.md`, and `SHA256SUMS.txt`. The source includes locked dependencies, build scripts, notices and corresponding source packages. Verify the SHA-256 checksum before installing.

[Privacy](https://github.com/linshenghou/Rumi/blob/main/PRIVACY.md) · [Report a bug](https://github.com/linshenghou/Rumi/issues) · [Private security reports](https://github.com/linshenghou/Rumi/security/advisories/new)

Built on PDFMathTranslate-next and BabelDOC. Rumi remains AGPL-3.0; third-party components retain their own terms.
