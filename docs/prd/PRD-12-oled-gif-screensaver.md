# PRD-12: OLED Image, GIF & Screensaver

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** — (optional: **PRD-05** for the persist-across-power-loss route
  via onboard `oled_pixels`; shares OLED ownership with PRD-11)
- **Firmware basis:** `oled_direct_write` — live `1F 81` (confirmed); `oled_display`
  persist — `38 83` (confirmed); onboard `oled_pixels[640]` via PRD-05
  (the profile flash-write). **No new protocol** beyond what is already confirmed.

## 1. Summary
Apex Control can load a still image and fit it to the OLED, but with a single fixed
threshold and no motion. This PRD rounds out the *picture* side of the screen:
(a) **animated GIF** playback looped at ≤10 fps over the confirmed live path,
(b) **still images** with real dithering (threshold or Floyd–Steinberg) and fit
modes, (c) a **screensaver** that dims/blanks or shows a chosen image after host
idle to protect the panel and wakes on activity, and (d) a **persisted image** that
survives app quit and power loss via `38 83` or the onboard profile.

## 2. Background & GG parity
As far as we know, GG lets users set a custom OLED image, ships animated screens,
and has idle behaviour that protects the panel. OLED panels can retain / burn in
under a static image over long periods, so an idle screensaver/dimmer matters for
a screen that is lit whenever the keyboard is powered. Apex Control today does a
one-shot fit-and-threshold still image (`OLEDGraphics.image(contentsOf:)`) and
nothing else — no animation, no dither-quality options, no burn-in protection, and
images only persist if the user hits "Save to Keyboard." This PRD brings the image
experience to parity with that and adds panel care.

## 3. Technical basis (grounded)
- **Live animation path (confirmed).** Each GIF frame is a `MonoBitmap` pushed with
  `OLED.liveWrite` (`1F 81`, verified on `0x1642`). The firmware caps OLED
  animation at ~10 fps → clamp
  playback to **≤10 fps (≥100 ms/frame)** regardless of the GIF's native timing.
  *(Cap: from the descriptor, consistent with the 30 fps direct-write tearing note
  in `PROTOCOL.md`; the live write itself is confirmed.)*
