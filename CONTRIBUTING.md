# Contributing to Apex Control

Thank you for wanting to help. Apex Control is a small, careful project: it
writes to the memory of a real keyboard, and its core features were checked
against real hardware. The rules below exist to keep it that way, and to make
your first contribution easy rather than intimidating.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to help

You do not need to write Swift to be useful, and most of this needs no keyboard.

- **Report a bug** with the [bug report form][new-issue]. The more precise the
  report, the faster it gets fixed; the form asks for the output of
  `apexctl --version` and `apexctl info` for that reason.
- **Tell us about your keyboard.** Apex Control supports exactly one model today
  (see [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). If yours is different,
  the *device support* form collects what is needed to make progress.
- **Report a protocol finding**: a command the docs get wrong, a firmware that
  behaves differently, a new byte you decoded. This is the most valuable kind of
  report the project gets. See [Protocol work](#protocol-work).
- **Improve the docs.** If something confused you, it will confuse the next
  person; a pull request that fixes it is always welcome. A change to the
  documentation alone needs no Mac: edit the Markdown and run
  `python3 Scripts/check-repo.py`.
- **Fix a known issue.** [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md) lists rough
  edges found in review, each of them a good first contribution.
- **Write tests, work on the interface, or improve the tooling.** Unit tests, the
  SwiftUI panes (the screenshot harness draws every pane without a keyboard) and the
  scripts and workflows can all be developed without hardware.
- **Review pull requests** and reproduce bugs on your hardware.

Anything that changes what reaches the keyboard has to be tested on one. If you
cannot, say so plainly in the pull request.

Not sure whether an idea fits? Ask in
[Discussions](https://github.com/Rikearon/apex-control/discussions)
before writing code. Ideas that touch the keyboard's flash memory, or that add a
whole feature, should start as a discussion (or a PRD, see below).

## Ground rules

These are the things that get a pull request sent back. Rules 1 and 2 matter only if
you touch code that talks to the keyboard; a documentation, test or tooling change
needs neither.

1. **Hardware safety comes first.** A write that reaches the keyboard must be one
   you can undo, or one the code has read back first. A command that replaces a
   whole frame or flash image is a read-modify-write: read what the keyboard holds,
   change only what you mean to, write it back, and for flash verify by reading it
   back. A blank frame is acceptable only where blank is the factory state (the
   normal and second-actuation layers are written that way by `reset-bindings`).
   The Fn layer and flash images are never written from scratch (the one way to
   blank the Fn layer is the app's explicit, confirmed **Clear the Fn layer too**
   action, which keeps what it erased in the undo history). The app's best-effort
   save at quit skips the read-back so that quitting is not held up, and the OLED image
   save is a single command that is not read back; those are the two deliberate
   exceptions to verifying. The
   [invariants in the architecture guide](docs/ARCHITECTURE.md#invariants-that-will-bite-you)
   explain each rule and what it cost to learn. Read them before touching
   anything under `Sources/ApexKit/Protocol/`.
2. **Do not "fix" a packet builder to match an assumption.** The odd-looking
   parts of the protocol are odd because the firmware is. Change protocol code
   only with hardware evidence, and update [docs/PROTOCOL.md](docs/PROTOCOL.md)
   in the same pull request.
3. **Provenance.** Contribute only work that is yours to license under this
   project's terms:
   - Do not include vendor files or code in a contribution. Short factual
     data you confirmed on your own device is welcome; say how you confirmed it.
   - Do not copy code from other projects unless its licence allows it under
     MIT. OpenRGB (GPL-2.0) and OmniLED (GPL-3.0) in particular are
     copyleft, so code from them cannot come in. Describing a byte layout you
     also observed on hardware, and citing the project, is fine.
   - Do not commit captures or dumps that contain your keyboard's serial number or
     GUID. Profile images from `apexctl profile read` contain the GUID; redact it
     or leave the file out.
4. **No network, no telemetry.** The app makes no network connections, and that
   is a feature people rely on when they grant it Input Monitoring. See
   [docs/PRIVACY.md](docs/PRIVACY.md). Proposals that add any are a discussion
   first, not a pull request. Opening a link in the user's browser is not a
   connection the app makes, but `make check` rejects any URL literal under
   `Sources/`, so ask first if you need one.
5. **If you used an AI assistant, you are still the author.** You are responsible
   for every byte your change writes to hardware: verify it on a device or say
   plainly that you could not. Unverified protocol claims are labelled as such in
   this project, never presented as fact.

## Development setup

You need macOS 14 or later and Xcode 16 or later (Swift 6.0+). Xcode 16 itself
needs macOS 14.5 or later, and if a command complains about the Xcode licence you
accept it once with `sudo xcodebuild -license accept`. There are no other
dependencies: no package manager, no Homebrew formulae, no third-party code.

```bash
git clone https://github.com/Rikearon/apex-control.git
cd apex-control
swift build
swift test
make check
```

`swift build` builds every product in debug, `swift test` runs the unit tests (no
keyboard needed), and `make check` checks whitespace, doc links, PRD
cross-references, workflows and scripts. CI runs more than that: ShellCheck and
actionlint (`make lint`, after `brew install shellcheck actionlint`), a security
audit of the workflows, a release build, a packaging dry run, and the tests on
several Xcode versions, one of them on Intel. If you change `Scripts/check-repo.py`,
run `make test-tools` too. `make help` lists the shortcuts.

To run what you built:

```bash
swift run ApexControlApp
swift run apexctl --version
make app && open "build/Apex Control.app"
```

Those start the app unbundled (fine for most work), run the CLI (`apexctl info` and
the other commands need a plugged-in keyboard; `--version` does not), and build and
open a real bundle. `make app` does not build
`apexctl`; `swift build -c release` does (`swift build -c release --show-bin-path`
prints the folder it lands in).

**Quit an installed Apex Control, and SteelSeries GG, before you run your own
build.** Two programs streaming lighting to one keyboard fight over it, and the
app's single-instance check does not cover `swift run`. Note too that the app saves
to the keyboard's flash on its own (a few seconds after you change something, and
when it quits), so if the settings matter, first keep a copy with
`apexctl profile read 0 --out backup.bin`.
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#before-you-run-your-own-build) has the
details.

Reactive lighting needs a permission macOS ties to the app's code signature.
If you work on it, run `./Scripts/make-signing-identity.sh` once so the grant
survives rebuilds. Read what it does first; it is explained in
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#keeping-permissions-across-rebuilds).

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) covers the rest: the hardware
verification loop, the development harnesses, and recipes for common changes.

## Testing

- `swift test` must pass, and needs no keyboard. It covers packet framing, key
  tables, config codecs and the reactive-input rules, everything that can be
  checked without a device.
- New behaviour that can be expressed as pure logic should come with a test.
  Keep logic out of views and controllers so it can be tested this way. The one
  test target, `ApexKitTests` in `Tests/ApexKitTests/`, exercises ApexKit only, so
  logic in the app target has no unit tests to fall back on. Cases are XCTest
  methods named `testSomething`, one file per area; look at `MappingsTests` for the
  style.
- Anything that talks to the device is verified on a device. Say in the pull
  request what you ran and against which firmware (`apexctl info` prints it).
  There is no device simulator yet ([PRD-31](docs/prd/PRD-31-device-simulator-test-harness.md)).
- The build is warning-free; keep it that way. An incremental build only reports
  what it recompiled, so check with `swift package clean && swift build 2>&1 | grep -c "warning:"`,
  which should print 0.

## Making a change

1. Fork the repository and branch from `master`.
2. Keep the change focused. Unrelated clean-ups belong in their own pull
   request.
3. Match the code around you: 4-space indentation, and comments that explain
   *why* (especially anything the hardware forced on the design), not what.
   The codebase is deliberately hand-formatted; do not run a formatter over
   files you are not otherwise changing.
4. Follow the conventions in the
   [architecture guide](docs/ARCHITECTURE.md#conventions), in particular:
   protocol builders are pure and I/O-free, USB writes never run on the main actor
   (in `DeviceController` they go through `perform`), config structs decode with
   `decodeIfPresent` and defaults, and views are built from the `Design/`
   components.
5. Update the docs in the same pull request. That means
   [docs/PROTOCOL.md](docs/PROTOCOL.md) for protocol changes, the relevant PRD's
   **Status** line for feature work, and the README or user guides for anything
   a user would notice. Code comments reference PRD numbers and requirement ids
   (`PRD-01 FR-1`); keep that thread.
6. If a user would notice the change, add a line to [CHANGELOG.md](CHANGELOG.md)
   under **Unreleased**. Refactors, tests and internal tooling do not need one.
7. Run `make check` and `swift test`.
8. Write the commit message in [Conventional Commits](https://www.conventionalcommits.org/)
   style: `feat: …`, `fix: …`, `docs: …`, `refactor: …`, `test: …`, `ci: …`,
   `build: …`.

## Protocol work

The protocol reference is [docs/PROTOCOL.md](docs/PROTOCOL.md). It is the
reference the code follows, and it states how sure it is about each claim: *confirmed on
hardware*, *from descriptor* (taken from the vendor's description of the device,
which this repository does not contain) or *needs RE* (not yet reverse-engineered).
Keep that discipline.

To establish or check a claim you need only your own keyboard and `apexctl raw`
(`.build/debug/apexctl` once you have run `swift build`). This reads the
normal-layer binding of the A key (HID `0x04`) by sending the request and then
reading the reply. It is read-only. The reply is `B6 00 00 01 04 51 04 00 00 00`:
command, error 0, layer 0, one key, then (hid, function, key codes): A is mapped
to itself, the factory resting state.

```bash
apexctl raw query --delay 20 --gets 3 B6 00 01 04
apexctl raw read 644
```

`raw read 644` is a GET_REPORT with no preceding write.

A good protocol finding says: the exact bytes sent, the exact bytes received,
the firmware version, what you concluded, and how you would confirm it. The
*protocol finding* issue form asks for exactly that.

Commands that write to the keyboard's flash are a special case. Be sure you
understand the flash-persistence invariant in the architecture guide before you
send one, and never run experiments on a keyboard you cannot afford to lose
settings on.

### Another keyboard model

Apex Control drives one keyboard: the wired Apex Pro TKL Gen 3 (`1038:1642`).
Its command set is believed not to be shared with the full-size Gen 3 (`0x1640`) or
the wireless variants (`0x1644` / `0x1646`), and the code assumes the TKL in many
places. Supporting more models is a planned refactor
([PRD-27](docs/prd/PRD-27-multi-device-multi-model.md)), not a configuration
change. The most useful thing you can do today is file a *device support*
report with your model's identifiers and the results of a few read-only
commands. [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#adding-another-keyboard-model)
explains what a port involves.

## Proposing a larger feature

Larger features are written up as a PRD in [docs/prd/](docs/prd/), using
[the template](docs/prd/_TEMPLATE.md). A PRD states the problem, what is known
and how confidently, the requirements, and the risks, so that the discussion can
happen before the code. Open a discussion first; if the idea has legs, the PRD
becomes the first pull request. `make check` verifies that every PRD is listed
in the index in [docs/FEATURE-GAP-ANALYSIS.md](docs/FEATURE-GAP-ANALYSIS.md#f-prd-index).

## Pull requests

- Fill in the template; it asks the questions a reviewer would otherwise ask.
- Continuous integration must pass. It builds and tests on several Xcode
  versions and on Intel, and runs `make check`, ShellCheck, actionlint and a
  packaging dry run. On a pull request from a fork it starts only when a maintainer
  approves it, and again after each push, so it may sit at "Waiting for approval" for a
  while; that is expected.
- A maintainer reviews on a best-effort basis; this is a volunteer project and
  there is no guaranteed turnaround. A polite ping after a couple of weeks is
  fine.
- By submitting a pull request you license your contribution under the
  project's terms: [MIT](LICENSE) for code and documentation, and
  [CC BY 4.0](LICENSES/CC-BY-4.0.txt) for `docs/PROTOCOL.md` and the Code of
  Conduct. You keep the copyright to your work.

## What will not be accepted

- Vendor files or code.
- Code copied from projects whose licence is incompatible with MIT. Third-party data
  or code that is compatible (a table of numbers, say) needs a credit and the
  licence text in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md), which ships with
  every release.
- Network access, telemetry or analytics of any kind.
- Anything that installs an update without the user's explicit consent.
- Writes to the keyboard's flash that do not read first, patch, and verify by
  read-back (the app's documented save at quit and its OLED image save, which do not
  read back, are the only exceptions).
- Binary blobs. Screenshots and small icons are fine; `make check` refuses any
  file over 1.5 MB.
- Changes that quietly weaken a safety invariant. If one is wrong, say so in an
  issue and let us fix the invariant openly.

[new-issue]: https://github.com/Rikearon/apex-control/issues/new/choose
