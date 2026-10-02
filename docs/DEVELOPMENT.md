# Developing Apex Control

Everything you need to build, run, test and change the project. For how the code
is organised and the rules it must obey, read [ARCHITECTURE.md](ARCHITECTURE.md)
first.

## Prerequisites

- macOS 14 or later to run the app. To build it you need Xcode 16 or later
  (Swift 6.0+), and Xcode 16 itself needs macOS 14.5 or later. You build from the
  command line and never need to open Xcode. If a command stops with a message
  about the Xcode licence, accept it once with `sudo xcodebuild -license accept`.
- A **SteelSeries Apex Pro TKL Gen 3, wired (`1038:1642`)** for anything that
  touches the device. The unit tests and most of the app's UI need no keyboard.

There are no other dependencies. A change to the documentation alone needs no Mac:
`python3 Scripts/check-repo.py` (Python 3.9 or later, standard library only) runs
the same checks as `make check`, on any system.

## Everyday commands

| Command | What it does |
|---|---|
| `swift build` | Every product, debug |
| `swift test` | The unit tests; no keyboard needed |
| `swift test --filter MappingsTests` | One suite |
| `swift test --filter MappingsTests/testWriteFrameHeaderAndSize` | One case |
| `make check` | Docs links and anchors, PRD references, whitespace, workflows, scripts |
| `make lint` | ShellCheck and actionlint, the way CI runs them (`brew install shellcheck actionlint` first) |
| `make test-tools` | The tests of the repository checks themselves (`Scripts/test_check_repo.py`); run it if you change `Scripts/check-repo.py` |
| `swift run ApexControlApp` | The app, unbundled |
| `swift run apexctl info` | The CLI; or `.build/debug/apexctl <command>` once you have run `swift build` |
| `make app` | `build/Apex Control.app` (release). It is ad-hoc signed unless you have made a [signing identity](#keeping-permissions-across-rebuilds), and it does not include `apexctl`. |
| `open "build/Apex Control.app"` | Run that bundle |
| `swift build -c release` | Also builds the release `apexctl`; `swift build -c release --show-bin-path` prints the folder it lands in (usually `.build/release`) |
| `make package` | `dist/`: universal DMG, apexctl zip, SHA256SUMS |

`make help` lists the Make targets. `make check` and `swift test` are the minimum
before a pull request, but CI runs more: ShellCheck and actionlint (`make lint`), a
security audit of the workflows (zizmor), a release build, a packaging dry run, and
the tests on several Xcode versions, one of them on an Intel Mac.

### Unbundled or bundled?

`swift run ApexControlApp` is the quickest loop and is fine for almost
everything. But a bare executable has no `Info.plist` and no stable identity, so
macOS judges it by the terminal it was started from. Use the bundle
(`make app`) for anything involving permissions (Reactive lighting) or launch at
login, which also needs the app to be signed and in `/Applications`.

### Before you run your own build

- **Quit an installed Apex Control first, and SteelSeries GG if you have it.** Two
  programs streaming lighting to one keyboard fight over it. The app's
  single-instance check only stops a second *bundled* copy with the same bundle
  identifier (`io.github.rikearon.apex-control`). `swift run` starts a bare
  executable with no bundle, so nothing stops it from running next to an installed
  copy.
- **The app saves to the keyboard's flash by itself.** It rewrites the boot profile
  (slot 0) about three seconds after you change bindings, actuation, rapid trigger
  or rapid tap; after it connects, if the saved profile differs from what the app
  holds (a profile applied at launch, say); and once more when it quits. Before you
  try a build on a keyboard whose settings matter, keep a copy:
  `apexctl profile read 0 --out backup.bin`. The file holds your keyboard's GUID, so
  keep it out of public issues.

## The hardware verification loop

There is no device simulator ([PRD-31](prd/PRD-31-device-simulator-test-harness.md)),
so anything that talks to the keyboard is checked against a real one, with
`apexctl`. Know which commands are safe:

| Kind | Commands |
|---|---|
| **Read-only** | `info`, `bindings [layer]`, `profile read [slot]`, `raw read`, and `raw query` with a read request |
| **Writes keyboard RAM** (undone by unplugging) | `solid`, `key`, `rainbow`, `wave`, `actuation`, `rapidtrigger`, `bind`, `unbind`, `reset-bindings`, `fn`, `oled text\|image\|clear` |
| **Writes RAM, then puts it back** | `verify` rebinds Caps Lock to Ctrl+A for a moment (its first choice, F13, is not a rebindable key on this keyboard), reads that back, and writes the layer back as it read it. Read-back is intermittent, so a failed run can stop before the restore. Check `apexctl bindings`; if Caps Lock still says Ctrl+A, run `apexctl unbind Caps`, or unplug the keyboard, which clears RAM. |
| **Writes flash** (survives unplugging) | `profile save`, `profile restore`, and anything you send with `raw` that does |
| **Stores an OLED image in the keyboard** | `oled persist text\|image`. The image stays after the app quits ([PROTOCOL.md](PROTOCOL.md)). Whether it survives unplugging has not been recorded, so treat it like a flash write. |
| **Switches the active onboard slot** | `profile <slot>`. Whether the switch outlasts a power cycle is unconfirmed ([COMPATIBILITY.md](COMPATIBILITY.md) and the Profiles pane both say so). |
| **Hands lighting back** | `clear` |

Running Apex Control is not read-only either; see
[Before you run your own build](#before-you-run-your-own-build).

A typical loop, from the repository root after `swift build`:

- `.build/debug/apexctl info`: firmware, region, layout, key counts.
- `.build/debug/apexctl verify`: write a binding, read it back, restore it.
- `.build/debug/apexctl bindings`: all three layers, read off the keyboard's RAM.
- `.build/debug/apexctl profile read 0`: slot 0's boot profile, read off the flash.
- `.build/debug/apexctl profile save 0`: persist the current RAM bindings into flash.
- `.build/debug/apexctl clear`: hand lighting back to the keyboard.

Slots are numbered 0 to 4 by the CLI, by [PROTOCOL.md](PROTOCOL.md) and by the code.
The Profiles pane calls the same slots 1 to 5.

`apexctl info` on the reference keyboard prints:

```
Apex Pro TKL Gen 3 (0x1038:0x1642)
  connected:       true
  firmware:        1.19.7
  region:          US (1)
  layout:          ANSI (US)
  LEDs:            86
  adjustable keys: 68
  rebindable keys: 91
```

`apexctl raw` is the experimentation surface for protocol work. The first command
below reads the normal-layer binding of the A key (HID `0x04`). The reply is
`B6 00 00 01 04 51 04 00 00 00`: command, error 0, layer 0, one key, then (hid,
function, key codes). A is mapped to itself, the factory resting state.

```bash
apexctl raw query --delay 20 --gets 3 B6 00 01 04
apexctl raw read 644
apexctl raw feature <hex bytes...>
apexctl raw output <hex bytes...>
```

`raw read 644` is a GET_REPORT with no preceding write. `raw feature` and `raw
output` send a Feature or Output report as-is. `raw query` sends a SET_REPORT and
then reads with a GET_REPORT, the request-and-reply pattern the keyboard uses for
bulk read-back. `--delay` waits (in milliseconds) before the read, `--gets` repeats
it, and `--poll` keeps reading until the error byte clears, for the commands that
answer late. `raw feature` and `raw output` send exactly what you give them, so know
what a command does before you send it, and read back afterwards. Every `raw` command
stops with an error, and sends nothing, if an argument is not a hex byte or there are
too many bytes (64 for `output`, 644 for `feature` and `query`).

Some rules from experience:

- **Never experiment with flash on a keyboard whose settings you cannot afford to
  lose.** Read the flash invariant in [ARCHITECTURE.md](ARCHITECTURE.md#invariants-that-will-bite-you)
  first. `apexctl profile read 0 --out backup.bin` before you start gives you a
  file to restore with `profile restore`. To restore: quit Apex Control first (it
  would otherwise save its own state over the restored image), run
  `apexctl profile restore 0 backup.bin`, then unplug and replug the keyboard so it
  starts from the restored profile. The file contains your keyboard's GUID, so keep
  it out of public issues.
- Binding read-back is intermittent on firmware 1.19.7. If a read fails, retry
  before concluding anything.
- State what you verified, and on which firmware, in your pull request.

## The development harnesses

Three harnesses live in `Sources/ApexControlApp/Support/`. Each is **inert unless
its environment variable is set**. While one is enabled, the app does not start
its device connection, so **none of them touches the keyboard**, and all of them
bypass the single-instance check so they can run while the real app is open.

### Screenshots

The app draws its own window into a bitmap, so this needs no Screen Recording
permission:

```bash
APEX_SNAPSHOT_DIR=/tmp/shots "build/Apex Control.app/Contents/MacOS/Apex Control"
```

It walks every pane, writes a PNG each (plus one of the menu-bar panel), and quits.
These variables adjust it:

| Variable | Effect |
|---|---|
| `APEX_SNAPSHOT_PANES=lighting,bindings` | Capture only these panes (the `Pane` names in `Navigator.swift`) |
| `APEX_SNAPSHOT_ACTIVE=1` | A second pass with a key selected and per-key modes on |
| `APEX_SNAPSHOT_WIDTH=1440` | The width of the capture in points (default 1280). Pictures are twice as wide in pixels, and the height follows the content. Much narrower widths squeeze the layout |

The two pictures in `docs/images/` are captured at the default width and scaled to
1600 pixels: `lighting.png` is the Lighting pane as it opens (Rainbow Wave), and
`key-bindings.png` is the Key Bindings pane from the second pass. Retake them whenever
the words or the layout of those panes change. From the repository root, after
`make app`:

```bash
APEX_SNAPSHOT_DIR=/tmp/shots APEX_SNAPSHOT_ACTIVE=1 APEX_SNAPSHOT_PANES=lighting,bindings "build/Apex Control.app/Contents/MacOS/Apex Control"
cp /tmp/shots/01-lighting.png docs/images/lighting.png
cp /tmp/shots/02-bindings-active.png docs/images/key-bindings.png
sips --resampleWidth 1600 docs/images/lighting.png docs/images/key-bindings.png
```

Then look at both before you commit them.

Two things to know:

- There is no keyboard connected in this mode, so every image shows the
  "No keyboard" state.
- `ImageRenderer` draws AppKit-backed controls (switches, text fields, pickers) as
  yellow placeholders. Panes that use them are not fit for screenshots. Take a
  real screenshot with ⇧⌘5 instead. See
  [ARCHITECTURE.md](ARCHITECTURE.md#swiftui-and-macos-constraints-when-developing).

### Key recording

Regression-tests the key recorder by posting synthetic events to the app itself. It
exits non-zero on failure:

```bash
APEX_KEYCAPTURE_SELFTEST=1 .build/debug/ApexControlApp
```

### Reactive lighting input

Reports whether Reactive lighting can actually see key presses, from inside the
bundle (a command-line probe answers for the terminal's permissions, not the
app's). It listens for 6 seconds by default and exits non-zero when the listener
could not start; `APEX_INPUT_DIAGNOSTIC_SECONDS=10` changes how long it listens. It
prints the name of every key you press while it runs.

```bash
APEX_INPUT_DIAGNOSTIC=1 "build/Apex Control.app/Contents/MacOS/Apex Control"
```

To drive real events at the app without touching the keyboard, post them with
`CGEvent.post` from a throwaway `swiftc` binary: a session tap sees posted events
exactly as it sees typed ones. Posting events needs the Accessibility permission
for the terminal you run that binary from (the app itself needs none for this).

## Keeping permissions across rebuilds

Reactive lighting needs Input Monitoring or Accessibility. Grant **Input
Monitoring**: it is the narrower permission, and the one whose system prompt the
app can reliably raise. macOS records the grant against the app's **code signature**, and an
ad-hoc signature is the hash of the binary itself, so every rebuild looks like a
different app. The old grant stays ticked in System Settings and silently stops
working.

`./Scripts/make-signing-identity.sh` creates a stable, self-signed certificate
named "Apex Control Local Signing" once, and `make app` then signs with it. Read
what it does before you run it:

1. It creates a self-signed certificate and key in a temporary directory.
2. It imports them into your **login keychain**.
3. It marks the certificate as trusted **for code signing only** in the **System**
   keychain, using `sudo`. This is an admin trust setting and applies to every user
   of the Mac.
4. It tries to let `codesign` use that one key without prompting. macOS may ask
   once on the first build; choose **Always Allow**.

It asks for confirmation first (pass `--yes` to skip), and does nothing if the
identity already exists. The certificate is local and self-signed. It is not a
Developer ID, does not let the app be distributed, and anyone who obtained its
private key could sign code that *your* Mac would accept, so do not export it.

**To remove it**, undo steps 3 and 2: take back the admin trust setting, delete the
certificate from the System keychain, and delete the certificate and its key from
the login keychain. In Terminal (the `sudo` commands ask for your password):

```bash
security find-certificate -c "Apex Control Local Signing" -p > local-signing.pem
sudo security remove-trusted-cert -d local-signing.pem
sudo security delete-certificate -c "Apex Control Local Signing" /Library/Keychains/System.keychain
security delete-identity -c "Apex Control Local Signing" ~/Library/Keychains/login.keychain-db
rm local-signing.pem
```

The `remove-trusted-cert` command is what takes back the admin trust setting from
step 3; if you delete the keychain items in Keychain Access instead, run it as well.
Afterwards `security find-identity -v -p codesigning` no longer lists the identity.

If you would rather not, every rebuild works; you just remove Apex Control from
System Settings, then Privacy & Security, then Input Monitoring (with "−") and add
the new build again.

## Recipes

### Add or change an `apexctl` command

Edit `Sources/apexctl/main.swift`: add the command to `usage()` and to the
`switch`, connect with `connectOrExit()`, and print what happened. Report errors
with `fail(_:)` rather than discarding them. Then document it in
[USING-THE-CLI.md](USING-THE-CLI.md).

Check every argument before `connectOrExit()`, and put any rule that can be pure
(hex bytes, slots, numbers) in `Sources/ApexKit/Model/ArgumentParsing.swift` with a
test in `ArgumentParsingTests`. A command line that gets past parsing writes to the
connected keyboard, so do not "try out" argument checks by running plausible commands:
test the pure rules with `swift test`, and run the command itself only on a keyboard
you can afford to change.

### Add or verify a protocol command

1. Read [PROTOCOL.md](PROTOCOL.md) and the neighbouring builder in
   `Sources/ApexKit/Protocol/`.
2. Establish the bytes with `apexctl raw`, on a keyboard, and note the firmware.
3. Add a **pure** builder that takes values and returns bytes, citing its source
   and stating its confidence in the doc comment.
4. Add unit tests for the exact bytes. Look at `MappingsTests` for the style.
5. Expose it through `ApexDevice`.
6. Document it in PROTOCOL.md, with how it was verified.

### Add a lighting effect

Add a case to `EffectKind` in `Sources/ApexKit/Lighting/LightingEngine.swift`,
teach the pure `LightingRender.render(config:time:)` to draw it (the on-screen
preview and the hardware stream share that function, so they cannot disagree), and
add tests in the style of `ReactiveLightingTests`. The tile appears in the Lighting
pane from `EffectKind.allCases`; give it a description and parameters there. Route
selection through `DeviceController.selectEffect(_:)`, never by setting
`lighting.kind` from a view.

### Add a setting to a config struct

Add the field with a default, and decode it with `decodeIfPresent` in the
struct's hand-written `init(from:)`, so profiles saved by older builds still load.
Add a test in `ConfigurationTests` that decodes JSON without the field.

### Add a pane

Add a case to `Pane` in `Navigator.swift` (title, icon, subtitle, `storage`, and
its group), and a case in `paneContent` in `ContentView.swift`. Build the view from
the `Design/` components. Say in `storage` whether the pane's settings live on the
Mac or in the keyboard.

## Adding another keyboard model

Apex Control drives one keyboard, and the code is built around that. It is worth
being direct about what a port involves so nobody starts it expecting a small
change.

- **The model is a compile-time namespace.** `ApexProTKLGen3` holds the USB ids,
  the key tables (86 LEDs, 91 rebindable keys, 68 analog switches), the physical
  layout and the actuation curve. It is referenced about ninety times across
  twenty files in `Sources/`, as a global rather than an injected value.
- **Command sets differ between models.** The full-size Gen 3 (`0x1640`) and the
  wireless variants (`0x1644`, `0x1646`) are believed to use different commands from
  the TKL ([PROTOCOL.md](PROTOCOL.md)), so a new model means new protocol builders and new
  hardware verification, not just new tables.
- **The interface says "Pro TKL Gen 3"** in a few places, and assumes one
  connected keyboard.

The planned route is [PRD-27](prd/PRD-27-multi-device-multi-model.md): turn the
namespace into a model value, inject it, and parameterise the command families.
That is a refactor that should land before any second model does.

The most useful thing you can do today is a *device support* report: your model's
USB ids and firmware, what `apexctl info` says, and the HID interface listing. The
[device support form](https://github.com/Rikearon/apex-control/issues/new?template=device_support.yml)
gives the one command that prints only SteelSeries interfaces and leaves out serial
numbers and location ids; paste its output as text, and read it through before you
post. With that, someone can tell how far your keyboard is from the one that is
supported.
