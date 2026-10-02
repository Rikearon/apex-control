# PRD-21: Ambient (Screen-Mirror) Lighting

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-08 (shares the effect/compositor pipeline); independent of firmware work
- **Firmware basis:** **host-side only** — renders frames and streams them through
  the existing `direct_write` (`0x40`) path at 30 fps.

## 1. Summary
The keyboard has 86 individually addressable LEDs sitting directly under the
display. This PRD makes them mirror what is on screen — the "ambilight" effect —
by sampling the display with ScreenCaptureKit, reducing it to a coarse grid, and
mapping that grid onto the physical key positions we already know.

## 2. Background & GG parity
As far as we know, GG does not offer screen-mirrored lighting: its lighting is
driven by preset effects and GameSense events, not by screen content. Ambient
lighting is a familiar feature of TVs and other RGB software, and it shows what a
host-rendered engine can do that firmware effects cannot. We already have the two
hard parts — accurate per-key physical coordinates and a verified 30 fps streaming
path — so the remaining work is capture and colour reduction.

## 3. Technical basis (grounded)
- **Capture** (confidence: documented Apple API, macOS 12.3+; we target 14).
  `SCShareableContent` to enumerate displays, `SCStream` with an
  `SCStreamConfiguration` whose `width`/`height` are set to a *tiny* target
  (e.g. 32 × 18) so the compositor does the downscale on the GPU and we never
  touch a full-resolution frame. `queueDepth` of 2–3, `minimumFrameInterval` of
  1/30 s to match the LED controller's clean rate (`docs/PROTOCOL.md`).
- **Permission** (confidence: documented, and a real product cost): screen
  capture requires the **Screen Recording** TCC permission, granted per app in
  System Settings, with a system prompt on first use. This is a heavier ask than
  anything else in the app and must be framed honestly.
- **Colour mapping** (confidence: straightforward): each key has `x`/`y` in key
  units and the layout is 18.5 × 6.25 units (`ApexProTKLGen3`), so a key maps to
  a normalised display rectangle. Sampling a downscaled frame at that point,
  with a small blur across neighbours, is the whole algorithm.
- **Performance**: a 32 × 18 BGRA frame is 2.3 KB; per-frame work is 86 lookups
  plus a saturation/gamma pass. The cost is dominated by capture, not by us.
- **Multi-display**: `SCShareableContent.displays` gives all of them; the user
  picks which one drives the keyboard.

## 4. Goals / Non-goals
- **Goals:** mirror a chosen display (or a region of it) onto the keys; a
  "follow the focused window" mode; saturation/brightness/smoothing controls; a
  letterbox-aware mode that ignores black bars; automatic pause when the source
  is not visible; graceful behaviour when permission is refused.
- **Non-goals:** capturing a specific *application* stream for game-specific
  effects (that is PRD-13 GameSense); audio (PRD-22); capturing to disk;
  anything that stores or transmits frame data.

## 5. User stories
- As a film watcher, the keyboard glows with the colours of what I am watching.
- As a gamer, my keyboard picks up the tone of the scene without the game needing
  to support anything.
- As a multi-monitor user, I choose which display drives the lighting.
- As a laptop user, it stops capturing when I am on battery or the display
  sleeps, so it costs me nothing.
- As a privacy-minded user, I am told exactly why Screen Recording is needed and
  that frames never leave memory.

## 6. Functional requirements
- FR-1: Source selection: a display, a display region (drag-selected), or the
  focused window; default is the display containing the app's window.
- FR-2: Sample grid resolution configurable (default 32 × 18); each LED takes a
  weighted average of the grid cells nearest its normalised position.
- FR-3: **Temporal smoothing** with an adjustable factor (default 0.35 EMA) so
  fast cuts do not strobe; a hard cap on per-frame change for photosensitivity.
- FR-4: **Saturation boost** (default 1.4×) and **gamma** so dim scenes still
  read as colour rather than mud; a black-floor control.
- FR-5: Letterbox detection — rows/columns that are near-black across the whole
  frame are excluded from the mapping.
- FR-6: Runs at 30 fps, and drops to 10 fps automatically on battery or when no
  window is on screen; stops entirely on display sleep.
