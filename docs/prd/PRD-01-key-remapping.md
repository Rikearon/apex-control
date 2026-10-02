# PRD-01: Key Remapping & Bindings

- **Priority:** P0
- **Status:** Implemented — verified on hardware (write + read round-trip)
- **Depends on:** — (enables 02, 03, 04; consumes device read-back from 17)
- **Firmware basis:** the live per-layer binding write (cmd `0x36`) and the binding
  read-back (`0xB6`, to seed the current state); the block layout and the `function`
  values are from the vendor's description of the device (not included in this
  repository), with the write and read-back confirmed on hardware.

## 1. Summary
Apex Control can recolor and tune every key but cannot change what a key *does*.
This PRD adds live key remapping: bind any key to another key or modifier combo,
a media/consumer action, a mouse button / wheel / pan, "disabled", or a
host-assisted EXTERNAL action (launch app, insert text). Remaps are written live
via the `mappings` API (layer 0) and take effect immediately; the current bindings
are read back with the `0xB6` request to seed the editor. This is the
foundation that the Fn layer (PRD-02), dual-bind (PRD-03), and macros (PRD-04) all
build on.

## 2. Background & GG parity
As far as we know, SteelSeries GG's "Key Bindings" lets a user click any key and reassign it to a
keystroke, a modifier combo, a media/consumer control, a mouse action, a macro, an
app-launch/system shortcut, or disable it entirely — per profile. It is the most
basic "customizer" feature people expect from a configurable keyboard, and its
absence is why Apex Control today reads as a *lighting/actuation* tool rather than
a full configurator. Remapping is also a hard prerequisite: the Fn layer is just a
second binding layer, dual-bind is a third, and macros are bindings whose function
byte is `MACRO`. Nothing downstream ships without it.

## 3. Technical basis (grounded)
- **The mapping block** (confidence: from descriptor; confirmed on hardware): packed,
  **6 bytes**: the key's HID usage code, a function byte and four code bytes
  (`key_codes[4]`). Keys are addressed by HID usage code, so block order is irrelevant
  to which key is configured.
- **`function` values** (confidence: from descriptor; tabulated in
  `docs/PROTOCOL.md`): `0x00` unbound · `0x01–0x08` mouse buttons 1–8 · `0x31`/`0x32`
  wheel up/down · `0x33`/`0x34` pan left/right · `0x51` KEYBOARD · `0x61` CONSUMER ·
  `0x62` firmware function (named META in the descriptor; **not** the Fn trigger —
  PRD-02) · `0x30` CPI · `0x71` MACRO (PRD-04) · `0x72` EXTERNAL (host-assisted).
- **`key_codes[4]` payload** (confidence: mixed):
  - KEYBOARD (`0x51`): a key + combo (e.g. Ctrl/Shift/Alt/Gui). The field is 4
    bytes: on hardware it is a set of up to four HID usages sent together, with
    modifiers as ordinary usages rather than a bitmask (*confirmed on hardware*, see
    §12). UNBOUND is `function 0x00`; the firmware also has a "soft" unbound, a
    KEYBOARD entry with `key_codes = (0,0,0,0)`, which the highlight rule in PRD-02
    treats the same as unbound.
  - CONSUMER (`0x61`): a consumer-page usage as a little-endian `uint16` in
    `key_codes[0..1]`. Grounded examples, the ones the firmware itself uses on its
    media buttons: `205,0,0,0` = 0x00CD play/pause, `181` next, `182` prev, `226`
    mute, `233` vol-up, `234` vol-down (confirmed on hardware, see §12).
  - MOUSE_* / WHEEL / PAN / CPI: `function` alone selects the action; `key_codes`
    unused for the simple buttons (from descriptor).
  - EXTERNAL (`0x72`): `key_codes` hold a host-action id; the keyboard fires a
    **sentinel** and the *host* performs the action (see §9, PRD-14). Exact
    sentinel input-report format is *needs-RE*.
- **Live write — `mappings` API** (confidence: from descriptor; confirmed on
  hardware): each chunk is Feature `36 <layer> <count>
  [hid, fn, kc0, kc1, kc2, kc3] × count`. `layer` = `0x00` normal / `0x01` meta
  (PRD-02) / `0x02` second-actuation (PRD-03). Chunk capacity is
  `(report size − 5)/6 = (645 − 5)/6 = 106` keys, so all **91**
  mappable keys fit in **one** 644-byte feature report. The full sequence also
  carries macro chunks (`0x37`) and a trailing meta-highlight bitmask (Output
  `0x3C`, see PRD-02); a pure layer-0 remap needs only the `0x36 00 …` chunk —
  *confirmed on hardware: a layer-0-only write latches (see §12).*
