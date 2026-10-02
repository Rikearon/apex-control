# PRD-23: System & Notification Lighting

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-08 (layered lighting engine); overlaps PRD-10's indicator goals but from the *host* side
- **Firmware basis:** **host-side only** — composited into the normal
  `direct_write` (`0x40`) frame.

## 1. Summary
Make the keyboard tell you things. A Caps Lock key that is actually lit when Caps
Lock is on, a battery gauge along the function row, a timer burning down across
the number row, a build that turns the board red when it breaks. PRD-10 wants the
firmware's own indicator lighting, which is gated behind the onboard profile
format (PRD-05); this PRD delivers the same *user value* immediately, in
software, and adds classes of indicator the firmware's own indicator lighting does not cover.

## 2. Background & GG parity
As far as we know, GG's indicator lighting is limited to lock-key colour, stored in
the onboard profile (PRD-10), and it does not treat the keyboard as a general
status display. Some users improvise this with Hammerspoon scripts and third-party
RGB tools. The value is that a keyboard is *always in your peripheral vision*, which
makes it a better place for a build status or a meeting countdown than a menu-bar
icon you have to look for.

## 3. Technical basis (grounded)

What macOS will actually tell us, and what it will not:

| Signal | API | Confidence |
|---|---|---|
| Caps Lock state | `NSEvent.modifierFlags` / `CGEventSource.flagsState(.hidSystemState)` | documented, no permission |
| Battery %, charging, time remaining | `IOPSCopyPowerSourcesInfo` / `IOPSGetPowerSourceDescription` | documented, no permission |
| CPU / memory / network load | `host_statistics64`, `sysctl` | documented, no permission |
| Calendar events, meeting countdown | `EKEventStore` | documented, **Calendar permission** |
| Timers / pomodoro | ours | trivial |
| Arbitrary app state (CI, deploys, alerts) | our own push API (PRD-25) | ours |
| **Focus / Do Not Disturb** | **no public API** | not achievable — do not promise it |
| **Unread badge counts** | **no public API** | not achievable |
| **Mic / camera in use** | no supported public API on macOS | not achievable |

- **Compositing** (confidence: design): indicators must be a *layer over* the
  running effect, not a replacement — the rainbow keeps running and Caps Lock
  glows on top. This is the same compositor PRD-08 needs, which is why they share
  it.
- **Priority and expiry**: a transient alert (build failed) outranks a persistent
  gauge (battery) and expires; the layer stack needs both.

## 4. Goals / Non-goals
- **Goals:** a layer system with priority and TTL; built-in indicators for Caps
  Lock, battery, CPU/network, timers, and calendar; an alert style (flash N times
  then fade) and a gauge style (fill a key range); per-indicator key selection and
  colour; everything off by default.
- **Non-goals:** anything requiring an API macOS does not offer (see table);
  replacing the firmware's own lock-key lighting (PRD-10 still wants that for the
  no-software case); notification *content* (we show state, not text — the OLED is
  where text belongs, PRD-11).

## 5. User stories
- As someone who keeps hitting Caps Lock, the Caps key turns red when it is on.
- As a laptop user, the function row shows my battery and turns amber under 20 %.
- As a developer, my keyboard flashes red when CI breaks and green when it passes.
- As someone in back-to-back meetings, the number row counts down to my next one.
- As a user who wants none of this, it is all off until I turn it on.

## 6. Functional requirements
- FR-1: Indicators render into named **layers** with an integer priority and an
  optional TTL; the compositor draws base effect → layers in priority order.
- FR-2: Each indicator declares a **key set** (chosen from the layout, with
  sensible defaults) and a **style**: solid, gauge (fill k of n keys), pulse, or
  flash-then-expire.
- FR-3: **Caps Lock**: default on the Caps key, default colour red, updates within
  100 ms of the state changing.
- FR-4: **Battery**: gauge across F1–F12 by default; colour thresholds at 20 %
  and 10 %; a distinct style while charging; hidden on desktops with no battery.
- FR-5: **Load**: CPU and/or network throughput as a gauge, with a configurable
  scale and smoothing.
- FR-6: **Timers**: a countdown that drains a key range, with an end-of-timer
  alert; startable from the menu bar and from the automation interface (PRD-25).
