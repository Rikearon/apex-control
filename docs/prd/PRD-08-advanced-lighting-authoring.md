# PRD-08: Advanced Lighting Authoring

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** — (host-side only; shares the render pipeline reused by PRD-09 and PRD-13)
- **Firmware basis:** host-side only — extends the existing software render streamed over
  `direct_write` (`0x40`) / `clear_direct_write` (`0x41`); **no new protocol**.

## 1. Summary
Lighting today is a single global effect (`EffectKind`) plus one flat per-key paint
layer, rendered on the host and streamed at 30 fps. This PRD turns that into an
authoring surface: multi-stop **gradients**, arbitrary key **zones** each running
their own effect, composable effect **layers** (base + reactive overlay), per-effect
**parameters** (direction, angle, speed, color set), a wider effect set (ripple/ring
on keypress, comet, per-key gradient sweep, image→keyboard, screen-color ambient,
audio visualizer), and a JSON **preset library** with import/export. All of it is
host-side compute over the LED map we already drive — it deepens one of the areas where
Apex Control already differs from GG (§E of the gap analysis).

## 2. Background & GG parity
As far as we know, GG's software lighting lets a user stack effects, select a region of the board, drag
gradient stops, set direction/speed per effect, and pick reactive/ripple and
audio-reactive modes. That authoring depth is what "RGB software" buyers expect. We
currently expose six built-in effects with a single base color and speed — good
motion, shallow authoring. Two honest framings:
- This is about **breadth of authoring**, not core quality: our engine already renders
  anything the Mac can compute (arbitrary per-key animation, reactive to any host
  event), rather than being limited to the firmware's onboard modes.
- Scoping is where host-side rendering can offer more: the firmware's onboard reactive
  effect always applies to the whole board and cannot be limited to a region (from
  descriptor). Host-side zones let us scope reactive/ripple to any key group.

## 3. Technical basis (grounded)
- **Render path is already in hand (confirmed, shipping).** `LightingRender.render(config:time:hits:)`
  is a pure function returning `[UInt8: LEDColor]`; `LightingEngine` streams it at
  33 ms/frame (30 fps — the keyboard's Prism sync rate; faster tears, verified on
  hardware, PROTOCOL.md). Frames go out as `direct_write` `0x40`
  (`DirectLighting.directWrite`, 644-byte Feature payload, ≤ 91 keys). Everything below
  is new math and UI over this same path.
- **Spatial data exists (confirmed).** `ApexProTKLGen3.keys` carries per-key `hid`,
  `x`, `y` with `layoutWidth` / `layoutHeight`. Gradients, angle sweeps, comets, ripples
  and zone geometry are pure functions of these coordinates — no device work.
- **Master brightness = RGB scaling (confirmed).** There is no LED-brightness command in
  this family (PROTOCOL.md); each frame is scaled by `LEDColor.scaled(by:)`. Gradients
  and layers compose in linear RGB before that scale.
- **Reactive input (confirmed, permission-gated).** `KeyMonitor` (a `CGEventTap`,
  `AXIsProcessTrusted`) feeds `LightingEngine.registerKeyPress(hid:)`. Ripple/comet-on-press
  reuse this. Without Accessibility permission these degrade to non-interactive.
- **Audio visualizer (high confidence, host API).** `AVAudioEngine` installs a tap on
  the selected input/aggregate device; FFT the buffer to a magnitude spectrum and map
  frequency bins → key columns (via `x`). No device dependency; needs microphone/aggregate
  permission for loopback capture.
- **Screen-color ambient (high confidence, host API).** Sample the display with
  `ScreenCaptureKit`, average edge regions → colors mapped onto the board. Needs Screen
  Recording permission.
- **Forward-looking design note (grounded, not a protocol claim).** Model the authoring
  primitives on the vocabulary of the firmware's own lighting-graphics engine —
  *foundation / reactive / idle* layers, per-key *zones*, animated gradients
  (direction / speed / scale / repetitions), opacity and brightness masks, and
  multi-stop gradients (from descriptor). Aligning our host model to these now keeps authored effects viable
  candidates for onboard baking later (PRD-09) without a model rewrite.
- **Unknowns:** none blocking — this is host compute. Hard limits are the 30 fps stream
  cap and 91-key addressing.

## 4. Goals / Non-goals
- **Goals:** a gradient editor (multi-stop, per-key and board-wide); a zone selector
  drawn on the live keyboard (arbitrary key groups, an effect per zone); an effect
  **layer stack** (compose base + overlays with blend + z-order); per-effect parameters
  (direction, angle, speed, scale, color set); an expanded effect set (ripple/ring on
  keypress, comet, wave variants, per-key gradient sweep, image→keyboard mapping, screen
  ambient, audio visualizer); a JSON preset library with import / export / share; a live
  preview identical to the on-screen keyboard.
- **Non-goals:** running any of this on the keyboard's own controller or persisting it
  with the app closed (PRD-09); any new wire protocol; onboard indicator / idle /
  brightness settings (PRD-10); game-driven lighting events (PRD-13, which reuses this
  engine).

## 5. User stories
- As a user, I drag a three-stop gradient across the board and set it to sweep left→right
  at my chosen speed.
- As a tinkerer, I select just WASD + the arrows as a zone and give it a reactive ripple
  while the rest of the board breathes.
- As an enthusiast, I stack a slow spectrum base under a white keypress-ripple overlay.
- As a streamer, I turn on the audio visualizer so the number row bounces with my music.
- As a user, I export my look as a `.json` preset and send it to a friend, who imports it
  unchanged.

## 6. Functional requirements
- FR-1: **Gradient editor** — 2–8 color stops with 0…1 positions; board-wide (mapped by
  `x`/`y`/angle) and per-key; live handles on a gradient bar.
