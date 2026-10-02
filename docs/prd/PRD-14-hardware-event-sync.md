# PRD-14: Hardware Event Sync (0xFFC1 listener)

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** — (independent; complements PRD-10 brightness, PRD-06 profiles)
- **Firmware basis:** the **notification interface** — HID usage page `0xFFC1`,
  usage `0x0001`, **input-only**, 64-byte input reports (PROTOCOL.md, Transport).

## 1. Summary
The keyboard has hardware Fn shortcuts that change settings on the device itself —
brightness up/down, cycle onboard profile, switch actuation/OptiPoint mode. When the
user presses those, Apex Control's UI silently goes **out of sync** because the app
only ever opens the `0xFFC0` control interface. This PRD opens the keyboard's
**second HID interface (`0xFFC1`)**, listens for the input reports it emits on
on-device changes, and reflects them live in the app (brightness slider, active
profile, actuation mode) so the UI always matches the hardware.

## 2. Background & GG parity
As far as we know, GG keeps its UI in lock-step with the keyboard: press Fn+brightness on the board and
GG's slider moves; cycle the onboard profile with the SteelSeries key and GG
highlights the new slot. This is the invisible glue that makes a companion app feel
*correct* rather than stale. Without it, Apex Control shows one brightness while the
keyboard is at another, or points at profile 2 while the board is running profile 4 —
every on-device shortcut becomes a source of drift and user confusion. It is small in
surface area but high in "does this app actually know what my keyboard is doing."

## 3. Technical basis (grounded)
- **The interface.** PROTOCOL.md's Transport table lists a second endpoint on this
  device: usage page `0xFFC1`, usage `0x0001`, **input-only**, 64-byte reports.
  The app today matches only `0xFFC0` (control); this interface is untouched.
- **Event formats** (from a USB capture; to be re-checked on this keyboard): each notification is a
  64-byte input report whose first two bytes are `<type> <value>`:

  | Bytes | Meaning | Value range |
  |---|---|---|
  | `01 <level>` | Brightness changed on device | `level` 0–16 (17 steps) |
  | `02 <n>` | Active onboard profile changed | `n` 0–4 |
  | `04 <n>` | OptiPoint / actuation mode changed | `n` (mode index) |

  Remaining bytes are zero-padding. The keyboard emits these **only for on-device
  (Fn-shortcut) changes** — it does **not** echo changes the host makes over
  `0xFFC0`, so there is no feedback loop from our own writes.
- **Opening it.** Add a second IOHIDManager match (or a second matching dict on the
  existing manager) for VID `0x1038` / PID `0x1642` / usagePage `0xFFC1` /
  usage `0x0001`, `IOHIDManagerOpen`, then
  `IOHIDDeviceRegisterInputReportCallback` with a 64-byte buffer. Like `0xFFC0`,
  `0xFFC1` is a **vendor** usage, so macOS should let a user-space app open it with
  no kext/entitlement/root (same rationale as the control interface).
- **Confidence:** the interface descriptor is **confirmed** (already in
  PROTOCOL.md); the three event opcodes/ranges are **from capture** and must be
  **validated on hardware** — the set may be incomplete (only these three were
  observed), and the exact brightness→percent and mode-index mappings need a bench
  check against the on-screen values.

## 4. Goals / Non-goals
- **Goals:** open and read the `0xFFC1` interface; decode the brightness / profile /
  actuation-mode notifications; update the corresponding app state and UI live;
  never re-send those changes back to the device; degrade cleanly on unknown reports.
- **Non-goals:** *sending* anything on `0xFFC1` (it is input-only); reverse-engineering
  every possible notification type beyond the three captured (unknowns are logged,
  not acted on); polling `read_*` queries on `0xFFC0` for state (that is PRD-17's
  read-back job — this PRD is the *push* path).

## 5. User stories
- As a user, I tap Fn+brightness on the keyboard and watch Apex Control's brightness
  slider move to match — no refresh, no drift.
- As a user, I cycle onboard profiles with the SteelSeries key and the app highlights
  the profile the board actually switched to.
- As a user, I change actuation/OptiPoint mode on the board and the app's mode
  indicator follows.
- As a developer, I see a subtle "synced from keyboard" activity indicator so I know
  the update came from hardware, not from my click.

## 6. Functional requirements
- FR-1: On connect, open a `0xFFC1` / usage `0x0001` match for `1038:1642` and
  register a 64-byte input-report callback; tear down cleanly on disconnect.
- FR-2: Parse `01 <level>` → set brightness state from `level` (0–16), mapped to the
  app's brightness scale.