- **Decode / dither (host-side, high confidence).** `CGImageSource` (ImageIO)
  enumerates GIF frames and per-frame delays; each frame is drawn into the existing
  grayscale CG context (see `OLEDGraphics.render`) and reduced to 1-bpp by either a
  fixed **threshold** (today's behavior) or **Floyd–Steinberg** error diffusion for
  photographic content. Fit modes: `fit` (current, aspect-preserving), `fill`/crop,
  `stretch`, `center`. All pure CoreGraphics — public API.
- **Persist path (confirmed).** A single still frame can be written to flash with
  `OLED.persist` (`38 83 00 [640]`) so it stays after the app quits; for survival
  across power loss with no host, the 640-byte frame goes into the onboard
  profile's `oled_pixels` via PRD-05. **Both write flash → one-shot only, never
  looped.**
- **Framebuffer.** 640 bytes, SSD1306 page-major (`PROTOCOL.md` §OLED);
  `MonoBitmap.columnPacked()` already produces it (verified).
- **Idle detection (high confidence).** Host input idle via
  `CGEventSourceSecondsSinceLastEventType(.combinedSessionState, .anyInputEventType)`
  or IOKit `HIDIdleTime`. This must be **host-driven** because the model's own
  idle-timeout command is empty on `0x1642` (see FEATURE-GAP §A.2).

## 4. Goals / Non-goals
- **Goals:**
  - Load an animated `.gif`, decode all frames, dither each to 128×40 1-bpp, and
    loop at ≤10 fps via live writes, with play/pause/stop/loop.
  - Still-image import with dither mode (threshold + adjustable level, or
    Floyd–Steinberg) and fit mode (fit/fill/stretch/center), with live preview.
  - A screensaver: after a configurable host-idle timeout, blank, dim
    (checkerboard/low-duty), or show a chosen image; wake on input.
  - A persisted-image option: write once to flash (`38 83`) or into the onboard
    profile (PRD-05) so it survives quit / power loss.
  - Enforce frame-count / size limits and pacing so animation is smooth and cheap.
- **Non-goals:**
  - Live data widgets / stats / media (**PRD-11**).
  - Game-event-driven screens (**PRD-13**).
  - Video files, or GIFs beyond a sane frame budget; arbitrary vector/scene
    animation.
  - True onboard *animation* — the firmware's onboard sequence engine byte format
    is out of scope (opaque, see FEATURE-GAP §A.4); onboard persistence is a single
    still frame only.

## 5. User stories
- As a user, I want to put a looping animated logo on my keyboard's screen.
- As a user with a photo, I want Floyd–Steinberg dithering so it reads better than
  a hard threshold on a 1-bit panel.
- As someone who leaves the PC on, I want the OLED to blank or dim when I'm away so
  it doesn't burn in.
- As a user, I want my chosen image to stay on the screen after I quit Apex Control
  or unplug the keyboard.
- As a laptop user, I want animation to stop when I'm away so it isn't wasting
  cycles.

## 6. Functional requirements
- FR-1: Import `.gif`; use `CGImageSource` to read frame count, per-frame delays,
  and pixels; reject files over a frame budget (default max 120 frames) or that
  decode past a memory cap, with a clear message.
- FR-2: Convert each frame to a `MonoBitmap` via the chosen fit + dither; cache the
  packed 640-byte frames (640 B × frames is tiny) rather than CGImages.
- FR-3: Play the sequence looped via live write at `min(gifDelay, cap)` clamped to
  ≥100 ms (≤10 fps); honor per-frame delays but never exceed the cap. Controls:
  play, pause, stop, loop on/off.
- FR-4: Still image — threshold mode with a level slider (reuse
  `OLEDGraphics.image(_:threshold:)`) and a Floyd–Steinberg mode; fit modes
  fit/fill/stretch/center; live preview via `OLEDPreview`.
- FR-5: Screensaver — user sets an idle timeout (default 5 min, range 1–60 min) and
  an idle action (Blank, Dim, Image). On idle → drive the action over live write;
  on first input → restore the previous OLED owner's content.
- FR-6: Persist — "Save image to keyboard" writes once via `persistOLED` (`38 83`);
  optional "Store in onboard profile" routes the 640-byte frame through PRD-05.
  Persisting is only ever a single explicit action — **never** on a loop or a
  timer.
- FR-7: Suspend animation/screensaver when the device disconnects or the display
  sleeps; resume on return.
- FR-8: Respect OLED single-owner arbitration (shared with PRD-11): starting a GIF
  or screensaver takes ownership; stopping restores the prior owner.

## 7. UX / UI design
- Extend the OLED pane with an **Image / GIF / Screensaver** section beside the
  existing Text controls in `OLEDView`.
- **Image / GIF card:** a drop target or "Load…", a dither picker (Threshold +
  level slider / Floyd–Steinberg), a fit-mode segmented control, and — for GIFs —
  a transport (play/pause/stop, loop toggle, frame count + effective-fps readout).
  Live `OLEDPreview` shows the current frame; the GIF preview animates in-app.
- **Screensaver card:** enable toggle, idle-timeout stepper, action picker (Blank /
  Dim / Image with an image chooser), and a "Preview screensaver now" button.
- **Persist controls:** "Show" (live) vs "Save to Keyboard" (flash, `38 83`) vs
  "Store in profile…" (PRD-05), with a note that Save writes flash and shouldn't be
  spammed.
- **Error/empty states:** an oversized/invalid GIF explains the frame/size limit; a
  disconnected device disables the transport with a hint.

## 8. Technical design
- **ApexKit:**
  - Extend `OLEDGraphics` with `image(_:fit:dither:)` where `dither` ∈
    `.threshold(UInt8)` / `.floydSteinberg` and `fit` ∈
    `.fit/.fill/.stretch/.center`. Floyd–Steinberg runs on the grayscale buffer
    already produced inside `render(...)`, before the 1-bpp reduction — pure
    CoreGraphics, no new dependency.
  - Add `GIFDecoder` (ImageIO / `CGImageSource`) returning
    `[(frame: MonoBitmap, delayMs: Int)]`; keep it in the CoreGraphics-gated file
    (`#if canImport(CoreGraphics)`).
  - No wire changes — reuse `OLED.liveWrite` / `OLED.persist`. The
    persist-in-profile route calls into PRD-05's `OnboardProfile` (set
    `oled_pixels`).