- FR-2: **Zones** — select an arbitrary set of `hid`s on the live keyboard, name it, and
  assign one effect layer per zone; keys may belong to at most one zone (last write wins,
  clearly shown).
- FR-3: **Layer stack** — an ordered list of effect layers with a blend mode
  (normal / add / max) and z-order; a base layer plus ≥ 3 overlays; per-layer opacity.
- FR-4: **Per-effect parameters** — direction (H/V/radial), angle, speed (maps onto the
  existing `speed` 0…1), scale/wavelength, repetitions, and a color set; sensible defaults
  per effect.
- FR-5: **New effects** — ripple/ring on keypress, comet, wave variants, per-key gradient
  sweep, image→keyboard, screen ambient, audio visualizer.
- FR-6: **Preset library** — save/load named presets as JSON in Application Support;
  import/export via file picker; presets are forward-compatible (unknown fields ignored).
- FR-7: **Live preview** — the on-screen `KeyboardView` renders the exact frame being
  streamed (already shared via `LightingRender`).
- FR-8: **Performance ceiling** — never stream faster than 30 fps; full-frame `direct_write`
  every frame; composite in linear RGB, then apply master brightness once.
- FR-9: **Graceful degradation** — if Accessibility is denied, reactive/ripple render as
  static and prompt for permission; if Screen Recording / audio is denied, those effects
  are disabled with an inline explainer.

## 7. UX / UI design
- A **Lighting Authoring** surface replacing today's flat effect picker:
  - **Effect stack** panel (left): ordered layers, each with effect type, zone binding,
    blend, opacity, show/hide, reorder.
  - **Gradient editor**: a gradient bar with draggable stops and a color well per stop.
  - **Zone selector**: click/drag keys on the live `KeyboardView` to build a zone; zones
    are tinted; a chip list manages them.
  - **Parameters inspector** (right): direction/angle/speed/scale/color set for the
    selected layer.
  - **Preset browser**: grid of saved presets with import/export.
- **Empty state:** a single "Static" layer over the whole board.
- **Error states:** permission prompts for reactive (Accessibility), audio (microphone/
  aggregate), and ambient (Screen Recording); a "one zone per key" notice on overlap.

## 8. Technical design
- **ApexKit:** grow `LightingConfig` into a layered `LightingProject { layers: [EffectLayer],
  zones: [Zone], masterBrightness }`, where `EffectLayer { kind, params, zoneID?, blend,
  opacity }` and `Zone { name, hids: Set<UInt8> }`. `LightingRender` gains gradient
  sampling, zone compositing, and layer blending while staying a pure function; add
  `GradientStop`, `Gradient`, and an angle/position sampler over `keys`.
- **App:** new `AudioSpectrumSource` (`AVAudioEngine` tap → FFT), `ScreenAmbientSource`
  (`ScreenCaptureKit`), and `ImageMapper` (image → per-key colors) feeding the reactive
  `hits`/parameter inputs of the engine; `LightingAuthoringView`, `GradientEditor`,
  `ZoneSelector` in `Views/`; `DeviceController` continues to own a single `LightingEngine`
  and calls `engine.apply(project)`.
- **Data model:** `Codable` `LightingProject` / `EffectLayer` / `Gradient` / `GradientStop`
  / `Zone`; presets are JSON files under `Application Support/ApexControl/Presets/`, with a
  schema `version` for forward compatibility.

## 9. Edge cases & risks
- **Stream ceiling / tearing:** enforce the 33 ms cadence regardless of effect count;
  never let the authoring UI push frames faster.
- **USB throughput:** every frame is a full 644-byte Feature report; many-layer composites
  must still resolve to one frame — composite host-side, send once.
- **Permissions:** Accessibility (reactive), Screen Recording (ambient), and microphone/
  aggregate (audio) can each be denied; degrade the specific effect, never the whole engine.
- **Audio device churn:** input device can change/hot-unplug mid-effect; handle taps
  restarting cleanly.
- **CPU/battery:** FFT and screen capture run on the host; expose them as opt-in and pause
  when the window is hidden unless background mode (PRD-15) is on.
- **Brightness = 0** yields an all-black frame — keep the effect running so it restores
  when raised.
- **Per-key gradients** must stay within the 91 addressable keys; non-addressable keys are
  ignored.

## 10. Acceptance criteria
- AC-1: A board-wide 3-stop gradient renders identically in the live preview and on the
  keyboard, and sweeps in the chosen direction at the chosen speed.
- AC-2: A zone limited to WASD + arrows shows its own effect while the rest of the board
  runs a different one; no other keys are affected.
- AC-3: A base + overlay stack composites correctly (overlay visible over base) and respects
  per-layer opacity/blend.
- AC-4: The audio visualizer reacts to system/mic audio; the screen-ambient effect tracks
  on-screen color; both disable cleanly when their permission is absent.
- AC-5: Exporting a preset and re-importing it reproduces the look byte-for-byte (same JSON).
- AC-6: Frame rate never exceeds 30 fps and there is no visible tearing.

## 11. Effort & milestones
**L.** M1: layered render model + gradient sampling in `LightingRender`. M2: zone selector
and layer-stack UI. M3: new effects (ripple/comet/sweep/image). M4: audio + screen-ambient
sources. M5: preset library (JSON import/export/share).

## 12. Open questions
- Blend-mode set — is normal/add/max enough, or do we want screen/multiply too?
- Do per-key gradients need their own coordinate space, or is `x`/`y` + angle sufficient?
- Audio capture: require an aggregate/loopback device for system audio, or ship mic-only
  first?
- How closely should the host model mirror the firmware's foundation/reactive/idle
  split now, to maximise reuse when PRD-09's onboard baking lands?
