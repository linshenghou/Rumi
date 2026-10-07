# Rumi roadmap

## Community beta

Ship a free Apple Silicon app with bring-your-own API, PDF/arXiv import, reliable cancellation and error reporting, bilingual reading and export. Publish matching source and dependency notices. Invite a small group of paper readers, resolve installation/data/credential blockers, then open the beta more widely.

Before public downloads, finish the bundled native-library license/source review and installation acceptance on independent Macs running macOS 14 and the current macOS. See the [release checklist](RELEASE_CHECKLIST.md). Passing developer-machine tests or CI does not complete those checks.

## Native app direction

Rumi already has a native Swift client: SwiftUI/AppKit for the interface, PDFKit for reading, native arXiv import and macOS Keychain for credentials. A separate Python helper runs PDFMathTranslate-next and BabelDOC for document analysis, translation and typesetting. Users do not need to install Python in the standalone community build.

Keep this architecture for the open-source beta. Priorities are reliable installation, preserving documents and previous translations on failure, responsive cancellation, clear errors, and consistent reading/export behavior. The client checks the helper's protocol version before starting queued translations and validates the requested PDF outputs before replacing previous results.

Improve translation quality through reproducible examples and evaluation of terminology, omissions, formulas and layout. Build a small, redistributable document set and compare results before changing the engine; choosing another implementation language alone does not improve translation quality.

Measure cold/warm startup, peak memory, translation time and bundle size before selecting a module to migrate. A future Swift or Rust helper can use the existing process protocol, but must also pass output, cancellation, error and compatibility checks. Prefer Swift for macOS integration. Consider Rust for a measured bottleneck or a concrete shared-core requirement across platforms; a full engine rewrite is not planned for this beta.

## After beta feedback

Prioritize reading and translation reliability from reported cases. Evaluate Developer ID signing, notarization and stapling after the beta proves useful. Consider an automatic updater only with a secure signed distribution design.

Accounts, payments, a hosted API, Intel and Mac App Store distribution are outside the first release. This is a direction, not a delivery-date commitment.
