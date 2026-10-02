# Architecture

How Apex Control is put together, and the rules that keep it from hurting a real
keyboard. Read this before changing anything under `Sources/ApexKit/Protocol/`.

The protocol itself is documented in [PROTOCOL.md](PROTOCOL.md); this page is
about the code that speaks it.

## The three targets

Three SwiftPM targets, strictly layered. `ApexKit` has no UI, and the wire
protocol code in it (the packet builders and the transport) uses no UI framework,
so the command-line tool and the app are genuinely the same engine. The one part of
`ApexKit` that draws is `Protocol/OLEDGraphics.swift`, which turns text and images
into the OLED's 1-bit bitmap and imports CoreGraphics, CoreText and AppKit; it is
kept apart so that the packet builders stay dependency-free.

```
ApexKit ──┬── apexctl          (command-line front end)
          └── ApexControlApp   (SwiftUI app)
```

There are no third-party dependencies.

### ApexKit

| Path | What it is |
|---|---|
| `Transport/HIDTransport.swift` | `IOHIDManager` on a dedicated background thread with its own run loop, so input-report callbacks (query replies) arrive while a caller is blocked waiting for one. Three access patterns: `sendFeatureReport` / `sendOutputReport` (fire and forget), `queryFeature` (SET_REPORT then GET_REPORT, used for binding read-back) and `query` (Output report, then await an Input report, used for firmware, region and layout). A `queryGate` lock serialises round trips so two concurrent queries cannot eat each other's replies. |
| `Protocol/*` | Pure, testable packet builders. No I/O. Each file owns one command family and says in its doc comment where the layout came from and how sure we are of it. `OLEDGraphics.swift` is not a builder: it renders text and images into the OLED's bitmap. |
| `Model/Key.swift` | `ApexProTKLGen3` is the single source of hardware truth: the firmware's `deviceKeyIndexToHID` slot table and the three *different* key sets derived from it (see the invariants below). It also holds the physical layout used for rendering. |
| `Model/*` | Colours, HID usages, mac key codes, the configuration structs and the software profile format. `TapHealth` is the pure rule set that judges whether the key listener is really being fed. `ArgumentParsing` holds the strict rules `apexctl` applies to hex bytes, slots and numbers, so that they are unit-tested. |
| `Lighting/LightingEngine.swift` | Renders effects on the host and streams them at 30 fps from its own `DispatchQueue`. `LightingRender.render` is a pure function shared by the streamer and the on-screen preview, so they cannot drift apart. |
| `ApexDevice.swift` | The facade both front ends use. Everything above is reachable through it. |
| `Version.swift` | `ApexVersion.current`, the single source of truth for the version. |

### ApexControlApp

- **`AppEnvironment.shared`** owns the long-lived objects (controller, profile
  store, preferences, navigator) *outside* the SwiftUI scene graph. This is
  load-bearing: with "keep running when the window is closed" on, the app can be
  running with no window at all (a login launch, a closed window), and a
  `@StateObject` on a view would leave the keyboard dark until something
  appeared on screen. It is still the one ordinary app process, and you quit it
  from its menu-bar icon: there is no helper tool, daemon or launch agent (start
  at login registers the app itself as a login item).
