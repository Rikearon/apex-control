# PRD-02: Meta / Fn Secondary Layer

- **Priority:** P1
- **Status:** Implemented — Fn layer editable; factory shortcuts preserved
- **Depends on:** 01 (reuses the `mappings` builder, editor, and read-back)
- **Firmware basis:** the Fn-trigger command (Output `0x35 <hid>`), `function 0x62`
  (named META in the descriptor), the binding write and read-back on **layer 1**,
  the Fn-bound-key bitmask (Output `0x3C`), and the onboard lighting block's Fn
  highlight settings.

## 1. Summary
The keyboard has a full **second binding layer** ("Fn layer"): while a chosen meta
key is held (or toggled), every key can do something different. This PRD lets the
user pick the Fn key and author a complete second layer of bindings, with an
optional highlight of which keys carry an Fn binding. It is a thin, high-value
addition on top of PRD-01 — the same editor, pointed at mapping **layer 1**.

## 2. Background & GG parity
As far as we know, GG offers a secondary layer so one physical key (commonly a dedicated Fn
or the SteelSeries key) turns the whole board into a second set of bindings —
media on the number row, arrows on IJKL, macros, whatever the user wants. On a TKL
with no dedicated media/nav cluster this roughly *doubles* usable keys, and it is a
signature Apex Pro feature. Without it, Apex Control can only offer one binding per
key, so users can't recover the keys a TKL layout drops.

## 3. Technical basis (grounded)
- **Choosing the Fn key — two coupled facts** (confidence: from descriptor,
  command cross-listed in `docs/PROTOCOL.md`):
  1. The Fn-trigger command is Output **`35 <hid>`** — tells the firmware which
     physical HID code toggles/holds the meta layer.
  2. A key whose binding uses **`function 0x62` META** acts as the meta modifier.
     In practice the Fn key is set both ways: mapped as META in layer 0 and
     registered via the Fn-trigger command (`0x35`).
- **The layer-1 bindings** (confidence: from descriptor): identical wire format to
  PRD-01 but with `layer = 0x01` → Feature `36 01 <count>
  [hid, fn, kc0..3] × count` (91 keys, one chunk). Every
  `function` value from PRD-01 (KEYBOARD, CONSUMER, MOUSE, MACRO, …) is legal in
  layer 1. Read back with the `0xB6` request for layer 1.
- **Meta-key highlight bitmask** (confidence: from descriptor; the rule is
  implemented and unit-tested): a **32-byte** mask (256 bits, one per HID
  code) where a bound key sets `bit (1 << (hid & 7))` at byte `hid / 8`. A mapping
  counts as "bound" when `function != 0` and it is not a KEYBOARD entry with
  `key_codes = (0,0,0,0)`. The full `mappings` sequence ends with this mask as a
  trailing Output **`3C <32 bytes>`**. This tells the firmware *which* keys are
  Fn-bound so it can light them.
- **Highlight color/brightness is onboard-only** (confidence: from descriptor;
  nuance 2): the actual highlight appearance lives in the onboard lighting block (a
  brightness byte, an RGB colour, the 32-byte highlight mask and a background dimmer),
  with **no live command** on `0x1642`. So a *persistent*
  hardware highlight depends on PRD-05/PRD-10. In **direct lighting mode** (what
  Apex Control uses today) the app can simply paint the Fn-bound keys itself while
  the layer is engaged — no firmware highlight needed, and more flexible.
- **Live vs. onboard:** the Fn key + layer-1 bindings apply live via `mappings`
  and persist for the session; durable across power-loss requires PRD-05.

## 4. Goals / Non-goals
- **Goals:** pick the Fn/meta key (the Fn-trigger command + a META binding); author a
  complete layer-1 of bindings reusing the PRD-01 editor; a layer toggle (Normal ↔
  Fn) on the Bindings pane; seed layer 1 from the layer-1 read-back;
  optional host-rendered highlight of Fn-bound keys in direct mode; emit the
  `0x3C` bitmask alongside writes so the firmware's own highlight is correct.
- **Non-goals:** onboard persistence of the highlight color (PRD-05/PRD-10);
  more than one secondary layer (firmware exposes exactly one meta layer);
  per-application layer auto-switching (PRD-07); dual-bind second actuation
  (PRD-03, a different layer).

## 5. User stories
- As a TKL owner, I hold Fn and the number row becomes F13–F24 and media keys.
- As a gamer, I set the SteelSeries key as Fn and put arrow keys on WASD for
  menu navigation.
- As a user, I want the Fn-bound keys to glow while I hold Fn so I can see what's
  available.
- As a tinkerer, I read the current meta layer off the device so the editor shows
  what GG last stored.

## 6. Functional requirements
- FR-1: Select the Fn key from any of the 91 keys; on apply, send the Fn-trigger command
  `35 <hid>` **and** set that key's layer-0 binding to `function 0x62` META.
