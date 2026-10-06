# Community beta release checklist

A maintainer owns this record. Copy it into a private acceptance record for each candidate, recording tester, date, macOS/chip, build commit and artifact SHA-256. Do not mark a step passed without evidence. Keep private documents and credentials out of records.

## Repository and candidate

- [ ] Repository owner and independent bundle ID confirmed in `Release.json`.
- [ ] All intended source committed; upstream history and attribution preserved; no generated artifacts or personal files tracked.
- [ ] Full history, candidate tree and final source archive secret scans pass; findings resolved rather than broadly allowlisted.
- [ ] Actual bundled Python/native/font/model redistribution review closed with evidence. See [LICENSE_REVIEW.md](LICENSE_REVIEW.md).
- [ ] Issues works; private vulnerability reporting is enabled and its report form verified. Maintainer watches security notifications.
- [ ] `macOS PR checks` and `Source safety` pass on the release commit. Maintainer review is required for external PRs; configure branch protection for these checks.
- [ ] English/Chinese README screenshot, About links, privacy text and release notes match the app.

## Build and draft

1. Update `macos/Sources/PDFTranslate/Resources/Release.json` and release notes. Commit the reviewed source.
2. Run the source audit, Swift/bridge/release tests, icon compilation and local mock API smoke. No paid API key is needed for CI.
3. From a clean checkout, create the matching tag (Beta 1: `v0.3.0-beta.1`) and push that tag to the Rumi remote only. The release workflow requires the tag to resolve to HEAD.
4. The workflow builds pinned inputs and produces a **draft** prerelease with the DMG, matching complete source archive, `BUILD.json`, `RELEASE_NOTES.md` and `SHA256SUMS.txt`. `draft_release.py` validates checksums and clean/tagged build provenance; it has no publish mode.
5. Download the exact draft assets for invited testers with access. Do not replace tested assets without repeating acceptance. Public downloads wait for the following evidence.

## Independent Mac acceptance

Test on an Apple Silicon Mac independent of the build environment, covering **macOS 14 and the current macOS**. A developer-machine smoke test or CI VM alone does not satisfy this section. Use no Python installation, checkout, developer cache or saved development credentials.

| Case | Expected result | Tester / system / evidence |
| --- | --- | --- |
| Browser download → checksum → DMG → drag to Applications → first launch | Installs from the actual downloaded file; document the actual Gatekeeper prompt using Apple's approved flow | Pending |
| Offline first launch and local PDF reading | No Python, repo, asset download or external API needed | Pending |
| Configure own API, translate a small permitted paper | Keychain works; original, translated and bilingual outputs available | Pending |
| arXiv download-only and download-and-translate | Correct paper/version; progress, cancellation and retry work | Pending |
| Switch versions, search, zoom, export | Correct version and readable exported PDFs | Pending |
| Invalid key / quota exhausted / lost network | Actionable error; original and prior translated files preserved | Pending |
| Corrupt PDF / unwritable output | Clear error; no original overwritten | Pending |
| Cancel / quit / restart | Children stop; no silent restart; prior results and history remain | Pending |
| Upgrade from preview with documents/settings | Data retained; legacy credential read only on explicit import; denial allows replacement | Pending |
| Bundle and source inspection | No private documents, credentials or runtime dependencies on development-machine paths | Pending |

## Publish manually

- [ ] Every acceptance case passed on the exact candidate, and unresolved licensing items closed.
- [ ] A small invited group of paper readers tried the candidate; feedback reviewed.
- [ ] No installation failure, data loss or credential disclosure remains. Layout limitations are in [known issues](KNOWN_ISSUES.md).
- [ ] Release notes disclose **no Developer ID signature or Apple notarization**, system requirements, API billing, manual updates and known issues.
- [ ] Public availability wording is updated in README/INSTALL and the release body after acceptance. Keep the tested tagged source unchanged; document acceptance in the release body.
- [ ] Maintainer changes the accepted draft to a public prerelease in GitHub. No automation in this repository performs this step.

Do not disable Gatekeeper to pass acceptance. Apple Developer Program enrollment, Developer ID signing, notarization and stapling are a later distribution improvement, not a claim about this unsigned community beta. Source, dependencies and notices remain available alongside each distributed binary.
