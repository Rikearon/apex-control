# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Apex Control** — a native macOS app + CLI that drives a **SteelSeries Apex Pro TKL Gen 3, wired, `USB 1038:1642`** over its vendor HID interface: per-key RGB, actuation, rapid trigger, rapid tap/SOCD, key remapping, and the OLED. No kext, no root, no entitlement, no helper tool. It is an independent, unofficial alternative to SteelSeries GG for this one keyboard.

Swift 6 / SwiftPM, macOS 14+. No third-party dependencies.

**The protocol was worked out and checked on real hardware (one keyboard, firmware 1.19.7).** `docs/PROTOCOL.md` is the wire reference, and says how sure each claim is — read it before touching anything under `Sources/ApexKit/Protocol/`. Do not "fix" a packet builder to match an assumption; the odd-looking parts are odd because the firmware is.

## Commands

```bash
swift build                       # debug build of all three products
swift build -c release
swift test                        # the XCTest suite, no hardware needed
swift test --filter MappingsTests                              # one suite
swift test --filter MappingsTests/testWriteFrameHeaderAndSize  # one case

./Scripts/build-app.sh release    # → build/Apex Control.app (ad-hoc signed unless a signing identity exists)
open "build/Apex Control.app"
swift run ApexControlApp          # dev run of the GUI
swift run apexctl info            # or .build/debug/apexctl <cmd>

make check                        # docs links/anchors, PRD refs, whitespace, workflows, scripts (Scripts/check-repo.py)
make lint                         # shellcheck + actionlint, as CI does (needs both installed)
make test-tools                   # tests of Scripts/check-repo.py itself (run it if you change the checker)
make package                      # dist/: universal DMG, apexctl zip, SHA256SUMS (what the release workflow runs)
```

Run `make check` and `swift test` before finishing any change (`make lint` too if you touched a script or a workflow). `make help` lists every target. CI runs more than `make check`: see `docs/DEVELOPMENT.md`.

`swift test` covers packet framing, key tables, config codecs, and key-capture rules — everything that can be checked without a keyboard. Anything involving the device itself is verified with `apexctl` against real hardware; there is no device simulator (PRD-31 is unimplemented).

### Hardware verification loop

Quit the Apex Control app first for anything that writes (`verify`, `bind`, `profile save`, `raw feature|output`): the app re-applies its own state, and two writers fight over the keyboard. Take a backup before any experiment that writes (`profile read 0 --out backup.bin`; the file holds the GUID, so it never goes in the repository), and prefer the read-only commands.

```bash
.build/debug/apexctl info                      # firmware, region, layout, key counts
.build/debug/apexctl verify                    # 0x36 write → 0xB6 read round-trip (remaps Caps Lock to Ctrl+A meanwhile; if the read-back fails it may not put it back)
.build/debug/apexctl bindings                  # dump all three layers off the device (RAM)
.build/debug/apexctl profile read 0            # dump the boot profile off the flash
.build/debug/apexctl profile save 0            # persist current RAM bindings into flash
.build/debug/apexctl raw query --delay 20 B6 00 5B …   # poke an undocumented command
.build/debug/apexctl raw read 644              # GET_REPORT with no preceding write
.build/debug/apexctl clear                     # hand lighting back to the keyboard
```

`apexctl raw feature|output|read|query` is the experimentation surface for protocol work — `query` does a SET_REPORT-then-GET_REPORT round trip with `--delay`, `--gets`, and `--poll` for the commands that answer late.

### Dev-only harnesses inside the app

All three are env-gated, inert otherwise, and deliberately bypass `AppDelegate.terminateIfDuplicate` (and never touch the keyboard) so they can run while the real app is open.

