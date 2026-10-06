# README visuals

The app icon is referenced directly from `macos/Resources/Branding/RumiIcon.png`.

The four `native-*.png` files are transparent 3× renders of Rumi's native UI glyphs. Regenerate them on macOS with `python3 macos/scripts/export_readme_assets.py`:

- **Translate:** the actual `TranslationOrb` view compiled from `TranslationAction.swift`, stationary at zero progress.
- **Import:** `doc.badge.plus`, used by `PDFImportCard`.
- **Compare:** `doc.on.doc`, used by `ContentView`.
- **Service:** `network`, used by `SettingsView`.

These images illustrate Rumi's macOS UI; they are not a standalone icon library or installation acceptance evidence. SF Symbols remain Apple system artwork, not Rumi branding. The README renders them at 32 points with short, accessible feature headings, without a screenshot or feature-table borders.

Structure references: [Jan](https://github.com/janhq/jan) for clear product identity and entry points, and [Cherry Studio](https://github.com/CherryHQ/cherry-studio) for app identity and feature sections. No wording, screenshots or branding from those projects is reused.
