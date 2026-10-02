# PRD-03: Dual-Bind & Advanced Actuation

- **Priority:** P1
- **Status:** Implemented — second actuation thresholds, layer-2 bindings, release modes
- **Depends on:** 01 (the `mappings` layer-2 binding write + editor)
- **Firmware basis:** the second-actuation threshold command (Feature `38 61 44 02`,
  builder already in ApexKit), the binding write on **layer 2** (`36 02`) and its
  onboard counterpart (the second-actuation bindings block of the profile image), the
  release-mode command (`38 62`, modes `0x03/0x04`), and the protection and
  adaptive-distance fields (onboard).

## 1. Summary
An OmniPoint analog key can have a **second actuation point deeper in its travel
that fires a different binding** — a light press does one thing, a full press does
another (e.g. light `W`, full `Shift+W`). ApexKit already builds the second-point
*threshold* command (`setSecondActuation`) but nothing exposes it, and there is no
way to assign the second binding. This PRD surfaces dual-bind end-to-end, adds the
rapid-trigger **release modes** `0x03/0x04` (today only off/standard are used), and
exposes **protection mode** (anti-chatter). It extends the Actuation pane rather
than adding a new one.

## 2. Background & GG parity
As far as we know, GG's "Dual Actuation" / "two-stage" turns each analog key into two
inputs by travel depth — a headline OmniPoint selling point (e.g. walk on a light
press, sprint on a full press) — and it appears to offer rapid-trigger release
*variants* and an anti-chatter setting. Apex Control
already nails single-point actuation and standard rapid trigger, but the *advanced*
analog behavior — the reason people buy a Hall-effect board — is missing from the
UI even though the core threshold command is implemented.

## 3. Technical basis (grounded)
- **Second actuation point** (confidence: builder in ApexKit; command from
  descriptor + `docs/PROTOCOL.md`; second-layer *effect* needs on-hardware
  validation): Feature **`38 61 44 02 [hid, h, l] × 68`** — same layout as the
  primary threshold command but with layer `0x02` (68 = `0x44` analog keys). Already
  emitted by
  `Actuation.secondActuation` / `ApexDevice.setSecondActuation`; `(h,l)` come from
  the same verified level→threshold table. A sentinel `(255,255)` disables a key's
  second point.
- **The second binding** (confidence: from descriptor):
  - *Live:* **layer 2** — Feature `36 02 <count> [hid, fn, kc0..3] × 68` (analog keys
    only). Reuses PRD-01's mapping-block format and `function` values; read back with
    the `0xB6` request for layer 2.
  - *Onboard:* the same information is stored positionally in the profile image's
    second-actuation bindings block: a function byte and four code bytes per analog
    key (no HID code: the index is the key). This is the form PRD-05 serializes.
- **Rapid-trigger release modes** (confidence: from descriptor): the release-mode
  command = Feature **`38 62 44 [hid, mode] × 68`**, `mode ∈ {0x00, 0x02, 0x03,
  0x04}`. Today `ApexDevice.setRapidTriggerMode` only uses `0`=off / `2`=standard;
  the firmware accepts `0x03`/`0x04`, but what they do is unknown (the app labels
  them "Alternate mode 3/4"). Their behavioral meaning *needs on-hardware
  characterization*.
- **Protection / adaptive** (confidence: from descriptor; onboard-only): live only
  inside the profile image (schema 6/7/8): a protection duration (u32, ms), a per-key
  protection distance (70 bytes, 0.1 mm units), and a per-key adaptive distance
  (70 bytes). **No standalone live command for these is
  known on `0x1642`**, so protection/adaptive only take effect once
  written into an onboard slot — i.e. this part **depends on PRD-05**. Any live
  path is *needs-RE*.
- **Live vs. onboard split:** thresholds, the layer-2 binding, and release mode
  apply **live**; protection/adaptive persist **onboard** (PRD-05). Dual-bind
  *bindings* survive the session live but are durable only via PRD-05, exactly like
  PRD-01/02.

## 4. Goals / Non-goals
- **Goals:** per-key second actuation point (enable + depth) via the existing
  `secondActuation` command; assign the second binding via `mappings` layer 2;
  expose rapid-trigger release modes `0/2/3/4`; expose protection mode (duration +
  per-key distance) with a clear "requires Save to Keyboard (PRD-05)" note; seed
  from the layer-2 read-back.
- **Non-goals:** the normal-layer and Fn-layer bindings (PRD-01/02); macros
  (PRD-04); the onboard flash write itself (PRD-05); adaptive-actuation *tuning UX*
  beyond a basic on/off/distance (a later depth PRD if warranted).

## 5. User stories
- As an FPS player, I set W to walk on a light press and Shift+W (sprint) on a
  full press, from one key.
- As a producer, I bind a pad key to note-on light / velocity-accent deep.
- As a competitor, I switch rapid trigger to the instant release variant to see
  which feels sharper.
- As someone with a chattery switch, I enable protection so it stops double-firing
  (and I understand it takes effect after saving to the keyboard).
- As a tinkerer, I read the second-actuation bindings back to confirm them.

## 6. Functional requirements
- FR-1: Per analog key, toggle a **second actuation point** and set its depth
  (level 1–40 / 0.1–4.0 mm), constrained deeper than the primary point; write via
  the second-actuation threshold command (`38 61 44 02`); `(255,255)` disables.
