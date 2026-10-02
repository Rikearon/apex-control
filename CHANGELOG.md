# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is 0.x, minor releases may change behaviour that 1.0 will
freeze.

## [Unreleased]

The first public release, planned as 0.1.0.

### Added

- **The app**: per-key RGB lighting with Static, Per-Key, Rainbow Wave, Spectrum
  Cycle, Breathe and Reactive effects rendered on the Mac at 30 fps; key
  remapping across the normal, Fn and second-actuation layers with undo and redo;
  per-key actuation from 0.1 mm to 4.0 mm; rapid trigger; rapid tap (SOCD); the
  OLED screen (text, clock, image); software profiles with JSON import and
  export; a menu-bar mode with login item, sleep and wake handling.
- **Bindings and settings persist in the keyboard.** Key bindings, the Fn key,
  actuation, rapid trigger and rapid tap are written into the keyboard's flash
  (onboard slot 0, which the app calls slot 1) shortly after an edit settles, by a
  verified read-modify-write, so they should survive unplugging (a dated power-cycle
  check is not recorded yet; see the
  [compatibility page](https://github.com/Rikearon/apex-control/blob/master/docs/COMPATIBILITY.md)).
  There is no setting to turn this off and no automatic backup: see the
  [README](https://github.com/Rikearon/apex-control/blob/master/README.md#install) and the
  [known issues](https://github.com/Rikearon/apex-control/blob/master/docs/KNOWN-ISSUES.md).
- **`apexctl`**, a command-line front end to the same engine: lighting,
  actuation, OLED, bindings, onboard profile read, save and restore, and raw
  protocol access. `apexctl --version` reports the version. It checks its arguments
  before it connects, and refuses what could quietly change something other than
  what you typed:
  - `bind` and `unbind` stop with an error, and write nothing, when they could not
    read the layer first (a write is a complete frame, so writing from nothing would
    reset every other key on it, and read-back is intermittent on firmware 1.19.7) and
    when they meet an argument they do not understand.
  - Hex bytes, slots and numbers follow rules in ApexKit (`ArgumentParsing`) that are
    unit-tested: a slot is a plain number from 0 to 4, `raw` commands send nothing if
    an argument is not a hex byte, and `raw read` and the options of `raw query` must
    be whole numbers in range.
  - `key` needs complete key and colour pairs and refuses a key that has no LED; `fn`
    refuses a key that cannot be the Fn key; a sensitivity given to
    `actuation --rapid-trigger` must be 1 to 20 (default 2); `rainbow` limits its frame
    rate to 1 to 30 (faster frames
    make the lighting tear), and `rainbow` and `wave` limit their duration to 0 to 3600
    seconds.
  - `verify` exits with an error when the read-back does not match, `reset-bindings`
    says that it leaves the Fn layer alone, and `raw feature`, `raw output` and `fn`
    report a failed write.
- **ApexKit**, the reusable library underneath both.
- **Release packaging**: `Scripts/package-release.sh` builds a universal
  (Apple Silicon and Intel) disk image, the `apexctl` binary and `SHA256SUMS`;
  the release workflow runs it from a version tag.
- **Build scripts**: `Scripts/build-app.sh` asks SwiftPM where the build products
  are, so it works across toolchains; it supports universal builds
  (`APEX_UNIVERSAL=1`), stamps the version and copyright into `Info.plist`, and stops
  with an error if the signature does not verify. `Scripts/make-signing-identity.sh`
  states what it changes on your Mac, asks before changing it, limits its keychain
  change to the key it creates, and gives only `codesign` (not the `security` tool)
  passwordless access to that key.
- **Open-source project files**: MIT licence (with CC BY 4.0 for
  `docs/PROTOCOL.md` and the code of conduct), third-party notices, contributing
  guide, code of conduct, security policy, governance, issue forms, pull request
  template, continuous integration on several Xcode versions and on Intel, and user,
  developer and maintainer documentation.
- **Documentation**: guides to the app and the command line, troubleshooting, a
  compatibility page that records what was verified and how, known issues, a privacy
  and security page, and a glossary.
- `make check` (`Scripts/check-repo.py`) verifies documentation links and
  anchors, PRD cross-references, whitespace, workflow pinning and the release
  files, and keeps captures, dumps and vendor files out of the repository.
  `make lint` runs ShellCheck and actionlint, as CI does, and `make test-tools`
  runs the tests of the checks themselves. A maintainer's private word list can be
  added with `CHECK_DENYLIST`; the check says whether it applied it.

[Unreleased]: https://github.com/Rikearon/apex-control/commits/master
