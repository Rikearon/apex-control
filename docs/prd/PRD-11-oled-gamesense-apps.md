# PRD-11: OLED GameSense Apps (system stats, media, notifications)

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (reused by PRD-13; shares OLED ownership with PRD-12)
- **Firmware basis:** `oled_direct_write` — live write `1F 81` (confirmed on
  hardware, `0x1642`). Everything else is host-side data collection; **no new
  protocol**.

## 1. Summary
Apex Control's OLED already shows static text, a loaded image, and a live clock
over the confirmed live-write path (`1F 81`). GG offers a library of live OLED
**"apps"** — small widgets that render system stats, now-playing media,
notifications, and hardware status at a glance and rotate through them. This PRD
adds a host-side **OLED app framework**: each app renders a 128×40 frame on its own
cadence, and a scheduler shows one at a time (carousel or priority), all pushed
over the existing volatile live write with zero flash wear.

## 2. Background & GG parity
As far as we know, GG's Engine exposes an OLED "screen" configurator where the user drops in widgets
— clock, CPU/GPU/RAM load, network throughput, now-playing track, Discord /
notification counts, and device status — and cycles them on the keyboard's screen.
People like the keyboard doubling as an ambient status display
without giving up monitor space. Apex Control today has exactly **one** hard-coded
widget (the clock, driven by `DeviceController.startOLEDLoop`) and no way to add
data-driven ones or rotate between them, so the OLED reads as a novelty rather
than a glanceable dashboard. Because the live path is confirmed and never touches
flash, this is high-value parity with essentially no hardware risk — one of the
cheapest wins in the backlog.

## 3. Technical basis (grounded)
- **Transport (confirmed).** Every app frame is pushed with the existing
  `OLED.liveWrite(_:)` → Feature report `1F 81 [640 bytes]`, verified on `0x1642`
  (see `PROTOCOL.md` §OLED). Frames are `MonoBitmap` (128×40) packed by
  `columnPacked()`. No new protocol, no flash writes, no wear.
- **Pacing.** The firmware caps OLED refresh at ~10 fps; the live path is
  otherwise cheap. The scheduler runs on a **≤10 fps budget** and, per app, pushes
  **only when the rendered frame changed** — `MonoBitmap` is `Equatable`, so a
  cheap compare against the last-sent frame suppresses redundant USB traffic.
- **Data sources (host-side, macOS)** — confidence noted per source:
  - **CPU load** — `host_statistics64(HOST_CPU_LOAD_INFO)` /
    `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` tick deltas. Public, stable.
    *(High confidence.)*
  - **Memory** — `host_statistics64(HOST_VM_INFO64)` (`vm_statistics64`) +
    `sysctlbyname("hw.memsize")`. Public, stable. *(High.)*
  - **Network throughput** — `getifaddrs` → `if_data` byte counters, delta over
    the sample interval. Public, stable. *(High.)*
  - **Battery / power** — `IOPSCopyPowerSourcesInfo` (relevant for laptops docked
    to the board). Public. *(High.)*
  - **GPU load** — **no public API.** Metal exposes memory but not utilization;
    the practical source is IOKit `IOAccelerator` / `IOReport`
    "PerformanceStatistics" → `Device Utilization %` via
    `IOServiceMatching("IOAccelerator")`. Works today but is undocumented →
    treat as best-effort behind a capability probe. *(Medium.)*
  - **Now-playing media** — the **private `MediaRemote.framework`**
    (`MRMediaRemoteGetNowPlayingInfo` → artist/title/artwork). Undocumented and
    known to change between macOS releases (notably restricted around macOS 15.4).
    Fallback: ScriptingBridge to Music/Spotify (per-app, needs Automation
    consent). → **must be optional and fail soft.** *(Low / fragile.)*
  - **Notification counts** — no clean public API for arbitrary apps; scope to a
    Dock-badge read (Accessibility) or a user-defined local webhook in a later
    iteration → **experimental.** *(Low.)*
  - **Date/time** — already implemented (the clock). *(Done.)*
  - **Custom text · profile / actuation status** — fully host-side from Apex
    Control's own state. *(High.)*
- **Reuse.** `MonoBitmap`, `OLED.liveWrite`, and `OLEDGraphics` (CoreText/CoreGraphics
  text + image) already exist and are unchanged by this PRD.

## 4. Goals / Non-goals
- **Goals:**
  - An `OLEDApp` framework: `render(context) -> MonoBitmap?`, a preferred
    `interval`, a `priority`, and an `isAvailable` capability flag.
  - A scheduler (`OLEDAppHost`) that shows one app at a time — **Carousel** (dwell
    N s each) or **Priority** (highest-priority app with fresh data wins) —
    pushing via live write at ≤10 fps, only on change.
  - A starter set: Clock (port existing), CPU, RAM, GPU (best-effort), Network,
    Battery, Now-Playing (fragile/optional), Custom Text, Profile/Actuation Status.
  - Reusable layout templates: `iconLabelValue`, `twoLine`, `bigNumber`,
    `barGauge`.
  - Per-app enable/disable, ordering, per-app dwell/priority; live in-app preview.
  - Graceful degradation when a data source or private API is unavailable.
