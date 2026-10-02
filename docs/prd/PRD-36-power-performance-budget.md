# PRD-36: Power & Performance Budget

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (constrains PRD-21, PRD-22, PRD-24, PRD-27, PRD-28)
- **Firmware basis:** the 30 fps `direct_write` ceiling documented in
  `docs/PROTOCOL.md` (faster outpaces the LED controller and tears).

## 1. Summary
Apex Control's whole value proposition is that effects render on the host — which
means the app must run all the time, on a laptop, doing floating-point work and
USB I/O thirty times a second, forever. Nothing in the project currently measures
what that costs, and several planned features (screen capture, audio analysis,
scripted effects, a second keyboard) multiply it. This PRD sets a budget,
measures against it, and makes the app back off when nobody is looking.

## 2. Background & GG parity
Not a parity feature. Apex Control aims to be a light background app, but nothing
in the project measures what it costs to run, so it makes no claim about resource
use relative to GG or any other software until this PRD's measurements exist.
Meanwhile the design deliberately pushed work to the host: a 30 fps timer streams a
644-byte feature report continuously whenever an animated effect is selected, and
the new keyboard render draws a bloom layer and gradients in the UI.

For a desktop user none of this matters. For a laptop user on battery, a
background process waking the CPU 30 times a second and issuing USB control
transfers is a measurable fraction of idle drain, and it is happening while the
lid is open on a train with the keyboard unplugged — which is the specific case
worth fixing.

## 3. Technical basis (grounded)
- **The 30 fps floor is a hardware constraint, not a choice**: faster tears,
  slower looks worse. So the lever is *when* we run at 30 fps, not how fast.
- **Cheap wins available today** (confidence: from the current implementation):
  - The engine runs whenever an animated effect is selected, **including when the
    keyboard is disconnected** — the timer fires and every write throws
    `notConnected`.
  - Static effects already stop the timer, and the OLED clock runs at 1 Hz, which
    is right.
  - There is no throttling when the app has no visible window, when the display
    sleeps, or when on battery — PRD-15 added sleep/wake handling but not
    activity-based throttling.
- **Measurement** (documented tooling): `os_signpost` intervals around render and
  write, `powermetrics`, Xcode's Energy gauge, and `MXMetricPayload` — though the
  last is iOS-centric, so signposts plus `powermetrics` is the practical pair.
- **Where the cost will grow**: PRD-21 adds a display capture stream, PRD-22 an
  FFT per frame, PRD-24 a JavaScript call per frame, PRD-27 a second device
  doubling USB traffic, and PRD-28 puts all of it on a battery-powered keyboard.
  A budget set now is a design constraint; set later it is a rewrite.

## 4. Goals / Non-goals
- **Goals:** a stated budget (idle CPU, energy impact, memory, USB rate) with
  automated measurement; adaptive frame rate driven by what is actually
  observable; stop rendering entirely when the device is absent; battery-aware
  defaults; a per-effect cost readout; regression detection in CI.
- **Non-goals:** rendering below the quality bar to save power (the user chose
  the effect); optimising the SwiftUI preview at the expense of the hardware
  path; supporting a "low power mode" that silently changes what the keyboard
  looks like without saying so.

## 5. User stories
- As a laptop user, Apex Control does not show up in the battery-usage list.
- As a user with the keyboard unplugged, the app is doing nothing at all.
- As a user, closing the window does not stop my lighting but does stop the app
  redrawing a window nobody can see.
- As a user picking an effect, I can see which ones are expensive.
- As a maintainer, a change that doubles idle CPU fails CI.

## 6. Functional requirements
- FR-1: **Budget**, measured on Apple Silicon with one keyboard and an animated
  effect: < 2 % average CPU, "Low" energy impact, < 80 MB resident, and exactly
  one USB feature write per frame. Idle with a static effect: ~0 % CPU, no timer.
- FR-2: **Device absent → nothing runs.** The lighting timer, the OLED loop, and
  any capture stream stop on disconnect and resume on reconnect.
- FR-3: **Display asleep or screen locked → hardware rendering continues only if
  the user asked for it**; the on-screen preview stops unconditionally.
- FR-4: **No visible window → the SwiftUI preview does not render.** The
  `TimelineView` driving the on-screen keyboard must not animate for a window
  that is closed or fully occluded (`NSWindow.occlusionState`).
- FR-5: **On battery**, animated effects drop to a configurable rate (default
  15 fps) with a one-time explanation; a per-profile override exists. Effects
  whose appearance depends on frame rate must degrade gracefully, not stutter.
