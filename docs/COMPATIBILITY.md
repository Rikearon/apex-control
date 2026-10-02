# Compatibility

What Apex Control works with, what has been checked, and by whom. A status here
is a statement of evidence, not a promise: a cell that says *unverified* means
nobody has tried it, not that it is broken.

This page is kept by hand. The plan is to generate it from committed capability
reports ([PRD-30](prd/PRD-30-protocol-conformance-probe.md),
[PRD-37](prd/PRD-37-project-docs-compatibility-community.md)); until then, if you
have evidence that a row is wrong, please open a
[protocol finding](https://github.com/Rikearon/apex-control/issues/new?template=protocol_finding.yml).

## Keyboards

| Keyboard | USB id | Firmware | Status |
|---|---|---|---|
| **SteelSeries Apex Pro TKL Gen 3, wired** | `1038:1642` | 1.19.7 | **Supported.** The one keyboard the project was built on and verified against. |
| Apex Pro Gen 3, full size | `1038:1640` | not seen | **Not supported.** Believed to use a different command set; untested ([PROTOCOL.md](PROTOCOL.md)). |
| Apex Pro Gen 3 wireless variants | `1038:1644`, `1038:1646` | not seen | **Not supported.** Believed to use another command set, plus battery and radio to handle; untested ([PRD-28](prd/PRD-28-wireless-variants-battery.md)). |
| Any other keyboard | | | **Not supported.** |

The name "Gen 3" is shared across these models, but their protocols are believed to
differ. Do not expect a different model to work: a wrong command sent to a keyboard
can change its settings.

Only one keyboard at a time is handled. Region and layout are read from the
keyboard; the reference unit is a US region, ANSI (US) layout. Other layouts (ISO,
JIS) are unverified.

Multi-model support is planned as
[PRD-27](prd/PRD-27-multi-device-multi-model.md). If yours is a different model,
the [device support form](https://github.com/Rikearon/apex-control/issues/new?template=device_support.yml)
collects what is needed to judge how far away it is.

## What works on the supported keyboard

Firmware 1.19.7, on one keyboard (the maintainer's). **Verified** means it was
exercised on that keyboard; the last column says how it is known.

| Capability | Status | Evidence |
|---|---|---|
| Detect the keyboard; read firmware, region and layout | Verified | Re-run on 2026-09-28 (`apexctl info`); [PROTOCOL.md](PROTOCOL.md#queries--misc) |
| Per-key RGB, streamed from the Mac at 30 fps | Verified | Streaming rate and tearing limit measured on hardware ([PROTOCOL.md](PROTOCOL.md#implementation-notes-verified-on-hardware)). `4B` (enable direct mode) is an init that other RGB tools are reported to send; whether this keyboard strictly needs it is not established here. The app sends it on connect, on wake, when it applies a profile and when it takes lighting back. |
| Actuation, 0.1 to 4.0 mm, global and per key | Partly verified | The app writes the thresholds and they are stored in the boot profile (read back byte for byte with the slot image; see the onboard-slot row). The level-to-threshold table is *from descriptor* (not independently derived), and the physical travel at each level has not been measured ([PROTOCOL.md](PROTOCOL.md#actuation-level--raw-threshold)). |
| Second, deeper actuation point and deeper-press bindings | Partly verified | The second-layer thresholds and bindings are written and read back (68 keys, re-run 2026-09-28), and the maintainer reports it working in use; [PRD-03](prd/PRD-03-dual-bind-actuation.md) still lists as open whether a live second-layer binding latches on its own. |
| Rapid Trigger (release mode "Rapid Trigger") | Verified | Maintainer, during development. |
| Rapid Trigger alternate modes 3 and 4 | Unverified | The keyboard accepts them; what they do is not known. The app labels them "Alternate mode". |
| Rapid Tap (SOCD) pairs, and "report both keys" | Partly verified | The commands and the report-both flag are documented. What the four resolution modes do on hardware is not recorded; the names in the app are its own labels. |
| Key remapping: write and read back | Verified | Write and read round-trip ([PRD-01](prd/PRD-01-key-remapping.md)); read-back re-run 2026-09-28 on the normal, Fn and second layers. Read-back is intermittent on this firmware, so it retries. |
| Fn layer, and choosing the Fn key | Verified | Factory shortcuts are preserved on write ([PRD-02](prd/PRD-02-meta-fn-layer.md)). The Fn key can only be read back from flash. |
| Key bindings and the six standard media bindings | Verified | The six media controls are the ones the keyboard's own buttons use. |
| Mouse bindings | Unverified | The keyboard has a mouse collection to carry them ([PROTOCOL.md](PROTOCOL.md#the-devices-full-usbhid-interface-map)), but no click from a mouse binding has been recorded. |
| Other [HID](README.md#glossary) media usages (Stop, Launch Mail, Browser Back, and so on) | Unverified | Defined by the HID standard; this firmware may ignore them. |
| OLED text, image and clock | Verified | [PROTOCOL.md](PROTOCOL.md#oled-128--40-1-bpp): "verified working on `0x1642`". |
| OLED "Save to keyboard" | Partly verified | The command works. Whether the screen outlasts unplugging is not recorded. |
| Bindings, Fn key, actuation, rapid trigger and rapid tap saved into onboard slot 0 | Verified | Erase, 25-chunk write, validate and byte-for-byte read-back, first on a spare slot and then slot 0 ([PROTOCOL.md](PROTOCOL.md#onboard-profiles--the-flash-filesystem), [PRD-05](prd/PRD-05-onboard-profile-persistence.md)). Slot 0 re-read with a valid CRC on 2026-09-28. |
| Saved settings outlast unplugging the keyboard | Not yet re-checked | The firmware loads its boot profile from flash at power-up ([CLAUDE.md](../CLAUDE.md) records settings written before saving was added being lost at restart), so saved settings should come back, but a dated unplug-and-replug check is not recorded. To check on your own keyboard: wait for *Saved in the keyboard*, quit Apex Control, unplug and replug the keyboard, then run `apexctl bindings`. |
| Switching the active onboard slot | Unverified | The command is sent. Whether the choice outlasts a power cycle, and what "temporary" means, is not confirmed. |
| Reactive lighting | Verified | Maintainer, on hardware; the rules that decide whether key presses are really arriving are unit-tested. Needs Input Monitoring or Accessibility; see [Using the app](USING-THE-APP.md#reactive-lighting-and-permissions). |
| Macros | Not supported | [PRD-04](prd/PRD-04-macro-engine.md) |
| Firmware update, region write | Not supported | Deliberately not exposed: they write [flash](README.md#glossary) ([PRD-16](prd/PRD-16-firmware-update.md)). |
| Idle dimming | Not available | No command for it is known on this model, and its saved profile has no idle-timeout field, going by the vendor's description of the device (not tried on hardware; [gap analysis](FEATURE-GAP-ANALYSIS.md)). The Brightness slider only scales the colours the Mac sends, so it works while the app runs. |
| Lock-key and Fn-key indicator colours | Not yet | They live in the keyboard's saved profile, which Apex Control can write, but the app does not expose them ([PRD-10](prd/PRD-10-brightness-idle-indicator.md)). |

## Computers

| Configuration | Status |
|---|---|
| macOS 27.0, Apple Silicon | **Verified.** Built, unit tests passed, and the read-only hardware checks above were re-run on 2026-09-28. |
| macOS 26, Apple Silicon | Built with the macOS 26.5 SDK during development. The CI workflow is configured to build and test on it. |
| macOS 15, Apple Silicon | The CI workflow is configured to build and test on it, on Xcode 16.0, the minimum toolchain. |
| macOS 14 | The declared minimum (`LSMinimumSystemVersion`). Untested. Building from source needs Xcode 16 or later, and Xcode 16 itself needs macOS 14.5 or later. |
| Intel Macs | Release builds are universal, and the CI workflow is configured to run the tests natively on an Intel runner. **Nobody has driven a keyboard from an Intel Mac**, so the hardware side is unverified. |

The CI rows say what the [CI workflow](../.github/workflows/ci.yml) is set up to do;
check its latest run for what it has actually done.

## SteelSeries GG

Apex Control opens the keyboard's vendor interface without seizing it, so it should be
able to coexist with GG (this has not been tested with GG running). If GG's background
helpers are running, they may fight Apex Control for the lighting; quitting GG gives
the cleanest result. Bindings and settings
GG left in the keyboard are read back off it and shown, and Apex Control builds on them
rather than starting from blank. Anything you then change, or apply from a profile, is
written over them, and GG's helpers may write theirs again.

## Add your result

Tried it on other hardware, another firmware, or another macOS? Tell us with a
[protocol finding](https://github.com/Rikearon/apex-control/issues/new?template=protocol_finding.yml)
(for the keyboard) or a bug report (for the app), and say what you ran. That is how
an *unverified* cell becomes a *verified* one.
