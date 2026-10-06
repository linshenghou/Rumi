<p align="center">
  <img src="macos/Resources/Branding/RumiIcon.png" width="112" height="112" alt="Rumi app icon" />
</p>

<h1 align="center">Rumi</h1>

<p align="center">
  <strong>Your papers. Your language.</strong><br />
  A native macOS workspace for reading and translating research papers.
</p>

<p align="center">
  <a href="docs/rumi/INSTALL.md"><img src="https://img.shields.io/badge/macOS-14%2B-333333?style=flat-square" alt="macOS 14 or later" /></a>
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-333333?style=flat-square" alt="Apple Silicon" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0-6655a5?style=flat-square" alt="AGPL-3.0 license" /></a>
  <a href="docs/rumi/BETA_RELEASE.md"><img src="https://img.shields.io/badge/community_beta-in_preparation-bb8536?style=flat-square" alt="Community beta in preparation" /></a>
</p>

<p align="center">
  <a href="#get-rumi"><strong>Get Rumi</strong></a> ·
  <a href="#what-you-can-do">Features</a> ·
  <a href="docs/rumi/BUILD.md">Build from source</a> ·
  <a href="https://github.com/linshenghou/Rumi/issues">Feedback</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<br />

## What you can do

<table>
<tr>
<td width="50%" valign="top">
<h3>Read without the setup</h3>
<p>Drop in a PDF or paste an arXiv link. Read, search and navigate your paper in a native Mac app. Local reading works offline.</p>
<p><sub>PDF &amp; folder import · arXiv · ⌘O</sub></p>
</td>
<td width="50%" valign="top">
<h3>Translate on your terms</h3>
<p>Connect your own API, choose a language and select the pages you need. Translate now, or return to it later.</p>
<img src="docs/rumi/images/translate-action.png" width="232" alt="The Translate Again button in Rumi" />
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>Keep the original close</h3>
<p>Switch between original, translated and bilingual PDFs in the same workspace. Export the version you want to keep.</p>
<p><sub>Original · Translated · Bilingual · Export</sub></p>
</td>
<td width="50%" valign="top">
<h3>Bring your own API</h3>
<p>Use DeepSeek or an OpenAI-compatible service. Keys stay in macOS Keychain. No Rumi account or subscription.</p>
<p><sub>Free app · Your provider bills API usage</sub></p>
</td>
</tr>
</table>

Built for **Apple Silicon**, with an **English and 简体中文** interface. The translation engine is bundled; you don't need to install Python.

## Get Rumi

> [!NOTE]
> **0.3.0 Beta 1 is in preparation.** There is no public DMG yet. Follow [Releases](https://github.com/linshenghou/Rumi/releases) for the first community build, or [build from source](docs/rumi/BUILD.md).

| Platform | Availability |
| :--- | :--- |
| macOS 14+ · Apple Silicon | Community Beta coming after [release acceptance](docs/rumi/RELEASE_CHECKLIST.md) |

The community DMG will be **without Developer ID signing or Apple notarization**. Follow the [installation guide](docs/rumi/INSTALL.md) for first-launch steps. Updates will be available through Releases.

### From a paper to a translation

1. **Bring a paper.** Drag in a PDF, or add an arXiv link with ⌘⇧O.
2. **Connect your API.** Open Settings → Translation Service and save your endpoint, model and key.
3. **Translate and compare.** Choose pages, press ⌘↩, then switch versions or export with ⌘⇧E.

Rumi is free. Your API provider charges for translation and connection tests. Translation sends document text to that provider; local reading needs no API. [Privacy details →](PRIVACY.md)

<details>
<summary><strong>Before you try the Beta</strong></summary>

- Layout and translation quality vary. See [known issues](docs/rumi/KNOWN_ISSUES.md).
- Intel Macs, hosted APIs and automatic updates are outside this first release.
- Rumi includes no telemetry. Documents and settings are stored locally.
- Upgrades preserve existing paper records. To copy a key from the previous app, choose **Import Key from Previous App**, then Save. Import failures leave the old key untouched. [Upgrade guide](docs/rumi/INSTALL.md#upgrading).

</details>

## Make Rumi better

Found a reading issue, have a feature idea, or want to contribute? Start with [Issues](https://github.com/linshenghou/Rumi/issues), the [contribution guide](CONTRIBUTING.md), or the [roadmap](docs/rumi/ROADMAP.md). Development checks use a local mock API, so contributors need no paid key.

[Build instructions](docs/rumi/BUILD.md) · [Code of conduct](CODE_OF_CONDUCT.md) · [Report a security issue privately](SECURITY.md)

## Built on open source

Rumi is an independently maintained fork of [PDFMathTranslate-next](https://github.com/PDFMathTranslate-next/PDFMathTranslate-next), powered by [BabelDOC](https://github.com/funstory-ai/BabelDOC). Their work makes this app possible. Upstream history, copyright notices and the [AGPL-3.0 license](LICENSE) are retained.

Every binary release must ship with its matching complete source, dependency information, build instructions and checksums. Third-party components keep their own licenses; the [redistribution review](docs/rumi/LICENSE_REVIEW.md) must be completed before public binaries are released. The original project's documentation is preserved in [README-upstream.md](README-upstream.md).