- FR-6: **Frame coalescing**: if a render takes longer than the frame interval,
  skip rather than queue, so the app can never build a backlog of USB writes.
- FR-7: **Cost readout**: each effect shows a measured cost badge (low/medium/
  high) derived from real timing on this machine, not a hard-coded guess.
- FR-8: **Signposts** around render, encode, and USB write, so a profile in
  Instruments attributes time correctly.
- FR-9: **CI regression check**: a headless benchmark over the pure renderers
  (which need no hardware) fails if per-frame render time regresses beyond a
  threshold.
- FR-10: Every future feature that adds per-frame work states its budget in its
  own PRD and is measured before it ships.

## 7. UX / UI design
- Mostly invisible. Three touchpoints:
  - **Effect tiles** gain a small cost indicator (a dot scale), explained on
    hover — this is honest information, not a warning.
  - **Settings → Power**: "Reduce frame rate on battery" with the rate, and a
    line reporting the app's current measured cost ("about 1.4 % CPU").
  - **A one-time note** the first time the app throttles on battery, so the
    change is never mysterious.
- The live cost figure in Settings is the most useful thing here: it turns an
  unverifiable claim into something the user can watch.

## 8. Technical design
- **ApexKit:**
  - `LightingEngine` gains a target frame rate, a "skip don't queue" scheduler,
    and a `stop()` on device loss; it already owns its timer, so this is
    contained.
  - `os_signpost` intervals in the engine and in `HIDTransport.send`.
  - A `FrameCostMeter` maintaining an EMA of render + write time, exposed for the
    UI badge and the Settings readout.
- **App:** an `ActivityMonitor` observing device presence, window occlusion,
  display sleep, and power source, producing a single `RenderPolicy`
  (`full | reduced | previewOnly | off`) that the engine and the preview both
  obey. One policy object avoids the classic bug where three features each
  implement their own throttling and fight.
- **Benchmarks:** an XCTest performance test over `LightingRender.render` and the
  frame encoders, run in CI.

## 9. Edge cases & risks
- **Throttling that surprises** is worse than the power cost: a user who set a
  smooth wave and sees it stutter on battery will file a bug. Hence the one-time
  explanation and the visible setting.
- **Occlusion detection is subtle** — a window behind another app is occluded,
  but a window on another Space may not report as such; getting this wrong stops
  the preview while the user is looking at it.
- **Skip-don't-queue changes effect timing**: effects driven by elapsed time
  (all of ours are) handle skips correctly; any future effect driven by frame
  *count* would drift. Worth stating in the effect contract (PRD-24).
- **Measuring on the developer's machine only** produces a budget that is wrong
  on Intel; the numbers need at least one Intel data point or an explicit
  "Apple Silicon" qualifier.
- **The cost badge could shame good effects** — it should be informative, with a
  neutral scale, not a red warning on the nicest effect in the app.
- **Two keyboards (PRD-27)** double USB traffic; the budget must be stated
  per-device and the policy applied per-device.

## 10. Acceptance criteria
- AC-1: With the keyboard unplugged and an animated effect selected, the app
  creates no timer and shows ~0 % CPU over a 60 s sample.
- AC-2: With the window closed and an animated effect running, the hardware keeps
  updating and the SwiftUI preview does no work (verified with signposts).
- AC-3: Measured against the FR-1 budget on Apple Silicon, an animated effect
  with one keyboard is within every limit; the numbers are recorded in the repo.
- AC-4: Unplugging power drops the frame rate to the configured value and shows
  the one-time explanation.
- AC-5: An artificially slowed render skips frames rather than accumulating a
  write backlog (asserted by a test with a stub transport).
- AC-6: A deliberate 2× slowdown in `LightingRender` fails the CI benchmark.

## 11. Effort & milestones
**S–M.** M1: stop everything when the device is absent; signposts. M2:
`ActivityMonitor` + `RenderPolicy` covering occlusion, display sleep, and power
source. M3: skip-don't-queue and the cost meter. M4: UI readouts and the battery
setting. M5: CI benchmark.

## 12. Open questions
- Is 15 fps on battery actually acceptable for a wave effect, or does it look bad
  enough that "pause entirely and tell the user" is the better default?
- Should the app stop driving lighting altogether when the screen is locked, or
  is a lit keyboard on a locked machine desirable?
- What is the honest idle cost on Intel, and does the README claim need
  qualifying?
- Does the OLED clock at 1 Hz justify keeping a timer alive at all, or should it
  align to the system clock's second boundary and use a lower-power scheduler?
