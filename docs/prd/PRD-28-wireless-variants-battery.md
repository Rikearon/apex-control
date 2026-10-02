# PRD-28: Wireless Variants & Battery

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-27 (the model abstraction is a hard prerequisite)
- **Firmware basis:** none established yet. The wireless models' command set has to be
  worked out from a contributor's own captures and reads of their own keyboard and from
  public projects (see PRD-27), by a contributor who owns the wireless hardware.

## 1. Summary
The Gen 3 family includes wireless keyboards (`0x1644` / `0x1646`) and the wider
Apex line includes the Pro Mini Wireless, each of which speaks a related but
distinct command set and adds concepts this app has never modelled: a battery, a
sleep timer, and the fact that the device can simply be *gone* while still
"connected" over Bluetooth. This PRD extends the engine to those devices.

## 2. Background & GG parity
As far as we know, GG shows battery level, charging state, and low-battery warnings, and lets users
set sleep/dim timers to protect battery life — for a wireless keyboard these are
not extras, they are the difference between a usable tool and one that dies
mid-game. Apex Control has no concept of any of it: `DeviceController` assumes a
wired device that is either present or absent, and the lighting engine happily
streams 30 fps forever, which on a wireless keyboard is the fastest way to flatten
a battery.

## 3. Technical basis (grounded)
- **The wireless models are different products** (confidence: inferred from how the
  vendor's description of the devices is organised; not verified on hardware).
  The same physical keyboard appears to present **different USB identities depending
  on how it is connected** (cable, dongle, Bluetooth), each with its own endpoint set.
- **`docs/PROTOCOL.md` already warns** that `0x1644`/`0x1646` are believed to use
  different command sets despite the shared Gen 3 name — so this is not a parameter
  tweak of the wired protocol; its command set has to be worked out separately, from a
  contributor's own hardware.
- **Unknown** (needs RE): the battery-read command and its units, sleep/dim timeout
  commands, the dongle's pairing/link-quality reporting, and whether direct lighting
  is even permitted over Bluetooth (it may be dongle-only for bandwidth reasons).
- **Host side**: nothing new — the same `IOHIDManager` matching works for a
  dongle or a Bluetooth-attached HID device; only the matching criteria change.
- **The real design constraint** is power: a wireless keyboard cannot be driven
  the way we drive a wired one. Host-rendered 30 fps effects are a wired-only
  luxury, which makes **onboard effects (PRD-09)** and **onboard profiles
  (PRD-05)** disproportionately important for these models.

## 4. Goals / Non-goals
- **Goals:** establish and document the wireless command set (needs a contributor
  who owns the wireless model); support at least one wireless model end-to-end; battery level, charging state, and low-battery
  warning; sleep/dim timer configuration; connection-mode awareness (dongle vs
  Bluetooth vs cable); power-aware defaults that stop us flattening a battery.
- **Non-goals:** pairing management (that is firmware/OS territory); the wireless
  mice and headsets; making host-rendered effects a good idea on battery — the
  honest answer there is to recommend onboard effects.

## 5. User stories
- As a wireless keyboard owner, the app works with my keyboard at all.
- As a user, I can see my battery level and get told before it dies, not after.
- As a user, I set how long before the lighting dims and the keyboard sleeps.
- As a user on battery, animated effects do not silently halve my runtime — the
  app tells me the cost and offers a lighter option.
- As a user who plugs in the cable, everything switches to full capability
  without me reconfiguring anything.

## 6. Functional requirements
- FR-1: Recognise the wireless models in each of their connection identities and
  present them as **one logical keyboard** whose transport happens to change.
- FR-2: Read and display **battery percentage** and **charging state**, polled at
  a low rate (default 60 s) and on connect.
- FR-3: **Low-battery warning** at a configurable threshold (default 15 %), shown
  in the menu bar and optionally on the keyboard itself via an indicator layer
  (PRD-23) and the OLED where present.
- FR-4: Configure the firmware's **dim** and **sleep** timeouts, with the ranges
  the firmware allows.
- FR-5: **Power-aware effect policy**: when on battery, host-streamed animated
  effects are throttled by default and the UI states the trade-off; a per-profile
  override exists for users who do not care.
- FR-6: When the cable is connected, restore full behaviour automatically and
  say so.
- FR-7: If direct lighting turns out to be unsupported or impractical over
  Bluetooth, the lighting pane must present onboard alternatives rather than a
  broken control.
- FR-8: Every wireless-only control is hidden on wired models (PRD-27 capability
  flags).
- FR-9: A disconnected wireless keyboard (asleep, out of range) is shown as
  "asleep" rather than "not found", and settings changes are queued and applied
  on reconnect.

## 7. UX / UI design
- Battery appears in the sidebar footer next to the connection dot, and in the
  menu bar panel — the two places people already look for device state.
- A **Power** card (wireless only) with dim/sleep timeouts, the low-battery
  threshold, and the effect policy, each with a plain sentence about the
  battery cost.
- Connection mode shown as a small tag (Cable / Dongle / Bluetooth) because it
  changes what the app can do.
- **Asleep state:** the UI stays populated and editable, with a banner: "Your
  keyboard is asleep. Changes will apply when it wakes."

## 8. Technical design
- **ApexKit:**
  - New model descriptions per wireless variant (PRD-27's `DeviceModel`), plus a
    `LogicalDevice` concept that groups the identities of one physical keyboard.
  - `Power` protocol builders once the command set is established: battery read,
    dim and sleep timeout writes.
  - `capabilities` gains `battery`, `sleepTimers`, and a
    `preferredMaxFrameRate` so the engine can be told what the link can take.
- **App:** `DeviceController` gains a `power` section and a queue for changes
  made while asleep; the lighting engine reads `preferredMaxFrameRate` instead of
  the hard-coded 33 ms.
- **Data model:** `PowerConfig { dimAfter, sleepAfter, lowBatteryThreshold,
  throttleOnBattery }` in `SoftwareProfile`.

## 9. Edge cases & risks
- **No hardware to test on.** This PRD cannot be verified the way the wired work
  was, and shipping unverified wireless support risks bricking someone's
  settings. It should ship behind an explicit "unverified — help us test" label,
  or wait for a contributor with the hardware.
- **Identity churn**: dongle and Bluetooth present as different devices; a naive
  implementation creates two entries and applies profiles twice.
- **Battery units** are guessable and easy to get wrong (percent vs raw ADC vs
  millivolts); a wrong reading that triggers false low-battery warnings is worse
  than no reading.
- **Flash wear**: writing sleep timers on every slider drag would write flash
  repeatedly; these are commit-on-release settings.
- **Streaming over Bluetooth** may work but with latency and battery cost that
  make it a bad default; measure before enabling.
- **Sleep during a write** — a device that sleeps mid-transaction returns errors
  that must be treated as "asleep", not "broken".

## 10. Acceptance criteria
- AC-1: The wireless command set is documented in `docs/PROTOCOL.md` (or a sibling
  page) with the same provenance tags as the wired one, and each claim is confirmed
  on wireless hardware by a contributor who owns it.
- AC-2: One wireless model connects, reports battery, and accepts a lighting
  change over the dongle.
- AC-3: The same keyboard on cable and on dongle appears as one device with one
  profile.
- AC-4: Setting a sleep timeout survives a power cycle (read back to confirm).
- AC-5: On battery with the default policy, the streamed frame rate drops and the
  UI explains why.
- AC-6: An asleep keyboard shows the asleep state, and a change made then applies
  on wake.

## 11. Effort & milestones
**L.** M1: establish and document the wireless command set (needs a contributor who
owns the wireless model). M2: model descriptions and connection-identity grouping. M3: battery and power settings. M4: power-aware
effect policy. M5: queued changes and asleep handling.

## 12. Open questions
- Does direct lighting work at all over Bluetooth, and at what frame rate and
  battery cost?
- Are the dongle and Bluetooth command sets the same, or does each need its own
  builder set?
- Can the app tell reliably that a keyboard is *asleep* rather than *powered off
  or out of range*, and does that distinction matter to the user?
- Should we ship unverified wireless support at all, or gate it behind a
  contributor with hardware confirming each acceptance criterion?
