# Build Rumi from source

Use an Apple Silicon build host with macOS 26+, full Xcode 26.4.1+ selected via `xcode-select`, Python 3.11+ and [uv](https://docs.astral.sh/uv/). The built app still targets macOS 14+. Building needs network access to fetch the pinned CPython runtime, hash-locked packages, model/font assets and corresponding dependency sources. Running the installed app does not need Python or a model download.

Clone the repository (or extract the matching complete source archive). The desktop engine keeps the upstream Python package name/version. `macos/Sources/PDFTranslate/Resources/Release.json` is the independent Rumi product version/build/channel/identity source.

```sh
python3 macos/scripts/build_engine.py
python3 macos/scripts/build_app.py --reuse-engine
swift test --disable-sandbox --package-path macos
```

The engine builder installs CPython 3.13.11 and creates an isolated environment under `macos/.build/standalone/`. It patches cache paths in staged sources, verifies allowlisted assets by SHA3-256, collects notices and freezes the helper. The app builder compiles Swift and the layered icon, bundles the helper and ad-hoc signs nested code. `artifacts/macos/Rumi.app` is the output. No Developer ID certificate or Apple notarization is used.

`--asset-cache PATH` seeds the build from verified font/model/CMap/tokenizer files only; it never copies working papers, translation databases or user configuration. Use an empty directory for an independent network build. The runtime uses bundled assets and a separate writable cache.

## Checks without a paid API key

```sh
uv pip install --python macos/.build/standalone/venv/bin/python pytest==8.3.5
macos/.build/standalone/venv/bin/python -m pytest tests/test_desktop_bridge.py tests/test_release_packaging.py
python3 macos/scripts/verify_engine.py macos/.build/standalone/dist/pdftranslate-engine
macos/.build/standalone/venv/bin/python macos/scripts/smoke_engine.py macos/.build/standalone/dist/pdftranslate-engine/pdftranslate-engine --work artifacts/mock-api
```

The smoke test generates a synthetic PDF, binds a server to loopback and verifies translated/bilingual outputs. It does not contact a paid translation service. Runtime signature validation and first startup may take longer on a fresh Mac.

## Release builds and corresponding source

A release uses a clean Git checkout and the exact tag from `release_metadata.py --field tag`. All intended source must be committed before packaging. Follow [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md), then run `python3 macos/scripts/build_app.py --release --dmg`. This creates a DMG, source tarball, build record, release notes and checksums. The source archive includes tracked repository input, adapted BabelDOC, dependency locks, resource/license manifests and copyleft source packages. `BUILD.json` records the commit and toolchain; engine metadata records the Python version and source fingerprint. This is traceable input provenance, not a promise of byte-identical outputs.

The complete source tarball can build the app using the first two commands above without Git; it cannot create an official release until restored to a reviewed Git checkout. Rebuilds can fetch pinned dependencies online; `third_party/` also supplies corresponding source for inspection/modification. Never substitute a GitHub automatic source ZIP for the complete corresponding-source attachment.

A development-only build uses `build_app.py --development --python /absolute/path/to/python` and records the checkout path in its bootstrap file. It is not portable and cannot be packaged as a DMG.