- FR-3: Parse `02 <n>` → set the active onboard profile to slot `n` (0–4).
- FR-4: Parse `04 <n>` → set the actuation/OptiPoint mode to index `n`.
- FR-5: Apply these updates to app state **without** issuing any `0xFFC0` write in
  response (no echo / no write-back loop).
- FR-6: Unknown report types or out-of-range values are logged and ignored, never
  crash or corrupt state.
- FR-7: Show a brief, non-intrusive activity indicator when a hardware sync is
  applied.
- FR-8: Tolerate reports of unexpected length gracefully (accept the 64-byte frame;
  ignore malformed).

## 7. UX / UI design
- No new pane. Existing controls become **live-updating sinks**:
  - Brightness slider (PRD-10) animates to the received level.
  - Active-profile selector (PRD-06) highlights the new slot.
  - Actuation/OptiPoint mode control moves to the new mode.
- A **subtle activity indicator** — e.g. a momentary pulse on the affected control or
  a small "↻ synced from keyboard" chip in the toolbar — so the change reads as
  device-originated, not a phantom UI move.
- Optional: a small log line in a diagnostics/debug view for observed notifications.

## 8. Technical design
- **ApexKit:** extend `HIDTransport` to hold a **second matcher** for
  `usagePage 0xFFC1, usage 0x0001` alongside the existing `0xFFC0` control matcher,
  with its own `IOHIDDeviceRegisterInputReportCallback`. Add a
  `NotificationDecoder` that turns a 64-byte report into a typed
  `HardwareEvent` enum. Surface events via an `AsyncStream<HardwareEvent>` (or a
  delegate/Combine publisher) on `ApexDevice`.
- **App:** a controller subscribes to the stream and updates the shared view models
  (`brightness`, `activeProfile`, `actuationMode`) on the main actor, setting a flag
  so the update path knows *not* to originate a device write. Drives the activity
  indicator.
- **Data model:** `enum HardwareEvent { case brightness(Int), case profile(Int),
  case actuationMode(Int), case unknown([UInt8]) }`; no persistence (transient
  sync events).

## 9. Edge cases & risks
- **Feedback loop:** the biggest risk is receiving a hardware event, updating a view
  model, and having the binding fire a device write that re-triggers UI churn. The
  device does not echo host changes, but the *app* must still mark hardware-sourced
  updates as "do not write back" (FR-5).
- **Interface coexistence:** the OS may also read `0xFFC1`. As a vendor usage it
  should open non-exclusively (like `0xFFC0`), but handle a failed/denied open
  gracefully — the feature is additive; the app must keep working without it.
- **Scale mismatch:** brightness is 0–16 on the wire but the app's slider may be
  0–100 % (PRD-10); pin the mapping and round consistently so a hardware step and a
  UI step agree.
- **Incomplete opcode set:** other notification types may exist; treat unknown
  types as `unknown` and log — never assume the three are exhaustive.
- **Hot-unplug / re-enumerate:** re-establish the `0xFFC1` callback on reconnect, in
  lockstep with the `0xFFC0` reconnection.
- **Validation gate:** the opcodes are from capture — verify on hardware before
  trusting the values to move real UI (a wrong mapping silently mis-syncs).

## 10. Acceptance criteria
- AC-1: Changing brightness on the keyboard moves the app's brightness slider to the
  matching level, with the activity indicator firing.
- AC-2: Cycling the onboard profile on the device updates the app's active-profile
  highlight to the correct slot 0–4.
- AC-3: Changing actuation/OptiPoint mode on the device updates the app's mode
  control.
- AC-4: A hardware-sourced update does **not** trigger any `0xFFC0` write (verified
  by capture / logging — no write-back).
- AC-5: Injecting an unknown report type leaves the app stable and logs it without
  altering state.

## 11. Effort & milestones
**S–M.** M1: open `0xFFC1` + dump raw reports to confirm the capture on our unit.
M2: decoder + `HardwareEvent` stream. M3: wire to brightness/profile/actuation view
models with loop-guard + activity indicator. M4: reconnect handling + unknown-event
logging.

## 12. Open questions
- Exact brightness mapping: are the 17 levels (0–16) linear to the app's brightness
  percent, or do they follow the same non-linear curve the firmware uses on-device?
- What are the actuation/OptiPoint **mode indices** (`04 <n>`) and their labels, and
  do they line up with PRD-03's actuation modes?
- Are there additional notification opcodes (e.g. lock keys, rapid-trigger toggle,
  connection/idle) beyond the three captured?
- Does macOS ever hand `0xFFC1` to a system consumer that would block our open, and
  if so, what is the fallback?
