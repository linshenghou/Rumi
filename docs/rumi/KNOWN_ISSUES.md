# Known issues — 0.3.0 Beta 1

- First launch can be slow while macOS validates the bundled ad-hoc binaries; one developer-machine relocation check took about 198 seconds. Independent-machine startup acceptance remains pending.
- No Developer ID signing or Apple notarization; first launch may be blocked or need explicit macOS approval. Managed Macs may not permit installation.
- Apple Silicon only, macOS 14+. No Intel build, Mac App Store distribution, automatic updates, Rumi account or hosted API.
- Complex columns, tables, equations, embedded fonts and scanned pages can produce imperfect layout or translation. Inspect exported papers before relying on them. This is not an OCR or scientific accuracy guarantee.
- Providers differ in OpenAI compatibility, model names, reasoning parameters and limits. Invalid credentials, exhausted quota or network failures require correcting the provider configuration or retrying later.
- New Rumi identity requires explicit import of an earlier preview's Keychain credential (or a new key). macOS can deny access or show an authorization prompt.
- Closing the window leaves active translation running; quitting stops it. Waiting/interrupted tasks do not automatically restart after launch.

Before public release, independent Mac installation and upgrade evidence must be completed and the [license review](LICENSE_REVIEW.md) closed. Installation failures, data loss and secret exposure are release blockers, not acceptable known issues.