- **Non-goals:**
  - Animated GIF / screensaver / still-image dithering (**PRD-12**).
  - Game-driven events (GameSense, **PRD-13**) — though this framework is exactly
    what PRD-13 renders into.
  - Persisting apps to the onboard profile (they are inherently live); a static
    fallback image is PRD-12 / PRD-05 territory.
  - A full drag-and-drop layout editor (v1 uses fixed templates).

## 5. User stories
- As a user, I want my keyboard to cycle CPU, RAM, and network load so I can watch
  system pressure without alt-tabbing.
- As a streamer, I want now-playing track info on the keys so I can see what's
  playing at a glance.
- As a gamer, I want the OLED to show my current actuation/profile so I always
  know which config is live.
- As a tinkerer, I want to enable only the apps I care about and set how long each
  is shown.
- As a user, I want a graceful "—" when GPU or media data isn't available instead
  of a crash or a frozen screen.

## 6. Functional requirements
- FR-1: Define `OLEDApp` with `id`, `displayName`,
  `render(_ ctx: OLEDRenderContext) -> MonoBitmap?` (nil = "no data — skip me"),
  `preferredInterval`, `priority`, and `isAvailable`.
- FR-2: `OLEDAppHost` scheduler with two modes — **Carousel** (each enabled +
  available app shown for its dwell, default 5 s, range 2–30 s) and **Priority**
  (show the highest-priority app currently returning non-nil).
- FR-3: The render/push loop runs at ≤10 fps (default one render per app per ~1 s
  for slow data, up to 10 fps for smooth content) and pushes to the device **only
  when the new `MonoBitmap` differs** from the last sent frame.
- FR-4: Ship apps: Clock, CPU %, RAM %/used, GPU % (best-effort), Net ↓/↑,
  Battery %, Now-Playing, Custom Text, Status. Each declares its availability.
- FR-5: Layout templates — `iconLabelValue(icon, label, value)`,
  `twoLine(top, bottom)`, `bigNumber(value, caption)`, `barGauge(label, fraction)`
  — each returning a `MonoBitmap` built via `OLEDGraphics`.
- FR-6: Persist the user's app list: enabled set, order, per-app options (dwell,
  priority, units), and scheduler mode. Codable, stored in app prefs.
- FR-7: When no app is enabled/available, either hand the screen back
  (`OLED.resetDirect`, `1F 82`) or show a configurable idle frame; never leave a
  stale frame from a now-disabled app.
- FR-8: Single-owner arbitration for the screen — pause the app host whenever
  another OLED consumer is active (manual text/clock in this pane, a PRD-12
  GIF/screensaver, or a PRD-13 game event) and resume cleanly afterward.
- FR-9: Every data source that uses a private/undocumented API is wrapped so a
  failure disables just that app (and logs once), never crashing the host.

## 7. UX / UI design
- Extend the OLED pane with an **"OLED Apps"** section (a sub-section/tab beside
  the existing Text/Image controls in `OLEDView`).
- A **reorderable list** of app rows: each row = icon, name, enable toggle, a
  compact live preview thumbnail, and a disclosure for per-app options (dwell
  seconds, priority, units such as MB/s vs Mb/s, which interface for Net).
- A header control for **scheduler mode** (Carousel / Priority) plus a global
  master toggle ("Run OLED apps").
- A large **live preview** mirroring exactly what's on the keyboard (reuse
  `OLEDPreview`), updating as the scheduler rotates.
- **Empty state:** explains apps and offers "Enable recommended (Clock, CPU, RAM,
  Net)".
- **Error/unavailable states inline:** the Now-Playing row shows "Requires media
  access — may be unavailable on this macOS version"; the GPU row shows a
  "Best-effort" badge if the IOReport probe failed.

## 8. Technical design
- **ApexKit:** stays protocol-only. The framework depends on macOS system
  frameworks, so it lives in the app (or a new `ApexOLEDApps` module). ApexKit
  already provides `MonoBitmap`, `OLED.liveWrite`, and `OLEDGraphics` — reuse as
  is. Optionally add the pure-CoreGraphics templates (`barGauge`, `bigNumber`) to
  `OLEDGraphics`, next to `text`/`image`, since they belong with the renderer.