- **App:**
  - `OLEDPlayer` — owns a timed loop that pushes cached frames via
    `device.showOLED(_:)` at the clamped rate; play/pause/loop; participates in the
    `OLEDOwner` arbitration from PRD-11 (or introduces it if PRD-11 lands later).
  - `Screensaver` — an idle monitor (`CGEventSource` / HID idle time) that, on
    threshold, tells the OLED owner to show blank/dim/image and restores on wake.
  - Extend `OLEDView` with the Image/GIF/Screensaver cards; wire to
    `DeviceController` (add `sendGIF(url:)`, `startScreensaver(...)`).
- **Data model:**
  - `OLEDImageConfig: Codable { source: URL?, fit: FitMode, dither: DitherMode, persisted: Bool }`.
  - `ScreensaverConfig: Codable { enabled: Bool, idleMinutes: Int, action: ScreensaverAction }`.
  - GIF bytes are **not** stored in prefs (only a security-scoped bookmark to the
    source + decode options); a persisted still frame, if any, lives on the device
    / in the onboard profile.

## 9. Edge cases & risks
- **Flash wear (critical).** `38 83` and onboard writes hit flash; the
  still-persist and "store in profile" paths must be one-shot, explicit, debounced,
  and never wired to the animation loop or a slider (mirrors PRD-05 §9). *(Persist
  path confirmed; wear caution is standard flash hygiene.)*
- **Pacing / tearing.** Exceeding ~10 fps for the OLED (or ~30 fps for any direct
  write, per `PROTOCOL.md`) causes drops/tearing; hard-clamp and **drop** frames
  rather than queue them.
- **Big / slow GIFs.** Decode cost and memory for many frames; enforce the frame
  budget, decode off the main thread, and cache the packed 640-byte frames.
- **Burn-in.** The reason the screensaver exists; default it on. Dim mode should use
  a low-duty checkerboard (1-bpp has no true grayscale) rather than a solid fill.
- **Idle-detection accuracy.** `CGEventSource` idle covers global input;
  full-screen games using raw HID may still count as active — acceptable. Display
  sleep should also trigger the idle action.
- **Ownership races.** GIF vs screensaver vs PRD-11 apps vs manual text all target
  `1F 81`; single-owner arbitration must resolve cleanly and restore the prior
  frame on wake/stop.
- **Persisted vs live confusion.** A persisted image reappears on next power-up even
  with the app closed, which can surprise users; make the distinction obvious and
  keep the existing "Reset to firmware default" (`1F 82`) escape hatch.

## 10. Acceptance criteria
- AC-1: A loaded animated GIF loops smoothly on the keyboard at ≤10 fps; native
  delays faster than 100 ms are clamped, slower delays are honored.
- AC-2: A photo dithered with Floyd–Steinberg is visibly more legible than the same
  photo at a hard threshold, and fit modes crop/fit/stretch as selected (verified
  in preview and on hardware).
- AC-3: After the idle timeout with the PC untouched, the OLED blanks/dims/shows
  the chosen image; the first keypress or mouse move restores the prior content.
- AC-4: "Save to Keyboard" persists a still image that is still shown after quitting
  Apex Control and after a power cycle (via the onboard-profile route); it writes
  flash exactly once per invocation (no loop).
- AC-5: An oversized GIF (> frame budget) is rejected with a clear message and no
  partial playback.
- AC-6: Disconnecting the keyboard mid-playback stops writes cleanly and playback
  resumes on reconnect.

## 11. Effort & milestones
**M.**
- M1: `GIFDecoder` + `OLEDPlayer` live loop with clamp + transport; reuse the
  existing image path.
- M2: Dithering (`floydSteinberg`) + fit modes in `OLEDGraphics`; still-image UI.
- M3: Screensaver (idle monitor + actions) and OLED owner arbitration.
- M4: Persist-to-flash / store-in-onboard-profile (depends on PRD-05) + polish,
  limits, and error states.

## 12. Open questions
- Exact fps ceiling on `0x1642` — is 10 fps a hard cap or the point where tearing
  starts? Measure the smooth maximum on hardware.
- Does a persisted onboard OLED image survive a full power cycle via `38 83` alone,
  or only via the onboard-profile `oled_pixels` route (PRD-05)? Verify both.
- Dim mode on a 1-bpp panel: checkerboard duty vs any real hardware brightness path
  (none exposed live per `PROTOCOL.md`) — is checkerboard acceptable for burn-in
  relief?
- Should GIF playback keep running while the app is backgrounded / menu-bar-only
  (ties into PRD-15), or pause to save power?
- Frame-budget default (120?) and maximum source dimensions before downscale.