- **Read-back — the `0xB6` request** (confidence: from descriptor): returns the 91
  layer-0 blocks `[hid, fn, kc×4]`. The same request reads layer 1 (Fn) and layer 2
  (second actuation, 68 analog keys). Used to seed the editor so the UI reflects
  reality even after another tool or an onboard profile set the bindings.
- **Persistence note:** live remaps persist for the session but are overwritten by
  the onboard profile on power-up; durable remaps flow through PRD-05.

## 4. Goals / Non-goals
- **Goals:** click-to-bind any key to → another key, → a modifier combo, → a
  media/consumer action, → a mouse button / wheel / pan, → disabled; seed the UI
  from the `0xB6` read-back; write live via the layer-0 binding write; expose the
  EXTERNAL host-assisted actions (launch app, insert text) behind a host listener;
  per-binding reset-to-default.
- **Non-goals:** the Fn/meta secondary layer (PRD-02); dual-bind / second-actuation
  bindings (PRD-03); macro recording (PRD-04); persisting bindings to an onboard
  slot (PRD-05); full device-state sync UI (PRD-17). CPI has no meaning on a
  keyboard and is exposed read-only for completeness only.

## 5. User stories
- As a gamer, I remap Caps Lock to Left Ctrl so I stop hitting the wrong key.
- As a creator, I bind the SteelSeries key to Play/Pause and F13→Mute so my
  media keys work without a numpad.
- As a power user, I set a key to Cmd+Shift+4 so one press starts a screenshot.
- As someone with a broken switch, I disable a key so stray presses stop.
- As a streamer, I bind a key to EXTERNAL "launch OBS" so one tap opens my app.
- As a tinkerer, I read the current bindings off the keyboard so the app shows
  exactly what GG last wrote.

## 6. Functional requirements
- FR-1: Enumerate all 91 mappable keys (`ApexProTKLGen3.keys`) and, on connect,
  seed each key's current binding from the `0xB6` read-back.
- FR-2: Bind a key to **KEYBOARD** — a target HID usage plus an optional modifier
  set (Ctrl/Shift/Alt/Gui, left/right), written as `function 0x51` + `key_codes`.
- FR-3: Bind a key to **CONSUMER** from a curated media list (play/pause, next,
  prev, stop, mute, vol±, and the common transport/consumer usages), written as
  `function 0x61` + the LE consumer code.
- FR-4: Bind a key to **MOUSE** — buttons 1–8 (`0x01–0x08`), wheel up/down
  (`0x31/0x32`), pan left/right (`0x33/0x34`).
- FR-5: **Disable** a key (`function 0x00`).
- FR-6: Bind a key to **EXTERNAL** (`0x72`) with a host action = {launch app by
  path, insert text/snippet}; the host listener performs it on the sentinel.
- FR-7: Write the layer-0 chunk(s) via `mappings`; apply is idempotent (re-send a
  full frame of all 91 keys so unspecified keys are never left stale).
- FR-8: Per-key "Reset to default" restores the key's factory HID (its own usage),
  and a profile-wide "Reset all bindings".
- FR-9: A binding is **testable**: after write, the `0xB6` read-back returns the
  same `[hid, fn, kc×4]` for that key (dev-mode verification).

## 7. UX / UI design
- A new **Bindings** pane sitting beside Lighting/Actuation, hosting the shared
  live `KeyboardView`. Selecting a key opens an inspector (reusing the
  `selectedKey` pattern from `DeviceController`).
- The inspector is a **category picker** → detail: *Keyboard* (a key field that
  captures the next physical press + modifier toggles), *Media* (a menu of
  consumer actions), *Mouse* (button/wheel/pan menu), *Disable*, *Launch app…*
  (file picker), *Insert text…* (text field). A remapped key shows a badge on the
  `KeyboardView`; disabled keys render dimmed.
- **Empty state:** before device read-back completes, keys show "default"; a
  banner explains bindings are read live from the keyboard.
- **Error state:** if a write fails, revert the key's UI to the last confirmed
  binding and surface a non-blocking error (consistent with existing panes).

## 8. Technical design
- **ApexKit:**
  - New `Mappings` protocol builder (mirrors `Actuation`): `func layerWrite(layer:
    UInt8, bindings: [(hid: UInt8, fn: UInt8, keyCodes: [UInt8])]) -> [UInt8]`
    emitting `36 <layer> <count> …`; helpers `keyboard(usage:modifiers:)`,
    `consumer(code:)`, `mouse(...)`, `disabled`, `external(actionID:)` that produce
    the 6-byte mapping block.
  - `ApexDevice.writeMappings(_ frame:)` (Feature) and
    `readMappings(layer:) -> [UInt8: Binding]` parsing the `0xB6` reply.
  - Add a `Binding` value type = `{ function: UInt8, keyCodes: [UInt8] }` plus a
    `MouseAction`/`ConsumerAction`/`ModifierSet` enum surface.