- **App:**
  - `OLEDApp` protocol + `OLEDRenderContext` (timestamp, device caps, controller
    state).
  - Concrete apps: `ClockApp` (port from `OLEDView.startClock`), `CPUApp`,
    `RAMApp`, `GPUApp`, `NetApp`, `BatteryApp`, `NowPlayingApp`, `CustomTextApp`,
    `StatusApp`.
  - `SystemMetrics` — one shared sampler (timer) wrapping `host_statistics64` /
    `host_processor_info` (CPU, RAM), `getifaddrs` (net deltas), `IOPS*`
    (battery), and a guarded `GPUMetrics` (IOReport/IOAccelerator). Apps read
    cached values rather than each spinning a timer.
  - `NowPlaying` — dynamically `dlopen` MediaRemote (never link it) so a
    missing/broken framework fails at runtime cleanly; feature-flag + availability
    probe; ScriptingBridge fallback.
  - `OLEDAppHost` — an `ObservableObject`/actor owning the render+push loop, mode
    logic, and arbitration; integrates with `DeviceController` and pushes via the
    existing `device.showOLED(_:)`.
  - **Screen ownership:** introduce an `OLEDOwner` enum (`manual`, `apps`, `media`
    [PRD-12], `game` [PRD-13]) in `DeviceController` so exactly one writer drives
    `1F 81` at a time; the current manual Show/Clock become the `manual` owner.
- **Data model:** `OLEDAppsConfig: Codable { mode, master, apps: [OLEDAppSetting] }`
  and `OLEDAppSetting { id, enabled, order, dwellSeconds, priority, options }`,
  stored in the app's preferences and later foldable into a software profile
  (PRD-06).

## 9. Edge cases & risks
- **MediaRemote fragility (low confidence).** Private API, restricted around macOS
  15.4. Load dynamically, gate behind an availability probe, degrade to
  ScriptingBridge or "unavailable" — never a hard dependency — and flag clearly in
  the UI.
- **GPU utilization has no public API (medium).** IOReport/IOAccelerator "Device
  Utilization" works on Apple Silicon and many AMD/Intel GPUs but is undocumented;
  best-effort, show "—" if the probe fails.
- **Pacing / USB load.** Never exceed ~10 fps; push-on-change avoids spamming the
  bus; the single shared sampler prevents N timers hammering the system. No flash
  writes → zero wear (unlike PRD-12's persist path).
- **Screen contention.** Manual text, apps, GIF, and game events all want `1F 81`;
  the `OLEDOwner` arbitration must guarantee exactly one writer and a clean handoff
  (last owner resets, or the new owner takes over).
- **Sleep / wake / unplug.** On display sleep or device disconnect, suspend the
  loop; on wake/reconnect, re-arm and repaint. Never push to a gone device.
- **Privacy / permissions.** ScriptingBridge to Music/Spotify triggers macOS
  Automation consent; request lazily and only if the user enables Now-Playing.
- **Width.** 128 px is tiny; long titles/labels must ellipsize or marquee within
  the ≤10 fps budget.

## 10. Acceptance criteria
- AC-1: With Carousel mode and Clock+CPU+RAM+Net enabled, the keyboard visibly
  rotates through all four at their dwell times, each showing live-correct values.
- AC-2: CPU/RAM/Net values on the OLED match Activity Monitor within sampling
  tolerance.
- AC-3: Disabling an app removes it from rotation immediately with no stale frame;
  disabling all + master off hands the screen back (or shows the idle frame).
- AC-4: With MediaRemote unavailable (e.g. macOS ≥ 15.4 or framework missing), the
  Now-Playing app reports unavailable and is skipped; the app does not crash and
  other apps keep running.
- AC-5: A sustained run holds ≤10 fps and pushes only on frame change (verify via a
  debug counter); no flash writes occur (a subsequent onboard image is accepted
  unchanged).
- AC-6: Starting a manual OLED action (Show/Clock) or a PRD-12 GIF cleanly takes
  ownership and pauses the app host; stopping it returns ownership.

## 11. Effort & milestones
**M** for the framework + core apps, **L** including the fragile sources.
- M1: `OLEDApp` protocol + `OLEDAppHost` scheduler (carousel/priority,
  push-on-change) + port Clock; `OLEDOwner` arbitration.
- M2: `SystemMetrics` (CPU, RAM, Net, Battery) + templates (`iconLabelValue`,
  `barGauge`, `bigNumber`).
- M3: OLED Apps UI (list, toggles, ordering, per-app options, live preview) +
  config persistence.
- M4: Fragile sources — GPU (best-effort) and Now-Playing (dynamic MediaRemote)
  behind availability flags.

## 12. Open questions
- Priority-mode semantics: strict priority, or priority with a minimum dwell so a
  high-priority app can't monopolize the screen?
- Should app config live in app prefs only, or also serialize into software
  profiles (PRD-06) so different profiles show different OLED apps?
- Is a lower-risk path to GPU utilization worth pursuing (an `IOReport`
  subscription vs a one-shot `IOAccelerator` sample)?
- Now-Playing: ship dynamic MediaRemote at all given the macOS 15.4 restriction,
  or default to ScriptingBridge (Music/Spotify) and treat MediaRemote as an
  opportunistic bonus?
- Notification counts: is there an acceptable public source (Dock badge via
  Accessibility), or should this be deferred / kept experimental?
