# PRD-32: Distribution, Signing, Notarization & Updates

- **Priority:** P0
- **Status:** Partially implemented. A version tag is set up to trigger a CI release
  (`.github/workflows/release.yml`) that builds an ad-hoc-signed universal disk image,
  the `apexctl` binary and `SHA256SUMS`, with a build provenance attestation (FR-3,
  FR-4, FR-8, and the version parts of FR-1 and FR-9: `apexctl --version`, and the
  bundle version stamped from `ApexKit/Version.swift`). The workflow is written and
  linted, and its packaging step has been run locally, but it has not yet run on
  GitHub. Not done: Developer ID signing
  and notarization (FR-1, FR-2), in-app updates (FR-5), the move-to-Applications helper
  (FR-6), the Homebrew cask (FR-7), and the signature status in an About panel.
- **Depends on:** — (blocks anyone who is not the author from using this app)
- **Firmware basis:** none — packaging and release engineering.

## 1. Summary
`Scripts/build-app.sh` ad-hoc signs the bundle (`codesign --sign -`). That is
fine for the machine that built it and unusable for anyone else: Gatekeeper
blocks it on download, `SMAppService` cannot register it as a login item, and
there is no way to ship a fix to someone who already installed it. This PRD makes
Apex Control something a stranger can download, open, trust, and keep up to date.

## 2. Background & GG parity
As far as we know, GG is distributed as a signed installer with a built-in
updater, so installing and updating it is unremarkable. For an open-source
alternative the bar is different but not lower: people will only replace vendor
software with a community app if installing it is unremarkable too. Right now the
honest install instruction is "clone the repo and run a build script", which
limits the audience to developers — and the README already promises features to a
wider audience than that.

There is also a functional dependency: PRD-15 shipped "Start at login" using
`SMAppService.mainApp`, and its own documentation notes that registration is
unreliable for unsigned apps outside `/Applications`. The feature exists but
cannot work properly until this PRD does.

## 3. Technical basis (grounded)
- **Signing** (confidence: documented Apple process): a Developer ID Application
  certificate, `codesign --options runtime` (hardened runtime), and a stable
  bundle identifier. The current script signs ad-hoc and does **not** enable the
  hardened runtime, both of which notarization requires.
- **Notarization** (confidence: documented): `xcrun notarytool submit --wait`
  against a zipped bundle or DMG, then `xcrun stapler staple`. Requires an Apple
  Developer account — a real, recurring cost that must be an explicit project
  decision, not an assumption.
- **HID access under hardened runtime** (confidence: **needs verification**).
  The app opens a vendor-usage HID interface, which macOS does not gate behind
  Input Monitoring. Hardened runtime does not obviously restrict this for a
  non-sandboxed app, but this must be tested on a genuinely notarized build
  before release — if it needs an entitlement, that changes the release plan.
  *Observed 2026-09-28:* a hardened-runtime build signed with a local certificate, with
  no entitlements, holds HID user clients on the keyboard. A notarized build has still
  not been tried.
- **Mac App Store is likely out** (confidence: high, worth confirming): the App
  Sandbox has no entitlement that grants arbitrary HID device access, and this app
  is nothing without it. Developer ID distribution is the path.
- **Updates**: Sparkle 2 is the established macOS choice (EdDSA-signed appcast,
  no server needed beyond static hosting); a GitHub Releases appcast works. The
  alternative — a Homebrew cask — costs nothing and reaches the CLI-literate
  audience immediately.
- **Reproducibility**: the release must be built by CI from a tag, not from a
  laptop, or the binary nobody can reproduce becomes the thing users are asked to
  trust.

## 4. Goals / Non-goals
- **Goals:** a signed, hardened, notarized, stapled `.app` in a `.dmg`; a tagged
  release pipeline in CI producing that artefact plus checksums; in-app updates
  with signed appcast; a Homebrew cask for `apexctl` and the app; a documented
  release process; a verified "downloads and opens with no scary dialog" flow.
- **Non-goals:** the Mac App Store; a paid tier; telemetry of any kind (PRD-34
  states this as a commitment); auto-update that installs without consent;
  supporting installation anywhere other than `/Applications` for the login-item
  path.

## 5. User stories
- As a user, I download a DMG, drag it to Applications, open it, and nothing
  warns me that it might be malware.
- As a user, "Start at login" actually works.
- As a user, the app tells me when there is an update and I can read what changed
  before installing it.
- As a Homebrew user, `brew install --cask apex-control` works.
- As a security-minded user, I can verify the release checksum and see that CI
  built it from a specific commit.
- As a maintainer, cutting a release is one tag push, not a checklist I get wrong.