- **App:**
  - `BindingsConfig: Codable` on `DeviceController` = `[UInt8: Binding]` for
    layer 0, `@Published` and applied on change (debounced like lighting).
  - A host **ExternalActionRunner** that listens on the `0xFFC1` notification
    interface (shared with PRD-14) for the EXTERNAL sentinel and runs the mapped
    action (NSWorkspace launch / paste).
  - `BindingsView` + a `KeyBindingInspector`.
- **Data model:** `Binding` and `HostAction { launchApp(url), insertText(String) }`
  persisted in the app profile; the wire encoding lives entirely in `Mappings`.

## 9. Edge cases & risks
- **Bricking your own escape hatch:** a user can remap or disable *every* key,
  including the key that opens the app's rescue path. Provide a "Reset all
  bindings" that is always reachable from the menu bar (PRD-15), and never let the
  app's own global shortcut depend on a remappable key.
- **Modifier-only combos vs. the meta trigger:** binding a key as a modifier must
  not collide with `function 0x62` META (that key becomes the Fn trigger, PRD-02);
  guard against assigning META here.
- **EXTERNAL needs a running host:** the action only fires while Apex Control (or
  its menu-bar agent) is listening; document that EXTERNAL bindings are inert on a
  machine with no software (unlike KEYBOARD/CONSUMER/MOUSE, which are firmware-side
  once written). Sentinel format is unproven → gate EXTERNAL behind a feature flag
  until captured.
- **Layer coupling:** the full `mappings` sequence bundles all layers + macros; if
  hardware rejects a layer-0-only write, we must send layers 1/2 as their current
  values too — hence FR-1's read-back seed is load-bearing. (Firmware 1.19.7
  accepts a layer-0-only write; see §12.)
- **Non-analog vs. analog:** all 91 keys are mappable (superset of the 68 analog
  keys); do not confuse the mapping set with the actuation set.

## 10. Acceptance criteria
- AC-1: Remapping Caps→Left-Ctrl, then pressing Caps, types Ctrl on any host with
  no software running (proves it is firmware-side, not host-emulated).
- AC-2: A CONSUMER bind to Play/Pause controls system media; a Mute bind mutes.
- AC-3: A disabled key produces no input.
- AC-4: The `0xB6` read-back after a write returns the exact `[hid, fn, kc×4]`
  for every changed key (round-trip).
- AC-5: A KEYBOARD combo (e.g. Cmd+Shift+4) fires the OS action.
- AC-6: "Reset all bindings" returns every key to its own HID and the keyboard
  types normally.

## 11. Effort & milestones
**M (L if EXTERNAL is in-scope).** M1: `Mappings` builder + the `0xB6` read-back
parse + round-trip harness (prove the `0x36` layer-0 write latches live). M2:
KEYBOARD/CONSUMER/MOUSE/disable + Bindings UI seeded from read-back. M3: EXTERNAL
host actions on the `0xFFC1` listener (may split into PRD-14). M4: reset paths and
full-frame idempotent apply.

## 12. Open questions

**Answered on hardware** (firmware 1.19.7 — see `docs/PROTOCOL.md` §Key bindings):

- *`key_codes[4]` layout for KEYBOARD combos.* There is **no modifier bitmask**.
  `key_codes` is a set of up to four HID usages sent together, and modifiers are
  ordinary usages (`E0`–`E7`); left/right are distinct. Verified by writing
  Caps Lock = `51 E0 04 00 00` and reading the same bytes back.
- *Does a layer-0-only write latch?* **Yes.** A single `36 00 …` chunk takes
  effect immediately; layers 1/2, the macro chunks, and the `0x3C` bitmask are
  not required.
- *What is the reset value?* Not `function 0`. The factory resting state is each
  key mapped to **its own usage** (`51 <hid> 00 00 00`) — this is what a stock
  keyboard reports. `function 0` is the correct blank for layers 1 and 2 only.
- *Consumer-usage coverage.* The six the firmware drives on its own media
  buttons (`205, 181, 182, 226, 233, 234`) are confirmed; the rest of the
  consumer page is offered but labelled unverified in the UI.

**Still open:**

- EXTERNAL sentinel: what input report does the keyboard emit, and how is the
  action id encoded in `key_codes`? (Moved to PRD-14 — needs the `0xFFC1`
  listener.)
- What do the nine firmware-function ids (`0x62` payloads) actually select, and
  can new ones be authored rather than only preserved?
- Which consumer usages beyond the six confirmed ones does the firmware honour
  rather than silently drop?
