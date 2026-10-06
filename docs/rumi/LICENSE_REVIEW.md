# Redistribution review

Status: **incomplete; public binary release is blocked**. Collecting license texts is not a redistribution audit. The integrated Rumi work remains AGPL-3.0; retain upstream copyright notices and provide matching complete source and installation/build scripts alongside every binary. See [AGPL sections 1 and 6](https://www.gnu.org/licenses/agpl-3.0.html).

Evidence comes from the exact pinned desktop environment: `stage/licenses/dependencies.json`, package license files, actual font name tables, `stage/assets/manifest.json`, and native library inspection. `macos/packaging/licenses/sources.json` records retrieved text hashes. The source builder includes copyleft source archives and the cache-adapted BabelDOC tree. An asset/model card label alone does not establish rights over all upstream material.

| Component | Evidence / action |
| --- | --- |
| Rumi / PDFMathTranslate-next / BabelDOC 0.6.2 | AGPL-3.0; retain history and attribution. Ship exact Rumi and adapted BabelDOC source and build instructions. |
| PyMuPDF 1.25.2 + MuPDF 1.25.2 | AGPL; include both source packages, not just Python bindings. Verify the linked native library matches. |
| Levenshtein | GPL-2.0-or-later in installed metadata. Include exact source. |
| PyInstaller | GPL with bootloader exception; retain exception and corresponding pinned source. |
| certifi / tqdm | MPL obligations must not be skipped by a GPL-only detector. Include exact source and verify notices; tqdm's installed distribution lacks a separate license file. |
| OFL font families | Retain full OFL, embedded copyrights and reserved names; ship unmodified fonts. Go Noto fonts use OFL even though its build scripts use Unlicense. |
| MaruBuri | Embedded font has copyright credits but no full grant. Existing mirrored README is insufficient; verify authoritative NAVER redistribution terms for the exact font. **Open.** |
| DocLayout ONNX | Converted model card says Apache-2.0; originating DocLayout-YOLO repository uses AGPL-3.0. Confirm terms and provenance for the bundled weights and conversion, including any required corresponding source. **Open.** |
| Flatbuffers / tqdm | Installed metadata has no separate copied license file. Obtain exact-version authoritative license text and include it. **Open.** |
| Native wheel libraries / CPython runtime | Review actual Mach-O inventory and embedded notices (e.g. FreeType, HarfBuzz, libspatialindex, BLAS, OpenSSL). Python package-level labels alone do not cover all bundled code. Resolve missing notices/source obligations. **Open.** |
| Other Python packages | Resolve missing/ambiguous metadata by reading included license texts. Lock hash and version must match the built payload. **Open.** |

Before publication, record reviewer, date, exact DMG/source digests, component decisions and supporting URLs in the release acceptance record. If rights cannot be established, replace/remove the component and rerun packaging and translation checks. Do not waive an unresolved component by relabeling the app “beta”.
