# Redistribution review

Status: **incomplete; public binary release is blocked**. Collecting license texts is not a redistribution audit. The integrated Rumi work remains AGPL-3.0; retain upstream copyright notices and provide matching complete source and installation/build scripts alongside every binary. See [AGPL sections 1 and 6](https://www.gnu.org/licenses/agpl-3.0.html).

Evidence comes from the exact pinned desktop environment: `stage/licenses/dependencies.json`, package license files, actual font name tables, `stage/assets/manifest.json`, and native library inspection. `macos/packaging/licenses/sources.json` records retrieved text hashes. The source builder includes copyleft source archives and the cache-adapted BabelDOC tree. An asset/model card label alone does not establish rights over all upstream material.

| Component | Evidence / action |
| --- | --- |
| Rumi / PDFMathTranslate-next / BabelDOC 0.6.2 | AGPL-3.0; retain history and attribution. Ship exact Rumi and adapted BabelDOC source and build instructions. |
| PyMuPDF 1.25.2 + MuPDF 1.25.2 | AGPL; include both source packages, not just Python bindings. Verify the linked native library matches. |
| Levenshtein | GPL-2.0-or-later in installed metadata. Include exact source. |
| PyInstaller | GPL with bootloader exception; retain exception and corresponding pinned source. |
| certifi / tqdm | MPL obligations must not be skipped by a GPL-only detector. Exact source packages and the full MPL-2.0 text are included; tqdm's pinned upstream notice supplements its installed distribution. |
| OFL font families | Retain full OFL, embedded copyrights and reserved names; ship unmodified fonts. Go Noto fonts use OFL even though its build scripts use Unlicense. |
| MaruBuri Regular | [NAVER's official license article](https://help.naver.com/service/30016/contents/18088?osType=PC&lang=ko) explicitly includes MaruBuri under OFL-1.1. Full article text and embedded copyright are included. The bundled TTF exactly matches the file inside the [official font download](https://hangeul.naver.com/hangeul_static/webfont/zips/maruburi.zip): SHA-256 `803429881927c79dbb49497274244e72b672c56e0503f28262503f77524cba7a` (checked 2026-10-06). Ship unmodified with these notices; do not sell the font alone. |
| DocLayout ONNX | Converted model card says Apache-2.0; originating DocLayout-YOLO repository uses AGPL-3.0. Confirm terms and provenance for the bundled weights and conversion, including any required corresponding source. **Open.** |
| Flatbuffers 25.12.19 / tqdm 4.70.1 | Missing installed notices supplemented with the exact upstream tag's [Flatbuffers Apache-2.0 license](https://github.com/google/flatbuffers/blob/v25.12.19/LICENSE) and [tqdm MIT/MPL notice](https://github.com/tqdm/tqdm/blob/v4.70.1/LICENCE). Full texts are vendored with SHA-256 in `sources.json` and copied into both app and source archive. |
| Native wheel libraries / CPython runtime | Review actual Mach-O inventory and embedded notices (e.g. FreeType, HarfBuzz, libspatialindex, BLAS, OpenSSL). Python package-level labels alone do not cover all bundled code. Resolve missing notices/source obligations. **Open.** |
| Other Python packages | Resolve missing/ambiguous metadata by reading included license texts. Lock hash and version must match the built payload. **Open.** |

Before publication, record reviewer, date, exact DMG/source digests, component decisions and supporting URLs in the release acceptance record. If rights cannot be established, replace/remove the component and rerun packaging and translation checks. Do not waive an unresolved component by relabeling the app “beta”.