```bash
# Screenshot every pane. Needs no Screen Recording permission — the app draws itself.
APEX_SNAPSHOT_DIR=/tmp/shots "build/Apex Control.app/Contents/MacOS/Apex Control"
#   APEX_SNAPSHOT_PANES=lighting,bindings   subset
#   APEX_SNAPSHOT_ACTIVE=1                  second pass with a key selected + per-key modes on
#   APEX_SNAPSHOT_WIDTH                     width in points (height follows the content)

# Regression-test key recording by posting synthetic NSEvents to ourselves.
APEX_KEYCAPTURE_SELFTEST=1 .build/debug/ApexControlApp     # exits non-zero on failure

# Report whether reactive lighting can actually see key presses, from inside the
# bundle — a CLI probe answers for the terminal's permissions, not the app's.
APEX_INPUT_DIAGNOSTIC=1 "build/Apex Control.app/Contents/MacOS/Apex Control"
#   APEX_INPUT_DIAGNOSTIC_SECONDS=10        how long to listen (default 6)
```

Drive real events at it with `CGEvent.post` from a throwaway `swiftc` binary
(the posting process needs Accessibility, which a terminal can have; the app under
test does not need it): a session tap sees posted
events exactly like typed ones, so the whole path is testable without touching
the keyboard.

## Architecture

Three SwiftPM targets, strictly layered — **`ApexKit` has no UI and no AppKit dependency in its protocol layer** (the one exception is `Protocol/OLEDGraphics.swift`, which renders text and images and imports CoreGraphics, CoreText and AppKit), so the CLI and the GUI are genuinely the same engine.

```
ApexKit ──┬── apexctl          (CLI front-end)
          └── ApexControlApp   (SwiftUI app)
```

### ApexKit

- **`Transport/HIDTransport.swift`** — `IOHIDManager` on a dedicated background thread with its own run loop, so input-report callbacks (query replies) arrive while a caller is blocked waiting for one. Three access patterns: `sendFeatureReport`/`sendOutputReport` (fire-and-forget), `queryFeature` (SET_REPORT → GET_REPORT, used for binding read-back), and `query` (Output report → await Input report, used for firmware/region/layout). A `queryGate` lock serialises round-trips so two concurrent queries cannot eat each other's replies.
- **`Protocol/*`** — pure, testable packet builders. No I/O. Each file owns one command family and says in its doc comment where the layout comes from and how sure that is (*confirmed on hardware* / *from descriptor* / *needs RE*).
- **`Model/Key.swift`** — `ApexProTKLGen3` is the single source of hardware truth: the firmware's `deviceKeyIndexToHID` slot table, and the three *different* key sets derived from it (see the invariants below). Also the physical layout used for rendering.
- **`Lighting/LightingEngine.swift`** — renders effects on the host and streams them at 30 fps from its own `DispatchQueue`. `LightingRender.render` is a pure function shared by the streamer and the on-screen preview so they cannot drift apart.
- **`ApexDevice.swift`** — the façade both front-ends use. Everything above is reachable through it.

### ApexControlApp

- **`AppEnvironment.shared`** owns the long-lived objects (controller, profile store, prefs, navigator) *outside* the SwiftUI scene graph. This is load-bearing: with "run in background" on, the app can be running with no window at all (login launch, window closed), and a `@StateObject` on a view would leave the keyboard dark until something appeared on screen.
- **`DeviceController`** is `@MainActor` and is the single source of truth for the UI. **USB I/O stays off the main actor** — a wedged control transfer must not freeze the UI. Most writes go through `perform(_:_:)` onto `deviceQueue`; the OLED clock timer and the quit-time flush use `deviceQueue` directly, and the lighting engine streams from its own queue. Slider-driven writes are coalesced through Combine `throttle` subjects (16 ms lighting, 120 ms bindings/actuation) because a binding write is ~2 KB across three layers.
- **`Navigator` / `Pane`** — pane selection lives outside the view tree so the menu bar, ⌘-shortcuts, and the snapshot harness can all drive it. `Pane.storage` declares whether a pane's settings live on the Mac or in the keyboard; the UI states this on every pane rather than burying it.
- **`Design/`** is a real design system (`Card`, `SwitchRow`, `SegmentedRail`, `ScaleControl`, `Banner`, `TravelGauge`, `KeyCaptureButton`, …). Build panes from these, not from raw SwiftUI controls.

## Invariants that will bite you

These are all things that cost a hardware debugging session to discover. They are documented at their definition sites too; this is the index.

**Every mapping write is a complete frame for its layer.** `Mappings.writeChunks` fills in *every* key the layer addresses. So the value written for keys the user never touched decides their fate, and it differs per layer:

- **Normal layer blank = the key mapped to its own usage** (`51 <hid> 00 00 00`), *not* `function 0`. Reading a stock keyboard back returns exactly that self-mapping for all 91 keys. "Reset this key" must write the self-mapping.
- **Meta/Fn and second-actuation blank = `unbound` (`function 0`).** A self-mapping on the Fn layer would make every key fire itself.

**Never write the Fn layer without reading it first.** It ships with nine `0x62` firmware-function entries — the SteelSeries-key brightness/media/OLED shortcuts — with payloads we know of no command to restore. A frame built without them erases them. `Mappings.Layer.isSafeToWriteUnread` and `DeviceController.writeBase(for:mine:)` enforce this in the app; the CLI's `bind` and `unbind` read the layer first and write nothing if the read fails. `resetAllBindings()` deliberately leaves the Fn layer alone. The one deliberate exception is the confirmed "Clear the Fn layer too" action (`resetFnLayer()`), which keeps an undo snapshot.

**`function 0x62` is not "this is the Fn key."** The vendor's description calls it META, but it means "run firmware function *n*", selected by `key_codes`. The key that *activates* the layer is chosen separately with `0x35 <hid>`. Treat the function ids as opaque: read, keep, write back unchanged.

**Three different key sets, all addressed by HID usage code.** 86 LEDs · 91 rebindable keys · 68 analog (adjustable) switches. `0xFB` (play/pause by the OLED) lights but cannot be rebound; the six media/OLED buttons neither light nor rebind; the second-actuation layer only covers the 68 analog keys. Use `ledHIDOrder` / `mappableHIDOrder` / `analogHIDOrder` — never assume one implies another.

**Binding read-back (`0xB6`) is intermittent on firmware 1.19.7.** The request is always acknowledged but the payload only comes back some of the time. `readMappings` retries; every caller must handle it throwing, and the app degrades to "read-back unavailable" rather than failing. The request must carry the list of HID codes you want — without a block list the device answers `err = 1`.

**Every live config command writes keyboard RAM only — flash is a separate act.** `0x36` bindings, `0x38 61` actuation, rapid tap, the `0x35` Fn trigger: all of it survives quitting the app but **not unplugging the keyboard**. Verified on hardware: after a `0x36` write the flash image is byte-for-byte unchanged, with the profile-volatility command (`0x34`) at either value. At power-up the firmware reloads the boot profile from flash — this was the "some bindings don't survive a restart" bug. Persistence is the onboard-profile flash write (`OnboardProfile` + `ApexDevice.writeOnboardProfile`): **always read-modify-write** (the image carries macros, GUID, the factory Fn shortcuts — things the app cannot rebuild from its own state), never write an image that failed validation, and verify by read-back. `DeviceController` auto-persists to slot 0 on a 3 s diff-gated debounce (`persistToKeyboard`), flushes on quit (`flushPersistOnQuit`: synchronous, waits up to 8 s, and skips the read-back verify so that quitting stays fast), and pauses the lighting stream around the write — flash ops stall the control pipe. The UI reports `persistState`; never let it claim "saved in the keyboard" for a RAM-only write.

**Bindings and actuation outlive the app** (RAM while powered, flash across power loss once persisted) — that is why binding edits have an undo stack (`DeviceController.undoStack`, bounded at 64) whose snapshots fold in what was read off the device, and why connecting never pushes bindings unless the app actually has some.

**The Fn trigger key is only readable from the flash image** (offset 76). `bindings.metaToggleHID == nil` means "never touched — leave the keyboard's own trigger alone"; an explicit "no Fn key" is stored as `0`. Writing `35 00` on connect used to silently disable the factory SteelSeries-key trigger.

**30 fps is the lighting ceiling.** Streaming full frames faster outpaces the LED controller and tears. Direct-mode colours stay for as long as the keyboard has power — only `0x41` (`clearLighting`) hands the board back. The app never forces onboard mode on quit, by design.

**`0x75` (write region) touches flash on every call** and is intentionally not exposed in the UI.

## macOS / SwiftUI constraints when developing