- FR-7: Permission is requested only when the effect is first selected, never at
  launch, and the UI explains it before the system prompt appears.
- FR-8: If permission is denied or revoked, the effect falls back to the previous
  effect and shows a persistent, dismissible explainer.
- FR-9: Frames are never written to disk and never leave the process.

## 7. UX / UI design
- Appears as a new entry in the existing effect grid ("Ambient"), so it is
  discovered where every other effect is.
- Its controls appear in the effect card: source picker, smoothing, saturation,
  brightness floor, grid size (advanced disclosure).
- A **live preview**: the on-screen keyboard already renders the frame the device
  is receiving, so nothing extra is needed — but add a small thumbnail of the
  sampled grid so the mapping is legible.
- **Permission state:** a card that says what will be captured, that it stays in
  memory, and a Grant button; after denial, a link to the exact settings pane.
- **Photosensitivity:** a "reduce flashing" toggle, on by default when the system
  Reduce Motion setting is on.

## 8. Technical design
- **ApexKit:** none — it consumes the existing `setColors` frame API.
- **App:**
  - `AmbientSource` — wraps `SCStream`, owns the `SCStreamOutput` delegate,
    hands out the latest small frame as a `[SIMD3<Float>]` grid behind a lock.
  - `AmbientRenderer` — pure mapping from grid + key layout + settings → per-key
    colours; unit testable with synthetic grids.
  - Add `.ambient` to `EffectKind` and a branch in `LightingRender` that reads
    the latest grid (the renderer stays pure; the *source* is injected).
  - Lifecycle wiring into the existing sleep/wake and background paths (PRD-15).
- **Data model:** `AmbientConfig { source, grid, smoothing, saturation, floor,
  reduceFlashing }` inside `LightingConfig`, so it travels with a profile.

## 9. Edge cases & risks
- **Permission fatigue** — this is the first feature that needs a scary-sounding
  permission. Ask late, explain first, and never block other features on it.
- **Energy cost** on a laptop is real; the battery/idle throttles in FR-6 are
  not optional extras.
- **Photosensitive users**: uncapped scene cuts on 86 bright LEDs is a genuine
  safety issue, hence the change cap and the Reduce Motion default.
- **Content on screen is sensitive by definition.** Even though we never store
  frames, a bug that logged one would be serious; the frame path must never
  touch a logger, and tests should assert that.
- **DRM'd content** (some video) yields black frames from ScreenCaptureKit; the
  effect will simply go dark, which must be explained rather than look broken.
- **Display reconfiguration** (unplugging a monitor) must not leave a dangling
  stream; observe `NSApplication.didChangeScreenParametersNotification`.
- `LightingRender.render` is currently a pure function shared with the on-screen
  preview; injecting a live source must not break that purity or the preview and
  the hardware will drift apart.

## 10. Acceptance criteria
- AC-1: With the effect selected and permission granted, a full-screen red image
  turns the keyboard red; a left-half-blue image lights only the left keys blue.
- AC-2: Denying permission leaves the previous effect running and shows the
  explainer; no crash, no black keyboard.
- AC-3: On battery, the capture rate drops to 10 fps (observable in the
  diagnostics log, PRD-35).
- AC-4: With "reduce flashing" on, a hard cut between black and white takes at
  least 300 ms to complete on the LEDs.
- AC-5: Unplugging the selected display falls back to the primary display
  without a crash.
- AC-6: No frame data appears in any log at any log level.

## 11. Effort & milestones
**M.** M1: `SCStream` capture at a tiny resolution with permission handling.
M2: grid → key mapping and the pure renderer with tests. M3: controls, smoothing,
saturation, letterbox. M4: throttling, display-change handling, safety caps.

## 12. Open questions
- Is "follow the focused window" worth the extra complexity, or is display +
  region enough for the value it delivers?
- Should the sampled region default to the bottom third of the display (closest
  to where the keyboard physically sits) rather than the whole screen?
- Does `SCStream` at 32 × 18 actually cost less than capturing larger and
  downscaling ourselves? Needs measurement, not assumption.
- How should this interact with PRD-07 per-app profiles — should selecting a
  game profile be able to force ambient off?