- **`DeviceController`** is `@MainActor` and is the single source of truth for
  the UI. **USB writes never run on the main actor**, because a wedged control
  transfer must not freeze the UI. They run on `deviceQueue`, nearly always through
  `perform(_:_:)`; the [conventions](#conventions) list the exceptions.
  Slider-driven writes are coalesced through Combine `throttle` subjects (16 ms for
  lighting, 120 ms for bindings and actuation) because a binding write is about
  2 KB: one 644-byte report for each of the three layers.
- **`Navigator` and `Pane`**: pane selection lives outside the view tree, so the
  menu bar, the ⌘-shortcuts and the snapshot harness can all drive it.
  `Pane.storage` declares whether a pane's settings live on the Mac or in the
  keyboard; the UI states this on every pane rather than burying it.
- **`Design/`** is a real design system (`Card`, `SwitchRow`, `SegmentedRail`,
  `ScaleControl`, `Banner`, `TravelGauge`, `KeyCaptureButton` and more). Build
  panes from these, not from raw SwiftUI controls.
- **`Support/`** holds three development harnesses that are inert unless an
  environment variable is set. See [DEVELOPMENT.md](DEVELOPMENT.md#the-development-harnesses).

### apexctl

`Sources/apexctl/main.swift` is a thin command-line front end over `ApexDevice`.
See [USING-THE-CLI.md](USING-THE-CLI.md).

## How a setting reaches the keyboard

The most important fact about the hardware is that some settings are held by the
Mac and vanish when the app quits, and others are burned into the keyboard and
outlive it. The UI says which on every pane.

| Setting | Written with | Where it lives |
|---|---|---|
| Lighting | `0x40` direct frames, streamed at 30 fps | Keyboard RAM. The last frame stays after the app quits, until `0x41` hands lighting back or the keyboard loses power. |
| Key bindings, Fn key | `0x36`, `0x35`, `0x3C` | Keyboard RAM immediately; flash after the debounce below. |
| Actuation, rapid trigger | `0x38 61`, `0x38 62`, `0x38 65` | Keyboard RAM immediately; flash after the debounce. |
| Rapid tap | `0x38 66`, `0x38 67` | Keyboard RAM immediately; flash after the debounce. |
| OLED, live | `0x1F 81` | Volatile. |
| OLED, saved | `0x38 83` | Written by **Save to keyboard** on the OLED Screen pane. It stays after the app quits; whether it survives unplugging has not been recorded. |

After an edit settles, `DeviceController.persistToKeyboard` rewrites onboard
slot 0 in the keyboard's flash (a full read-modify-write, verified by read-back)
so the setting should survive unplugging. The app saves once more when it quits; that
last save is not read back, so that quitting is not held up. See the flash
invariant below. Slots are numbered 0 to 4 in the protocol, the CLI and the code;
the Profiles pane shows them as 1 to 5.

## Invariants that will bite you

Each of these cost a hardware debugging session to discover. They are also
documented at their definition sites; this is the index.

**Every mapping write is a complete frame for its layer.** `Mappings.writeChunks`
fills in *every* key the layer addresses, so the value written for keys the user
never touched decides their fate, and it differs per layer:

- *Normal layer blank* is the key mapped to its own usage (`51 <hid> 00 00 00`),
  not `function 0`. Reading a stock keyboard back returns exactly that
  self-mapping for all 91 keys. "Reset this key" must write the self-mapping.
- *Fn (meta) layer and second-actuation blank* is `unbound` (`function 0`). A
  self-mapping on the Fn layer would make every key fire itself.

**Never write the Fn layer without reading it first.** It ships with nine `0x62`
firmware-function entries (the SteelSeries key's brightness, media and OLED
shortcuts) whose payloads we know of no command to restore. A frame built without them
erases them. `Mappings.Layer.isSafeToWriteUnread` and
`DeviceController.writeBase(for:mine:)` enforce this in the app, and the CLI's
`bind` and `unbind` read the layer first and write nothing if the read fails.
`resetAllBindings()` deliberately leaves the Fn layer alone. The one deliberate
exception is **Clear the Fn layer too** on the Key Bindings pane
(`DeviceController.resetFnLayer`): it erases the layer on purpose, behind a
confirmation, after putting the layer as last read into the undo history, so ⌘Z can
bring it back while the app stays open.

**`function 0x62` is not "this is the Fn key".** The vendor's description of the
device calls it META, but it means "run firmware function *n*", selected by
`key_codes`. The key that *activates* the layer is chosen separately with
`0x35 <hid>`. Treat the function ids as opaque: read, keep, write back unchanged.

**Three different key sets, all addressed by HID usage code.** 86 LEDs, 91
rebindable keys, 68 analog (adjustable) switches. `0xFB` (play/pause by the OLED)
lights but cannot be rebound; the six media and OLED buttons neither light nor
rebind; the second-actuation layer only covers the 68 analog keys. Use
`ledHIDOrder`, `mappableHIDOrder` and `analogHIDOrder`, and never assume one
implies another.

**Binding read-back (`0xB6`) is intermittent on firmware 1.19.7.** The request is
always acknowledged but the payload only comes back some of the time.
`readMappings` retries; every caller must handle it throwing, and the app
degrades to "read-back unavailable" rather than failing. The request must carry
the list of HID codes you want: without a block list the device answers
`err = 1`.

**Every live config command writes keyboard RAM only. Flash is a separate act.**
`0x36` bindings, `0x38 61` actuation, rapid tap and the `0x35` Fn trigger all
survive quitting the app but **not unplugging the keyboard**. Verified on
hardware: after a `0x36` write the flash image is byte-for-byte unchanged, with
the profile-volatility command (`0x34`) at either value. At power-up the firmware reloads
the boot profile from flash. Persistence is the onboard-profile flash write
(`OnboardProfile` and `ApexDevice.writeOnboardProfile`):

- **Always read-modify-write.** The image carries macros, the GUID and the
  factory Fn shortcuts, none of which the app can rebuild from its own state.
- **Never write an image that failed validation.**
- **Verify by read-back.** The one deliberate exception for the profile is the
  best-effort save when the app quits (`flushPersistOnQuit`), which skips the
  read-back so that quitting is not held up. It waits at most 8 seconds for the write,
  and the next launch reads flash again anyway. (The OLED image save, `0x38 83`, is a
  separate single command that is not read back.)
- `DeviceController` auto-persists to slot 0 on a 3 s diff-gated debounce, flushes
  on quit, and pauses the lighting stream around the write, because flash
  operations stall the control pipe.
- The UI reports `persistState`. Never let it claim "saved in the keyboard" for a
  RAM-only write.

**Bindings and actuation outlive the app** (RAM while powered, flash across power
loss once persisted). That is why binding edits have an undo stack
(`DeviceController.undoStack`, bounded at 64) whose snapshots fold in what was
read off the device, and why connecting never pushes bindings unless the app
actually has some.

**The Fn trigger key is only readable from the flash image**
(offset 76). `bindings.metaToggleHID == nil` means "never
touched, leave the keyboard's own trigger alone"; an explicit "no Fn key" is
stored as `0`. Writing `35 00` on connect used to silently disable the factory
SteelSeries-key trigger.

**30 fps is the lighting ceiling.** Streaming full frames faster outpaces the LED
controller and tears. The lighting engine holds to it (a 33 ms timer), and
`apexctl rainbow [seconds] [fps]` limits the frame rate it is given to 1 to 30.
Direct-mode colours persist until `0x41` (`clearLighting`) hands
the board back. The app never forces onboard mode on quit, by design.

**`0x75` (write region) touches flash on every call** and is intentionally not
exposed in the UI.

**"Lights off" is a black `baseColor`, so it poisons the next effect you pick.**
`setLightingOff(true)` sets `kind = .staticColor, baseColor = .black`. Selecting a
colour-driven effect afterwards keeps the black and renders an entirely black
effect; on Reactive that is indistinguishable from the feature being broken.
Every effect button goes through `DeviceController.selectEffect(_:)`, which
restores a visible colour first. Do not set `lighting.kind` directly from a view.

## Reactive lighting and permissions

Reactive lighting is the one feature that needs a macOS permission, and the one
place the obvious implementation is wrong four ways. `KeyMonitor` is the
reference; do not simplify it back.

- **Two permissions, either sufficient.** Accessibility (`AXIsProcessTrusted`) or
  Input Monitoring (`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`). They live in
  different System Settings panes. The app asks for both, but `IOHIDRequestAccess`
  (Input Monitoring) is the call that reliably raises the system prompt.
- **Never report the permission as the feature's state.** A grant on record and a
  tap macOS actually honoured are different facts, and the gap between them is the
  whole of "I granted it and nothing happens". The UI reads
  `DeviceController.reactiveInput`, which comes from whether the tap was created.
- **Modifiers are `flagsChanged`, not `keyDown`.** A mask without it silently drops
  every shift, control, option and command press. Use
  `MacKeyCode.pressedUsage(forFlagsChanged:flags:)`: it reads the per-side
  `NX_DEVICE*` bits, because `CGEventFlags.maskShift` cannot tell right shift from
  left shift already held.
- **A tap can be switched off after creation** (`.tapDisabledBy*`, delivered
  whatever the mask says). Unhandled, the listener goes permanently deaf, and the
  old code parsed those events as key presses. Re-enable on the event and from a
  watchdog.
- **A created tap is not a hearing tap.** Without an honoured grant (never given,
  stale after an ad-hoc rebuild, or granted after launch) the window server still
  *creates* the listen-only tap and then withholds every other app's `keyDown`.
  Modifiers and the app's own keys keep arriving. The symptom is that shift and
  control ripple from anywhere and letters only while the app is frontmost.
  `TapHealth` (pure and unit-tested) convicts that state from evidence: the HID
  system's last-key-down clock moved and the tap heard nothing, twice. A `keyDown`
  targeted at another pid is the only proof of delivery, because own-app keys
  arrive even when starved. The listener reports it as `.degraded`; never collapse
  that back into "listening".
- **Input Monitoring only applies to processes started after the grant**, and TCC
  keys on the code signature, so an ad-hoc rebuild silently loses it while still
  showing as ticked. `Scripts/make-signing-identity.sh` fixes that properly.
- **Starting goes through `DeviceController.syncKeyMonitor()` only**, so
  launching straight into a saved reactive profile listens too. Pausing, handing
  lighting back and quitting also stop the listener directly.

## Conventions

- **Protocol builders are pure.** No I/O, no globals; they take values and return
  bytes, so they can be unit-tested without a keyboard. Each says where its layout
  came from and states its confidence: *confirmed on hardware*, *from descriptor*
  (taken from the vendor's description of the device, which this repository does
  not contain) or *needs RE* (not yet reverse-engineered). Several fields
  (the profile-volatility command's argument direction, macro id encoding, release modes 3
  and 4) are declared but unverified, and marked as such.
- **USB writes never run on the main actor.** In `DeviceController` they go through
  `perform(_:_:)` onto `deviceQueue`. Three writes take another route, on purpose:
  the 30 fps lighting stream runs on the lighting engine's own queue; the OLED clock
  is a timer on `deviceQueue`; and the save at quit (`flushPersistOnQuit`) hands its
  write to `deviceQueue` directly and waits for it (up to 8 seconds), so that it
  finishes before the process exits. `apexctl` is synchronous and has no UI to
  protect.
- **Config structs are forgiving on decode.** `LightingConfig`, `ActuationConfig`,
  `BindingsConfig`, `OLEDConfig` and `RapidTapConfig` all hand-write `init(from:)`
  with `decodeIfPresent` and defaults, so profiles from older and newer builds
  still load. Keep that when adding fields. `HIDMap` serialises HID-keyed maps as
  `{"0x2C": …}` so exported profiles stay hand-editable.
- **Colour carries meaning.** The interface is dark-only on purpose: every pane
  previews light the keyboard is about to emit, and a light surround would
  misrepresent it. Graphite is every surface, **signal orange (`Theme.signal`)
  marks something you set**, and **readout cyan (`Theme.readout`) is the keyboard
  talking back** (measured values, the OLED). Never use one for the other's job.
  Distances are instrument readouts in millimetres, set in `Typo.readout`.
- **Comments explain why.** Especially anything the hardware forced on the
  design. The code is deliberately hand-formatted; match the file you are in.
- **Code comments reference PRD numbers and requirement ids** (`PRD-01 FR-1`).
  Keep that thread when you implement a PRD.

### Rendering hot path

For the 30 fps keyboard preview, measured on release builds: rebuilding 90
accessibility elements per frame was about 25% CPU, by far the largest cost, and
`NSColor(swiftUIColor)` round-trips about 6%; shadows and gradients were noise.
Hence `KeyAccessibilityLayer: Equatable`, `CapFace` keeping colour as plain
`Double`s, `OLEDPixels: Equatable`, the preview running at 20 fps while the
hardware gets 30, and pausing on `\.controlActiveState == .inactive`. `Equatable`
on a `View` needs `nonisolated static func ==` under Swift 6. Do not undo these
without re-measuring.

### SwiftUI and macOS constraints when developing

- These limits show up where **Screen Recording** permission is missing and cannot be
  granted from a shell, as in some automation setups. There `screencapture` fails,
  and `NSView.cacheDisplay` and `CALayer.render(in:)` both return blank for SwiftUI. Only `ImageRenderer` over the view tree worked, hence
  `SnapshotHarness`, which needs no permission. On your own Mac you can grant Screen
  Recording to your terminal and take ordinary screenshots (⇧⌘5 works too).
- `ImageRenderer` draws **no `Text` at all** inside a `GeometryReader` subtree, and
  renders `List`, `ScrollView` and AppKit-backed controls (switches, text fields,
  pickers) as a yellow placeholder. Views swap those containers for plain stacks
  under the `\.isSnapshotting` environment key. The shipping path always uses the
  native containers: the harness bends to the app, never the reverse.
- Posting events from outside the app (`CGEvent.post`) needs the Accessibility
  permission for the process that posts them. What needs no permission at all is the
  app posting events **to itself**: `NSApp.postEvent(NSEvent.keyEvent(…))` walks the
  same `sendEvent` path a real press does. That is how `KeyCaptureSelfTest`
  exercises the recorder.

## Testing

`swift test` covers packet framing, key tables, config codecs, the onboard-profile
codec and the key-capture and reactive-input rules: everything that can be checked
without a keyboard. Anything involving the device itself is verified with
`apexctl` against real hardware; there is no device simulator yet
([PRD-31](prd/PRD-31-device-simulator-test-harness.md)). The one test target,
`ApexKitTests` (in `Tests/ApexKitTests/`), exercises ApexKit only and has no tests
for the app target, so keep logic out of views and controllers and put it where it
can be tested in pure form. Cases are XCTest methods named `testSomething`, which
is what `swift test --filter Suite/testSomething` selects.

## Where the rest is documented

- [PROTOCOL.md](PROTOCOL.md): the byte-level command reference the code follows.
- [FEATURE-GAP-ANALYSIS.md](FEATURE-GAP-ANALYSIS.md): what the keyboard can do
  compared with SteelSeries GG, and the index of every planned feature.
- [prd/](prd/): one PRD per feature. Each carries a **Status** line.
- [DEVELOPMENT.md](DEVELOPMENT.md): building, the hardware verification loop, and
  recipes for common changes.