- **Assume no Screen Recording permission**: there is no way to grant it from a shell, and `screencapture` fails without it. `NSView.cacheDisplay` and `CALayer.render(in:)` both return blank for SwiftUI. Only `ImageRenderer` over the view tree works — hence `SnapshotHarness`.
- **`ImageRenderer` limits**, worked around via the `\.isSnapshotting` environment key: it draws **no `Text` at all** inside a `GeometryReader` subtree, and renders `List`/`ScrollView`/AppKit-backed controls as a yellow placeholder. Views swap those containers for plain stacks under the flag. The shipping path always uses the native containers — the harness bends to the app, never the reverse.
- **The app itself has no Accessibility permission** in a normal development setup, so `CGEvent.post` from *inside* it cannot synthesise input for other processes. What works with zero permission is the app posting events **to itself**: `NSApp.postEvent(NSEvent.keyEvent(…))` walks the same `sendEvent` path a real press does. That is how `KeyCaptureSelfTest` exercises the recorder. (A separate throwaway binary run from a terminal that has Accessibility can post real events; see above.)
- **Reactive lighting** is the one feature that needs a permission, and it is the one place the obvious implementation is wrong four ways. `KeyMonitor` is the reference; don't simplify it back.
  - **Two permissions, either sufficient**: Accessibility (`AXIsProcessTrusted`) *or* Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`). They live in different System Settings panes; `KeyMonitor.requestPermission` asks for both, but `IOHIDRequestAccess` (Input Monitoring) is the one that reliably raises the system prompt.
  - **Never report the permission as the feature's state.** A grant on record and a tap macOS actually honoured are different facts; the gap between them is the whole of "I granted it and nothing happens". The UI reads `DeviceController.reactiveInput`, which comes from whether the tap was created.
  - **Modifiers are `flagsChanged`, not `keyDown`** — a mask without it silently drops every shift/ctrl/alt/cmd press. Use `MacKeyCode.pressedUsage(forFlagsChanged:flags:)`: it reads the per-side `NX_DEVICE*` bits, because `CGEventFlags.maskShift` cannot tell right shift from left shift already held.
  - **A tap can be switched off after creation** (`.tapDisabledBy*`, delivered whatever the mask says). Unhandled, the listener goes permanently deaf *and* the old code parsed those events as key presses. Re-enable on the event and from a watchdog.
  - **A created tap is not a hearing tap.** Without an honoured grant (never given, stale after an ad-hoc rebuild, or granted after launch) the window server still *creates* the listen-only tap and then withholds every other app's `keyDown` — modifiers (`flagsChanged`) and the app's own keys keep arriving. Symptom: shift/ctrl ripple from anywhere, letters only while the app is frontmost. `TapHealth` (ApexKit, pure + unit-tested) convicts that state from evidence — the HID system's last-key-down clock moved and the tap heard nothing, twice; a `keyDown` targeted at another pid is the only proof of delivery, because own-app keys arrive even when starved. The listener reports it as `.degraded`; never collapse that back into "listening".
  - Input Monitoring only applies to processes started **after** the grant, and TCC keys on the code signature — so an ad-hoc rebuild silently loses it while still showing as ticked. `Scripts/make-signing-identity.sh` fixes that properly; `build-app.sh` warns when it has not been run.
  - Starting goes through `DeviceController.syncKeyMonitor()` only, so launching straight into a saved reactive profile listens too (pausing, handing lighting back and quitting also stop the listener directly).

**"Lights off" is a black `baseColor`, so it poisons the next effect you pick.** `setLightingOff(true)` sets `kind = .staticColor, baseColor = .black`. Selecting a colour-driven effect afterwards keeps the black and renders an entirely black effect — on Reactive that is indistinguishable from the feature being broken, and it cost a debugging session that had nothing to do with the feature. Every effect button goes through `DeviceController.selectEffect(_:)`, which restores a visible colour first. Do not set `lighting.kind` directly from a view.
- **Rendering hot path.** For the 30 fps keyboard preview, measured on release builds: rebuilding 90 accessibility elements per frame was ~25% CPU — by far the largest cost — and `NSColor(swiftUIColor)` round-trips ~6%; shadows and gradients were noise. Hence `KeyAccessibilityLayer: Equatable`, `CapFace` keeping colour as plain `Double`s, `OLEDPixels: Equatable`, the preview running at 20 fps while the hardware gets 30, and pausing on `\.controlActiveState == .inactive`. `Equatable` on a `View` needs `nonisolated static func ==` under Swift 6. Don't undo these without re-measuring.

## Interface conventions

Dark-only on purpose: every pane previews light the keyboard is about to emit, and a light surround would misrepresent it. Colour carries meaning, not decoration — **graphite** is every surface, **signal orange (`Theme.signal`) marks something you set**, **readout cyan (`Theme.readout`) is the keyboard talking back** (measured values, the OLED). Never use one for the other's job. Distances are instrument readouts in millimetres, set in `Typo.readout` (monospaced, tabular).

Config structs (`LightingConfig`, `ActuationConfig`, `BindingsConfig`, `OLEDConfig`, `RapidTapConfig`) all hand-write `init(from:)` with `decodeIfPresent` + defaults so profiles from older and newer builds still load. Keep that when adding fields. `HIDMap` serialises HID-keyed maps as `{"0x2C": …}` so exported profiles stay hand-editable.

## Docs

- **`docs/PROTOCOL.md`** — byte-level command reference. Source of truth. Update it when hardware behaviour is newly confirmed, and say what was verified how.
- **`docs/FEATURE-GAP-ANALYSIS.md`** — parity against GG, bounded by the endpoints we have identified for this keyboard (the list in that file). If a capability isn't backed by one of them or by host-side logic, we know of no way for any software to do it.
- **`docs/prd/PRD-NN-*.md`** — one PRD per feature, `_TEMPLATE.md` for new ones. Each carries a **Status** line: `PRD-01/02/03/06/15` are implemented; `PRD-05`, `PRD-10`, `PRD-17`, `PRD-32`, `PRD-34` and `PRD-37` partially. Every PRD must be listed in the index in `docs/FEATURE-GAP-ANALYSIS.md` (`make check` enforces it). Code comments reference PRD numbers and requirement ids (FR-1, AC-4) — keep that thread when implementing one.

State confidence explicitly in protocol code and PRDs: *confirmed on hardware* / *from descriptor* / *needs RE* (defined at the top of `docs/PROTOCOL.md`). Several fields (the profile-volatility command's argument direction, macro id encoding, release modes 3 and 4) are declared but unverified, and are marked as such in the source.

## Open-source project conventions

This repository is open source (MIT; `docs/PROTOCOL.md` and `CODE_OF_CONDUCT.md` are CC BY 4.0). Humans read `README.md`, `CONTRIBUTING.md` and `docs/`; `docs/ARCHITECTURE.md` is the human-facing version of the architecture and invariants above, so change both together.

- **The version lives in one place**: `ApexVersion.current` in `Sources/ApexKit/Version.swift`. `Scripts/version.sh` reads it for `Info.plist`, packaging and the release workflow. Keep the declaration on one line.
- **Bundle identifier**: `io.github.rikearon.apex-control`. macOS keys privacy grants and preferences on it, so do not change it lightly.
- **Releases are one tag** (`vX.Y.Z`, matching `Version.swift`, with a `CHANGELOG.md` entry). The steps are in `docs/MAINTAINING.md`. Add a line under `## [Unreleased]` in `CHANGELOG.md` for anything a user would notice.
- **The app promises no network access** (`docs/PRIVACY.md`). `make check` fails on any networking API under `Sources/`; changing that promise means changing the policy documents in the same change.
- **Never commit** vendor files, USB captures, signing material or a keyboard's serial number or GUID (`profile read --out` images contain the GUID).
- **Never put anything taken from the vendor's software into a tracked file** — code, comments, docs, tests or PRDs: no vendor file names, no verbatim vendor code. Provenance is stated in `README.md` and `docs/PROTOCOL.md`; describe behaviour in your own words. `make check` refuses unexpected file types and armoured key blocks, and reads an optional private deny-list (`CHECK_DENYLIST`) that is not part of the repository.
- **Known rough edges** are listed in `docs/KNOWN-ISSUES.md`. Delete an entry when you fix it.
- GitHub Actions are pinned to full commit SHAs; `make check` enforces it.