- FR-7: **Calendar**: minutes-to-next-event gauge, only after explicit Calendar
  permission; nothing about the event's *content* is displayed.
- FR-8: **External alerts** via PRD-25: `apexctl alert --color red --flash 3`
  and the equivalent IPC call, with a TTL so a crashed script cannot leave the
  keyboard stuck.
- FR-9: An indicator whose data source fails (permission revoked, source gone)
  removes its layer rather than freezing the last value.
- FR-10: A global "indicators off" switch, and automatic suppression while a
  fullscreen app is frontmost (configurable) so games are not disturbed.

## 7. UX / UI design
- A new **Indicators** pane listing available indicators with a toggle, a colour
  well, a key-range picker (click keys on the shared keyboard view), and a live
  preview on that same view.
- Unavailable indicators are listed but disabled with the reason inline ("macOS
  does not expose Focus state to apps") — better than pretending they do not
  exist, because users will ask.
- Priority is expressed as drag-to-reorder, not a numeric field.
- **Empty state:** all indicators off, with the three most useful (Caps, battery,
  timer) surfaced as one-click enables.

## 8. Technical design
- **ApexKit:** none. Indicators are host state.
- **App:**
  - `IndicatorLayer { id, priority, expiry, render(keys) -> [UInt8: LEDColor?] }`
    where `nil` means transparent.
  - `LightingCompositor` — base effect frame + sorted layers → final frame. Pure,
    testable, and shared with PRD-08.
  - `IndicatorSource` protocol with concrete `CapsLockSource`, `BatterySource`,
    `LoadSource`, `TimerSource`, `CalendarSource`, `ExternalAlertSource`; each
    publishes a layer and declares its own availability.
  - Sources poll at their own natural rate (battery 30 s, load 1 s, Caps event
    driven) — never at frame rate.
- **Data model:** `IndicatorConfig` list inside `SoftwareProfile`, so a "work"
  profile can show the calendar and a "game" profile can show nothing.

## 9. Edge cases & risks
- **Overpromising.** The table in §3 exists so the UI never advertises Focus or
  unread counts; a feature list that quietly drops them later is worse than never
  listing them.
- **Layer starvation**: an always-on gauge over F1–F12 makes the wave effect look
  broken; the compositor needs an opacity control per layer, not just on/off.
- **Stuck alerts** from external callers — TTL is mandatory, with a hard cap.
- **Permission scope creep**: Calendar access for a *lighting* feature is a big
  ask; it must be requested only when that indicator is enabled, and the app must
  work fully without it.
- **Fullscreen games**: an unexpected flash during a match is a real annoyance;
  suppression should default to on.
- **Caps Lock polling**: `NSEvent` global monitors need no permission for
  modifier flags, but confirm this on a clean machine — if it silently requires
  Accessibility, the indicator must say so.

## 10. Acceptance criteria
- AC-1: Toggling Caps Lock changes the Caps key colour within 100 ms, while a
  rainbow effect continues running underneath.
- AC-2: Unplugging power switches the battery gauge to discharging style; at
  < 20 % it turns amber.
- AC-3: `apexctl alert --color red --flash 3 --ttl 5` flashes and then clears
  itself even if the caller is killed mid-flash.
- AC-4: Denying Calendar permission disables only that indicator; everything else
  keeps working.
- AC-5: With suppression on, entering a fullscreen game removes all indicator
  layers and leaving it restores them.
- AC-6: Disabling every indicator produces a frame byte-identical to the base
  effect.

## 11. Effort & milestones
**M.** M1: compositor + layer model with tests. M2: Caps Lock and battery.
M3: load, timers, external alerts. M4: calendar, per-profile config, suppression.

## 12. Open questions
- Does reading modifier flags via a global `NSEvent` monitor work without
  Accessibility on a clean install? If not, Caps Lock indication costs a
  permission and should be reconsidered.
- Should indicators be per-profile (as designed) or global? Per-profile is more
  powerful but means "why did my battery gauge disappear" when switching.
- Is there a defensible way to surface *notification arrival* without content —
  e.g. a Notification Center database watch — or is that too fragile to ship?
- How do indicators interact with PRD-21 ambient lighting, where the whole board
  is already saturated with colour?