## 6. Functional requirements
- FR-1: `build-app.sh` gains a signed mode: Developer ID identity, hardened
  runtime (`--options runtime`), `--timestamp`, and a proper `Info.plist` with
  `CFBundleVersion` derived from the git describe output.
- FR-2: A `notarize` step submitting to `notarytool`, waiting, stapling, and
  failing the build on rejection with the log attached.
- FR-3: Release artefacts: a `.dmg` containing the app and an Applications
  symlink, plus `SHA256SUMS`, plus the `apexctl` binary.
- FR-4: CI builds releases **from a tag**, on a clean runner, with secrets held
  as encrypted CI secrets; the workflow file is the canonical release process.
- FR-5: In-app updates: check on launch and daily, never auto-install; the update
  sheet shows the release notes; the feed is signed and served over HTTPS; a
  setting disables checks entirely.
- FR-6: The app detects it is running from outside `/Applications` and offers to
  move itself, because the login-item path depends on it.
- FR-7: A Homebrew cask formula is maintained in the repo and updated by the
  release workflow.
- FR-8: The unsigned local build path keeps working exactly as it does today, so
  contributors need no certificate.
- FR-9: `apexctl --version` and the app's About panel report the version, the
  commit, and whether the build is signed.

## 7. UX / UI design
- **Install:** DMG with a background image showing the drag target. Nothing
  clever.
- **First launch:** no Gatekeeper dialog at all is the target state; if the build
  is unsigned (a contributor build), the app itself explains why macOS complained.
- **Move to Applications:** a one-time sheet, dismissible, with a plain reason —
  "Start at login only works from the Applications folder."
- **Updates:** a standard sheet with version, date, release notes, "Install and
  Relaunch" / "Later" / "Skip this version"; a Settings row showing the last
  check and a manual "Check now".
- **About:** version, commit hash, signature status, and links to the protocol
  documentation and the licence.

## 8. Technical design
- **Build:** rework `Scripts/build-app.sh` into `build`, `sign`, `notarize`,
  `package` steps that CI composes and a developer can run individually.
- **App:** Sparkle integration behind a small `UpdateController` so the rest of
  the app does not depend on it and unsigned builds can compile without it;
  `MoveToApplications` helper; About panel.
- **CI:** a release workflow triggered on `v*` tags — build, test, sign,
  notarize, staple, package, checksum, create the GitHub release, update the cask.
- **Data model:** none, beyond an `updateCheckEnabled` preference and
  `lastUpdateCheck`.

## 9. Edge cases & risks
- **This costs money and identity.** A Developer ID requires an Apple Developer
  Program membership tied to a person. That is a project governance decision
  (see PRD-37) and should be made before the work starts, not discovered
  half-way.
- **Secrets in CI**: a signing certificate and an App Store Connect key in a
  public repo's CI is a real attack surface; releases should run only on tags
  from a protected branch, and the certificate should be revocable.
- **Notarization rejects on the hardened runtime** if any entitlement is missing;
  the HID question in §3 must be settled on a real notarized build early, not at
  release time.
- **Sparkle is a dependency with update authority** — it can replace the app
  binary. Its signing key must be handled as carefully as the Developer ID, and
  the "never install without consent" rule is non-negotiable.
- **A stale cask** is worse than none; the release workflow must update it or the
  project should not publish one.
- **Ad-hoc builds continuing to exist** is good for contributors and confusing
  for users; the About panel's signature status is what keeps them apart.

## 10. Acceptance criteria
- AC-1: A released DMG downloaded through a browser on a clean Mac opens with no
  Gatekeeper warning.
- AC-2: `spctl -a -vvv` and `codesign -dv --verbose=4` report a valid Developer
  ID signature with the hardened runtime, and `stapler validate` passes.
- AC-3: The notarized build opens the keyboard's HID interface and drives
  lighting — proving hardened runtime does not break device access.
- AC-4: "Start at login" registers successfully from `/Applications` and appears
  in System Settings › Login Items.
- AC-5: An update is offered, the notes are readable, and declining leaves the
  app untouched.
- AC-6: A release is produced end-to-end by CI from a tag, with checksums that
  match the published artefacts.

## 11. Effort & milestones
**M.** M1: signing + hardened runtime locally, and the HID verification.
M2: notarization and DMG packaging. M3: CI release workflow. M4: Sparkle and the
update UI. M5: Homebrew cask and the documented process.

## 12. Open questions
- Does the hardened runtime require any entitlement for vendor-usage HID access?
  Everything else in this PRD is routine; this is the one real unknown.
- Who holds the Developer ID, and what happens to releases if that person steps
  away? (A project-governance question, not a technical one.)
- Sparkle vs. "check GitHub Releases and tell the user to download" — the latter
  has no update-authority risk and much less complexity.
- Should `apexctl` be distributed independently of the app for people who want
  only the CLI?
