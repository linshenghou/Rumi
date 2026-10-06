# Contributing to Rumi

English and Chinese contributions are welcome. Read the [code of conduct](CODE_OF_CONDUCT.md). Please open an issue before large changes; small fixes can go straight to a PR. Maintainers review and merge external PRs after the required checks pass.

## Development

Rumi targets Apple Silicon and macOS 14+. Build on Apple Silicon with macOS 26+ and Xcode 26.4.1+ (the layered icon compiler), Python 3.11+ and uv. Follow [English build instructions](docs/rumi/BUILD.md) or [中文构建说明](macos/README.md) for pinned engine setup. Swift tests need no API key. Python bridge tests run in the isolated desktop environment with pytest installed separately.

```sh
swift test --disable-sandbox --package-path macos
python3 macos/scripts/build_engine.py --skip-freeze
uv pip install --python macos/.build/standalone/venv/bin/python pytest==8.3.5
macos/.build/standalone/venv/bin/python -m pytest tests/test_desktop_bridge.py tests/test_release_packaging.py
```

The `macOS PR checks` workflow runs Swift tests, bridge/packaging tests, icon compilation, a frozen-engine portability check, and a real PDF translation against a loopback mock API. No repository secrets or paid provider key is needed. The `Source safety` check scans the history and current source.

## Changes and review

Keep changes focused and include reproduction steps and relevant validation. Add meaningful regression coverage for credential handling, migration, cancellation, output preservation and packaging. Update English and Chinese strings together. Use synthetic documents for tests and screenshots. Never attach API keys, personal configuration, private papers, translation caches or logs containing document text. `artifacts/` and `macos/.build/` are generated and ignored.

Use Python formatting consistent with the existing code (`ruff format`); preserve readable Swift code and macOS 14 availability checks. Do not add telemetry, silently read legacy credentials, or start translations without a user action. Record new dependencies and their redistribution terms.

Desktop version, build, channel and repository identity live in `macos/Sources/PDFTranslate/Resources/Release.json`. Keep the Python engine's upstream version separate. Binary assets belong in Releases, never Git. Follow the [release checklist](docs/rumi/RELEASE_CHECKLIST.md) before requesting a release.