- FR-2: Assign the **second binding** per analog key (full PRD-01 category set) and
  write it via the layer-2 binding write (`36 02 …`); seed from
  the layer-2 read-back.
- FR-3: Expose rapid-trigger **release mode** as {Off `0`, Standard `2`, Alternate
  `3`, Alternate `4`} per key (the alternates stay unlabelled pending §12), via the
  release-mode command.
- FR-4: Expose **protection mode**: a global protection duration and a per-key
  protection distance (0.1 mm units), stored for the onboard profile; UI clearly
  marks it as onboard-applied (PRD-05), not live.
- FR-5: Validate ordering: second point depth must be ≥ primary actuation depth;
  block or clamp otherwise.
- FR-6: A per-key "advanced" state is visible at a glance on the `KeyboardView`
  (badge for dual-bind, for non-default release mode, for protection).

## 7. UX / UI design
- Extend the **Actuation** pane: selecting an analog key reveals an *Advanced*
  disclosure with (a) a **second actuation** slider + its binding picker (reusing
  PRD-01's inspector), (b) a **release mode** segmented control, (c) a
  **protection** section (duration + distance) badged "Applies after Save to
  Keyboard."
- The primary and secondary actuation points render on a single travel track (two
  handles) so the depth relationship is visible; the deeper handle is the second
  point.
- Non-analog keys hide the Advanced section entirely (only 68 keys qualify).
- **Empty/error states:** default = no second point, release mode Standard,
  protection off; write failures revert the control (consistent with the pane).

## 8. Technical design
- **ApexKit:**
  - `Actuation.releaseMode` already accepts arbitrary modes — expose `3/4` through
    `ApexDevice.setRapidTriggerMode`; add an enum `ReleaseMode` for the surface.
  - Reuse `Actuation.secondActuation(perKeyLevel:)` (already emits `38 61 44 02`);
    add `ApexDevice.writeSecondActuationBindings(_:)` via the PRD-01 `Mappings`
    builder at `layer 0x02`, and `readSecondActuationBindings()`.
  - Add a `Protection { durationMs: UInt32, perKeyDist10: [UInt8: UInt8] }` and an
    `adaptiveDist10` field carried for PRD-05's profile-image serialization
    (no live builder — onboard only).
- **App:** extend `ActuationConfig` (already `Codable`) with
  `secondPoint: [UInt8: Int]`, `secondBinding: [UInt8: Binding]`,
  `releaseMode: [UInt8: ReleaseMode]`, and `protection`. `DeviceController`
  applies thresholds/binding/release live on change; protection is held for the
  profile blob.
- **Data model:** all of the above join the app profile and feed the profile
  image's actuation block in PRD-05.

## 9. Edge cases & risks
- **Protection is a promise the live path can't keep:** if we render a protection
  UI that does nothing until PRD-05 lands, users will call it broken. Either gate
  protection behind PRD-05 or badge it unmistakably as onboard-only.
- **Threshold ordering:** a second point shallower than the primary is nonsensical
  and may confuse the firmware; enforce `second ≥ primary` in the UI.
- **Analog-set mismatch:** second actuation and release mode address the **68**
  analog keys (`analogHIDOrder`), not all 91 — never offer these on mechanical
  keys.
- **Layer-2 availability:** the second-actuation layer exists on `0x1642` (from
  descriptor), but confirm the firmware latches a live layer-2 binding without an
  accompanying onboard write.
- **Release-mode semantics unknown:** shipping mislabeled 3/4 is worse than
  omitting them; characterize on hardware before final labels (§12).
- **Flash wear:** protection/adaptive only reach hardware through PRD-05's
  explicit, debounced flash write — never on a slider drag.

## 10. Acceptance criteria
- AC-1: A key with second point at 3.0 mm bound to Shift+W emits `W` on a light
  press and `Shift+W` past 3.0 mm, live.
- AC-2: The layer-2 read-back round-trips the second bindings.
- AC-3: Switching release mode 2→3→4 produces observably different rapid-trigger
  release behavior (documented per mode).
- AC-4: The UI blocks a second point shallower than the primary.
- AC-5: Protection settings serialize into an onboard profile (verified via
  PRD-05 read-back) and, once loaded, suppress a simulated double-fire.
- AC-6: Advanced controls never appear for non-analog keys.

## 11. Effort & milestones
**M.** M1: wire `setSecondActuation` + release modes 3/4 into the Actuation pane
(threshold half is done in ApexKit). M2: second-binding editor via `mappings`
layer 2 + read-back. M3: protection/adaptive model + UI, deferred-apply through
PRD-05. M4: dual-handle travel visualization + badges.

## 12. Open questions
- What do release modes `0x03` and `0x04` actually do (instant vs. continuous vs.
  something else), and what are the correct user-facing labels?
- Is there *any* live command for protection/adaptive on `0x1642`, or is PRD-05
  the only path?
- Does a live layer-2 binding latch on its own, or must the full `mappings`
  sequence (all layers + `0x3C`) accompany it?
- Units of the protection and adaptive distances — confirm 0.1 mm and the
  valid range against the actuation curve.