- FR-2: Author layer-1 bindings with the full PRD-01 category set; write via
  `mappings` `layer 0x01`.
- FR-3: A **Normal ↔ Fn** toggle in the Bindings pane switches which layer the
  editor edits and which the `KeyboardView` visualizes.
- FR-4: Seed layer 1 from the layer-1 read-back on connect.
- FR-5: Compute the 32-byte meta bitmask exactly per the rule in §3 (the one the
  firmware applies) and send it as Output `3C <32 bytes>` after a mappings write.
- FR-6: In direct lighting mode, optionally overlay a configurable highlight color
  on Fn-bound keys (host-rendered), toggleable in the pane.
- FR-7: "Clear Fn layer" unbinds all layer-1 keys and clears the meta key.

## 7. UX / UI design
- The Bindings pane (PRD-01) gains a segmented **Normal / Fn** control at the top.
  In Fn mode, the `KeyboardView` shows layer-1 bindings and the inspector edits
  layer 1; a persistent chip names the current Fn key ("Fn = SteelSeries key").
- A "Set Fn key" affordance: click the chip, then click a key (or capture a press).
- Fn-bound keys are visually marked in both modes (a small corner glyph); a
  "Highlight Fn keys while held" toggle enables the live direct-mode overlay.
- **Empty state:** no Fn key set → the Fn tab explains "Pick a key to hold for a
  second layer." **Error state:** mirrors PRD-01 (revert + non-blocking error).

## 8. Technical design
- **ApexKit:**
  - `ApexDevice.setMetaToggleKey(hid:)` → Output `35 <hid>` (reuses
    `sendOutputReport`).
  - Extend the `Mappings` builder with `metaMaskBitmap(from: [Binding]) -> [UInt8]`
    (32 bytes, the `hid/8` byte / `1<<(hid&7)` bit rule) and
    `ApexDevice.writeMetaMask(_:)` → Output `3C …`.
  - `readMappings(layer: 0x01)` already covered by PRD-01's read path.
- **App:**
  - `DeviceController` gains `metaKey: UInt8?` and `bindingsFn: BindingsConfig`
    (layer 1), plus an `editingLayer: Layer` UI state.
  - The direct-mode highlight is a compositing pass in `LightingEngine`: when the
    Fn overlay is on, OR the highlight color onto Fn-bound HIDs' frame.
- **Data model:** `metaKey` and the layer-1 `BindingsConfig` join the app profile;
  both are consumed by PRD-05 when serializing the profile image's Fn-layer bindings
  and Fn trigger key.

## 9. Edge cases & risks
- **Fn key with a normal binding:** the meta key is (usually) consumed by the layer
  toggle; decide and document whether tapping it alone still emits its layer-0
  binding, and whether META must also occupy its layer-0 slot.
- **Highlight persistence gap:** the *live* highlight is host-rendered and only
  visible while the app drives lighting; the *onboard* highlight (color/brightness)
  can't be set without PRD-05/PRD-10 — set expectations in the UI so users don't
  expect the glow to survive quitting the app.
- **Bitmask correctness:** an off-by-one in `hid/8` vs `hid&7` lights the wrong
  keys; unit-test against hand-computed masks for known bindings.
- **Single layer only:** don't imply multiple Fn layers; the firmware has exactly
  one.
- **Toggle vs. hold semantics:** confirm whether the Fn trigger yields
  momentary (hold) or latching (toggle) behavior on this firmware.

## 10. Acceptance criteria
- AC-1: With Fn set and layer 1 authored, holding Fn and pressing `1` emits the
  layer-1 binding; releasing Fn restores normal `1`.
- AC-2: The layer-1 read-back round-trips the authored layer-1 bindings.
- AC-3: The 32-byte mask sent via `0x3C` matches a reference computed from the
  same bindings (bit-exact).
- AC-4: The direct-mode overlay lights exactly the Fn-bound keys and nothing else.
- AC-5: "Clear Fn layer" removes the meta key and all layer-1 bindings; the board
  behaves as single-layer again.

## 11. Effort & milestones
**S–M** (leverages PRD-01). M1: the Fn-trigger command + layer-1 write/read + the
Normal/Fn toggle. M2: the 32-byte bitmask builder + `0x3C` emit, unit-tested. M3:
host-rendered Fn highlight in direct mode + polish.

## 12. Open questions
- Momentary vs. latching: does the Fn trigger hold-to-activate, or toggle?
- Does the Fn key need a layer-0 `META` binding *and* the Fn-trigger command, or is
  one sufficient?
- Does the firmware ever render the meta highlight in *direct* mode, or only from
  the onboard lighting block — i.e. is the `0x3C` mask purely advisory until
  PRD-05?
- Should the app forbid picking a non-analog / already-special key (e.g. an arrow)
  as the Fn trigger?
