# PRD-22: Audio-Reactive Lighting

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-08 (effect pipeline); shares the capture-permission story with PRD-21
- **Firmware basis:** **host-side only** — renders frames through `direct_write`
  (`0x40`) at 30 fps.

## 1. Summary
Turn the 86 LEDs into a music visualiser: capture system audio, run a short FFT,
and map frequency bands across the keyboard so bass sits under one hand and treble
under the other. This is the second half of the "the keyboard reacts to what the
computer is doing" story that PRD-21 starts with the screen.

## 2. Background & GG parity
GG lists an "audio visualizer" for some devices, tied to its Sonar audio software.
As far as we know Sonar is not available on macOS, so that route is not open to
users of this keyboard. On macOS the historical blocker was that capturing system
output required installing a virtual audio driver (Soundflower, BlackHole), which
is an unacceptable ask for a keyboard utility. That changed: ScreenCaptureKit can
capture system audio without any driver, which makes this feature reasonable to
ship for the first time.

## 3. Technical basis (grounded)
- **Capture without a driver** (confidence: documented Apple API, macOS 13+).
  `SCStreamConfiguration.capturesAudio = true` with `excludesCurrentProcessAudio`
  delivers system audio buffers through the same `SCStream` used in PRD-21. This
  reuses the **Screen Recording** permission rather than adding a new one, and
  needs no virtual device.
- **Alternative** (confidence: documented, macOS 14.2+): Core Audio process taps
  (`CATapDescription` + `AudioHardwareCreateProcessTap` + an aggregate device)
  capture output per process. Lower level, finer control, but a separate
  permission story and more moving parts. Treat as a later refinement, not the
  first implementation.
- **What we must not do**: require BlackHole or any kernel/user-space audio
  driver install. If neither API path works on a user's system, the feature is
  simply unavailable — it does not get to degrade into "go install a driver".
- **Analysis** (confidence: standard DSP): 1024-sample window, Hann, `vDSP` real
  FFT from Accelerate, magnitudes bucketed into log-spaced bands (bass →
  treble). Accelerate is a system framework; no third-party dependency.
- **Rate**: audio arrives far faster than 30 fps; the analyser keeps a rolling
  spectrum and the lighting timer samples it, so the two clocks stay decoupled.

## 4. Goals / Non-goals
- **Goals:** system-audio visualiser with several mapping styles (spectrum across
  columns, VU-meter from the centre, bass pulse, per-zone bands); sensitivity and
  auto-gain; a beat-pulse mode; silence detection that fades to a resting colour;
  no driver install, ever.
- **Non-goals:** microphone input; per-application audio isolation in v1;
  recording or storing audio; music-service metadata (that is PRD-11's OLED
  now-playing); latency-critical DJ-grade sync.

## 5. User stories
- As a listener, my keyboard pulses with whatever is playing, with nothing to
  install.
- As someone with a loud mix and a quiet podcast, auto-gain keeps both looking
  right without me touching a slider.
- As a gamer, explosions light the keyboard even though the game knows nothing
  about my keyboard.
- As a night owl, the visualiser respects my brightness setting instead of
  blinding me.
- As a privacy-minded user, I am told that audio is analysed in memory and never
  recorded.

## 6. Functional requirements
- FR-1: Capture system output audio with no third-party driver; if the system
  refuses, show why and fall back to the previous effect.
- FR-2: Analysis: 1024-sample Hann window, real FFT, magnitudes in dB, mapped to
  N log-spaced bands (default N = 14, roughly one per key column).
- FR-3: **Auto-gain**: a slow-moving normaliser (attack ≈ 100 ms, release ≈ 2 s)
  so quiet and loud sources both use the full range; a manual override.
- FR-4: Mapping styles: *Spectrum* (bands → key columns, height as brightness),
  *VU* (level grows outward from the space bar), *Bass pulse* (whole board
  breathes on low-band energy), *Zones* (bass/mid/treble → left/middle/right).
- FR-5: **Beat detection** — energy flux above a running median triggers a pulse;
  a sensitivity control, and a "beats only" mode.
- FR-6: **Silence**: after 2 s below a floor, fade to the profile's base colour
  rather than sitting black, so the keyboard never looks dead.
