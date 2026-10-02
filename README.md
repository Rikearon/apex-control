# Apex Control

[![CI](https://github.com/Rikearon/apex-control/actions/workflows/ci.yml/badge.svg)](https://github.com/Rikearon/apex-control/actions/workflows/ci.yml)
[![Licence: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)

A native macOS app and command-line tool to control the **SteelSeries Apex Pro TKL
Gen 3** (wired, `USB 1038:1642`): per-key RGB, actuation points, rapid trigger, rapid
tap / SOCD, key remapping, and the OLED screen. It needs no SteelSeries GG, no kernel
extension, no root and no helper tool.

![Apex Control's Lighting pane: a live picture of the keyboard showing a rainbow wave, with the effect chooser and sliders below](docs/images/lighting.png)

Apex Control talks to the keyboard directly over its vendor HID interface. It began as
a personal project: the author wanted to control this keyboard from macOS without
running SteelSeries GG. Its core features (lighting, actuation, rapid trigger, key
remapping and the OLED) were checked on one real keyboard, on firmware 1.19.7;
[Compatibility](docs/COMPATIBILITY.md) says exactly what was checked and what was not.
The project is early (0.x), and its rough edges are listed in
[Known issues](docs/KNOWN-ISSUES.md). **The app saves settings into the keyboard's own
memory by itself, with no switch to turn that off**, so read the note at the start of
[Install](#install) before you run it.

> **Not affiliated with SteelSeries.** Apex Control is an independent, unofficial
> project. It is not affiliated with, endorsed by or sponsored by SteelSeries.
> "SteelSeries", "Apex" and "GG" are trademarks of their owners and are used here
> only to identify the hardware and software this works with. The name "Apex Control"
> is this project's own. Use it at your own risk: the [licence](LICENSE) has no warranty.

## Does it work with my keyboard?

**Only the wired Apex Pro TKL Gen 3 (`1038:1642`) is supported.** Other Apex models,
including the full-size Gen 3 and the wireless variants, are believed to use different
commands. Sending them the wrong ones can change their settings, so the app does not try. To
check yours, run this in Terminal and look for `Product ID: 0x1642`:

```bash
system_profiler SPUSBHostDataType SPUSBDataType | grep -i -A12 apex | grep -E 'Apex|Vendor ID|Product ID|Product Version'
```

[Compatibility](docs/COMPATIBILITY.md) also covers Macs: it needs macOS 14 or later,
on Apple Silicon or Intel (Intel is untested on hardware).

## Install

> **Back up the keyboard before you first run the app.** Apex Control rewrites the
> keyboard's onboard profile (slot 0) by itself, and there is no setting to turn that
> off. A write that is cut short can leave the slot empty. With the command-line tool
> (a separate download, below), `apexctl profile read 0 --out backup.bin` saves a copy
> and `apexctl profile restore 0 backup.bin` writes it back. See
> [Safety and notes](#safety-and-notes).

### Download

1. Download `ApexControl-<version>.dmg` from the
   [latest release](https://github.com/Rikearon/apex-control/releases/latest),
   open it, and drag **Apex Control** to **Applications**.
2. macOS will not open it at first, because the release is not notarized (there is no
   Apple Developer ID yet). Try to open it once, then go to **System Settings, Privacy
   & Security**, scroll to the message about Apex Control and choose **Open Anyway**. Or
   run `xattr -dr com.apple.quarantine "/Applications/Apex Control.app"`.
3. Plug the keyboard in with its USB cable.

The command-line tool is `apexctl-<version>-macos.zip` on the same page. Each release
has `SHA256SUMS` and a build attestation; see [Privacy and security](docs/PRIVACY.md#releases)
for how to check them.

### Build from source

You need macOS 14 or later and Xcode 16 or later (Xcode 16 itself needs macOS 14.5 or
later). There are no other dependencies. Quit any other copy of Apex Control, and
SteelSeries GG if it is running, before you start your own build: two programs writing
to the keyboard at once can overwrite each other's settings.

```bash
git clone https://github.com/Rikearon/apex-control.git
cd apex-control
make app
open "build/Apex Control.app"
```

`make app` builds the app only. To build the command-line tool as well, run
`swift build -c release`; `swift build -c release --show-bin-path` prints the folder
that holds `apexctl`. For development, `swift run ApexControlApp` runs the app
straight from the source. See [Development](docs/DEVELOPMENT.md).

## What it does

- **Per-key RGB lighting** with a live picture of the keyboard that mirrors the
  hardware. Effects are rendered on your Mac and streamed to the keys: **Static,
  Per-Key paint, Rainbow Wave, Spectrum Cycle, Breathe, and Reactive**, so you are not
  limited to the firmware's built-in modes.
  - **Reactive** lights the key you press and sends a **ripple** across the board,
    with controls for the fade, how far the ripple reaches, how fast it travels, and
    how brightly unpressed keys rest. Modifiers count, and left and right are told
    apart.
  - Per-key painting has paint, pick and erase tools, and works by click-and-drag.
- **Key remapping**: bind a key to another key, a modifier combination
  (Cmd+Shift+4), a media control, a mouse button, the wheel, or nothing. Press **Press
  a key** and hit the combination you want instead of hunting through a list. Bindings
  are written **into the keyboard** a few seconds after you stop editing, so they keep
  working with the app closed, and should after unplugging and on another computer
  ([Compatibility](docs/COMPATIBILITY.md) records what has been checked).
  - Three layers: normal, the **Fn layer**, and a **second actuation layer** (partly
    verified) so one key can do two things depending on how deep you press it.
  - The app **reads the current bindings back off the keyboard**, so it shows what is
    really there. It keeps the Fn-layer shortcuts the keyboard shipped with unless you
    rebind or clear those keys yourself.
- **Actuation** from **0.1 mm to 4.0 mm** (nominal: the values come from the vendor's
  description of the device, and the physical travel has not been measured), globally or **per
  key**, with a live heat map.
- **Rapid Trigger**, globally or per key, with adjustable sensitivity.
- **Rapid Tap / SOCD**: up to 10 opposing-key pairs, such as the classic A/D "null bind"
  for counter-strafing. What each resolution mode does on the keyboard has not been
  checked ([Compatibility](docs/COMPATIBILITY.md)).
- **OLED screen**: text, an image or a live clock on the 128 x 40 display, with a
  *Save to keyboard* option (that it survives a power cycle has not been verified).
- **Profiles**: name and save complete setups, switch in one click, and export or
  import them as JSON. The app can also ask the keyboard to switch between its five
  onboard slots; that part is unverified, see [Compatibility](docs/COMPATIBILITY.md).
- **Lives in the menu bar**: keep effects running with the window closed, hide the Dock
  icon, and re-light after sleep.
- **A command-line tool**, `apexctl`, with the same engine, for scripts and quick tests.

[Using the app](docs/USING-THE-APP.md) goes through every pane.

## Command line

`apexctl` uses the same engine as the app. Quit the app first, because two programs
driving the keyboard at once fight over it. Then, one command at a time:

- `apexctl info`: firmware, region and layout.
- `apexctl solid '#FF4A00'`: every key one colour.
- `apexctl key W '#00FF00' A '#00FF00' S '#00FF00' D '#00FF00'`: light only the keys
  you name; every other key goes dark.
- `apexctl rainbow 8`: 8 seconds of animated rainbow.
- `apexctl actuation 8 --rapid-trigger`: 0.8 mm, with Rapid Trigger.
- `apexctl oled text "Hello" "world"`: two lines of text on the screen.
- `apexctl clear`: hand lighting back to the keyboard.
- `apexctl bindings`: read all three key-binding layers off the keyboard.
- `apexctl bind Caps key "Left Ctrl"`, `apexctl bind SS media playPause` and
  `apexctl bind F12 key 4 +cmd +shift` (Cmd+Shift+4): rebind a key. `apexctl unbind Caps`
  puts one back to its default.
- `apexctl profile save`: write the current bindings into the keyboard's flash. `bind`
  and `unbind` alone change only the keyboard's live memory, which is lost when it
  loses power.

Every command, and what it writes, is in [Using the command line](docs/USING-THE-CLI.md).

## Permissions

- **Lighting, actuation, OLED, bindings:** none. The keyboard exposes its control
  protocol on a *vendor* HID interface, which macOS does not seize exclusively, so an
  ordinary app can use it with no entitlement, kernel extension or root.
- **Reactive lighting only:** it needs to see which keys you press. **Input
  Monitoring** or **Accessibility** (either is enough), under System Settings,
  Privacy & Security. Key presses are used only by the Reactive effect, to light keys and
  to check that macOS is delivering them; nothing you type is written to disk, logged or
  sent. The app makes no network connections at all. See
  [Privacy and security](docs/PRIVACY.md), which shows how to check that yourself.

## Documentation

| | |
|---|---|
| [Using the app](docs/USING-THE-APP.md) | What every pane does |
| [Using the command line](docs/USING-THE-CLI.md) | Every `apexctl` command |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Keyboard not found, Reactive lighting, settings that revert |
| [Compatibility](docs/COMPATIBILITY.md) | What is supported and verified, and by whom |
| [Known issues](docs/KNOWN-ISSUES.md) | Rough edges we already know about |
| [Privacy and security](docs/PRIVACY.md) | What the app does with your key presses, and how to check |
| [Protocol reference](docs/PROTOCOL.md) | The keyboard's HID protocol, byte by byte |
| [Architecture](docs/ARCHITECTURE.md) and [Development](docs/DEVELOPMENT.md) | For contributors |
| [Roadmap](docs/FEATURE-GAP-ANALYSIS.md) | Where this stands against SteelSeries GG, and a requirements document for each planned feature |
| [All documentation](docs/README.md) | The index, with a glossary of the terms used |

## How it works

The keyboard is driven entirely through Apple's `IOHIDManager`:

- It matches `VendorID 0x1038`, `ProductID 0x1642`, `UsagePage 0xFFC0`, `Usage 0x0001`.
- Report ID `0`. **Feature reports** (644-byte payload) carry bulk data such as per-key
  colours, actuation tables and OLED frames; **Output reports** carry short commands and
  query requests; queries read the reply back as an **Input report**.

The command set was worked out from the vendor's device description files as installed
on the author's own computer and from USB captures of the author's own keyboard, was
cross-checked against public community projects, and was then checked against the
keyboard itself. This
repository contains no vendor files and no vendor code, and none is needed to build or
use the project. [`docs/PROTOCOL.md`](docs/PROTOCOL.md) is the command reference; it
says how sure each claim is, and you can test a claim on your own keyboard with
`apexctl raw`, at your own risk.

## Safety and notes

- The app never forces the keyboard back to onboard lighting when you quit, so your
  colours stay, frozen, until something changes them. To give lighting back, use **Hand
  Lighting Back to Keyboard** (the Keyboard menu or the menu bar) or `apexctl clear`.
  *Turn Lighting Off* only paints the board black; the app stays in charge.
- **Bindings outlive the app.** A key you disable stays disabled with Apex Control
  closed, and should on any computer. **Reset all keys** in the Bindings pane (or **Reset all key
  bindings** in the menu-bar panel) puts the keys back. From a terminal, quit the app,
  run `apexctl reset-bindings` and then `apexctl profile save`; the first alone changes
  only the keyboard's live memory.
- Reset deliberately leaves the **Fn layer** alone. It holds the shortcuts the keyboard
  shipped with (the SteelSeries-key combinations for brightness, media and the OLED; nine
  keys on the keyboard we tested), and we know of no keyboard command that restores them
  once overwritten (only a backup made beforehand, next point).
  Rebinding one of those keys, or clearing the layer, is a separate, explicit action.
- **Take a backup first.** The app rewrites the keyboard's onboard profile (slot 0)
  by itself, and there is no setting to turn that off. Before you run it on a keyboard
  whose settings matter, keep a copy with `apexctl profile read 0 --out backup.bin`
  (the file contains your keyboard's GUID, so keep it to yourself);
  [Using the command line](docs/USING-THE-CLI.md#onboard-profiles-flash) explains how
  to restore it.
- Settings written to the keyboard's flash are saved automatically a few seconds after
  you stop editing, with a read-modify-write that is checked by reading it back (a final
  save when you quit skips that check so that quitting is not held up). The tag at the
  top right of the panes whose settings live in the keyboard shows whether they are
  saved.
- The region-write command touches flash and is intentionally **not** exposed in the
  UI; set your region once in official software if the keycap legends ever look wrong.
- A few rough edges are known: [Known issues](docs/KNOWN-ISSUES.md).

## Contributing

Contributions are welcome, and you do not need to write Swift to help: a bug report
with the right details, a protocol finding checked on your keyboard, or a documentation
fix all matter. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, particularly the hardware
safety rules. Ask questions in
[Discussions](https://github.com/Rikearon/apex-control/discussions),
and see [SUPPORT.md](SUPPORT.md) for where to go for what. Report vulnerabilities
privately, as described in [SECURITY.md](SECURITY.md). Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Licence

The code, scripts and documentation are released under the [MIT licence](LICENSE),
except two files that are licensed under [CC BY 4.0](LICENSES/CC-BY-4.0.txt):
[`docs/PROTOCOL.md`](docs/PROTOCOL.md), so that the protocol knowledge can be reused,
with attribution, by other projects, and the [Code of Conduct](CODE_OF_CONDUCT.md),
which is adapted from the Contributor Covenant. Copyright (c) 2026 Henrique Aron,
except where a file says otherwise. [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
credits the one table of numbers that agrees with another project's.

## Credits

The command set was cross-checked against the public projects
[OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) (GPL-2.0),
[apex-tux](https://github.com/not-jan/apex-tux) (Unlicense) and
[OmniLED](https://github.com/llMBQll/OmniLED) (GPL-3.0); thank you to their authors.
Their licences differ from this project's, which is why
[CONTRIBUTING.md](CONTRIBUTING.md#ground-rules) asks contributors not to copy code from
them. The macOS-to-USB key code table agrees with the one in
[Chromium's key code data](https://source.chromium.org/chromium/chromium/src/+/main:ui/events/keycodes/dom/dom_code_data.inc);
its licence (BSD-3-Clause) is reproduced in
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). The Code of Conduct is adapted from the
[Contributor Covenant](https://www.contributor-covenant.org).