- FR-7: Respect the master brightness and the "reduce flashing" setting shared
  with PRD-21.
- FR-8: Audio buffers are analysed in place and discarded; nothing is written to
  disk, logged, or transmitted.
- FR-9: Throttle to 10 fps on battery; stop when audio has been silent and the
  display is asleep.

## 7. UX / UI design
- A new "Audio" entry in the effect grid, with its controls in the effect card:
  mapping style, sensitivity/auto-gain, band count (advanced), beat sensitivity,
  silence colour.
- A small **spectrum strip** under the controls showing the live bands, so the
  user can tell whether capture is working before looking at the keyboard.
- Shares PRD-21's permission card; if the user already granted Screen Recording
  for ambient lighting, this feature needs no further prompt — and should say so.
- **Empty/failed state:** "No audio is playing" versus "Audio capture is
  unavailable on this system" are different messages and must not be conflated.

## 8. Technical design
- **ApexKit:** none.
- **App:**
  - `AudioSource` — owns the `SCStream` audio path, hands out a rolling
    `SpectrumSnapshot` (band magnitudes + level + beat flag) behind a lock.
  - `SpectrumAnalyser` — pure `[Float] → SpectrumSnapshot`, using `vDSP`;
    testable against synthetic sine sweeps.
  - `AudioRenderer` — pure `SpectrumSnapshot + layout + style → [UInt8: LEDColor]`.
  - Add `.audio` to `EffectKind`; the shared `LightingRender` reads the latest
    snapshot exactly as PRD-21 reads the latest frame grid, so both stay pure.
- **Data model:** `AudioConfig { style, bands, gain, autoGain, beatSensitivity,
  silenceColor }` inside `LightingConfig`.
- **Shared:** PRD-21 and this PRD should share one `SCStream` when both are
  active rather than opening two.

## 9. Edge cases & risks
- **Permission conflation** — Screen Recording granting audio capture surprises
  people; the copy must say "macOS bundles system-audio capture under Screen
  Recording" plainly rather than hiding it.
- **Feedback loop**: `excludesCurrentProcessAudio` must be set or our own sounds
  would drive the visualiser.
- **DSP on the wrong thread** — FFT must not run on the audio delivery thread's
  critical path nor on the main actor.
- **Photosensitivity** — a beat-pulse visualiser is the most strobe-prone thing
  in the app; the shared flashing cap applies, and beat mode should default to a
  gentler curve.
- **Silence ≠ failure**: a broken capture and a paused track look identical on the
  keyboard; the spectrum strip exists to disambiguate.
- **Sample-rate and channel-count changes** mid-stream (switching output device)
  must reconfigure the analyser rather than produce garbage.
- **API availability**: if a future macOS restricts audio under a separate TCC
  service, this feature must detect and degrade, not crash.

## 10. Acceptance criteria
- AC-1: With music playing, the spectrum strip moves and the keyboard responds
  within ~100 ms of a beat.
- AC-2: A 100 Hz sine lights only the low bands; a 10 kHz sine only the high
  bands.
- AC-3: Auto-gain brings a −40 dB source and a −6 dB source to comparable
  visual range within 3 s.
- AC-4: Pausing playback fades to the silence colour rather than to black.
- AC-5: No third-party audio driver is present and none is required.
- AC-6: The app's own alert sounds do not drive the visualiser.

## 11. Effort & milestones
**M.** M1: `SCStream` audio capture and a level meter. M2: `SpectrumAnalyser`
with vDSP + tests against synthetic tones. M3: mapping styles and the spectrum
strip. M4: auto-gain, beat detection, silence, throttling, safety caps.

## 12. Open questions
- Does `SCStream` audio capture work when *no* display content is being
  captured, or must we also run a (discarded) video stream to keep the session
  alive? This decides whether the feature can exist independently of PRD-21.
- Is the Core Audio process-tap route worth building later for per-app audio
  (visualise only the game, not Slack notifications)?
- What is the right default band count — one per key column (14) reads nicely but
  low bands are perceptually crowded; log spacing may want fewer.
- Should beat detection drive the *OLED* too (a VU meter), or does that belong in
  PRD-11?
