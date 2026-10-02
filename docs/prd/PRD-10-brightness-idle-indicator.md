# PRD-10: Brightness, Idle Dimming & Indicator Lighting

- **Priority:** P1
- **Status:** Partially implemented — part **(a)**, master brightness, ships (every streamed
  frame is scaled in direct mode), and the Fn-highlight bitmask of part **(d)** is kept in
  step with the Fn bindings inside the boot-profile image (PRD-02/05). Host idle dimming,
  indicator lighting and the highlight color/brightness/dimmer are not built.
- **Depends on:** PRD-05 (onboard lighting-block write) for parts **(c)** and **(d)**;
  parts **(a)** and **(b)** ship independently on a host-side interim. Part **(d)** also
  consumes PRD-02 (Fn layer) bindings.
- **Firmware basis:** direct-mode RGB scaling (live, done) + the onboard lighting block
  (lock-key and Fn-key indicator settings, and a background dimmer). The live idle-timeout,
  idle-dimming and lock-key-colour commands are **empty** on `0x1642`
  (from descriptor: declared, with no fields or behavior).

## 1. Summary
Four related settings that GG groups together: **master brightness**, **idle dimming**,
**indicator lighting** (Caps/Scroll/Num-lock key colors), and **meta-key highlight**
(lighting the keys that carry Fn-layer bindings). On `0x1642` the live idle/lock commands do
nothing (they are declared but stubbed), so the durable versions of these settings live inside
the onboard profile's lighting block and depend on PRD-05. Master brightness and a
host-timer idle-dim work **now** in direct mode; indicators and meta-highlight need the onboard
write. This PRD formalizes all four and is explicit about which parts are live vs
onboard-dependent.

## 2. Background & GG parity
As far as we know, GG exposes a master brightness slider, a "dim or turn off after N minutes of inactivity"
option, colored lock-key indicators, and a highlight for keys that have Fn bindings. A
brightness control in particular is table stakes. The nuance (gap analysis §A.2): on this
model these are **not** quick live commands. The idle-timeout, idle-dimming and
lock-key-colour commands are declared but empty (from descriptor), so real
persistence routes through the onboard lighting block. In direct mode we can *fake* master
brightness by scaling RGB (already done); true idle-dim and Caps/Fn indicator lighting need
onboard persistence.

## 3. Technical basis (grounded)
- **(a) Master brightness — confirmed, already working.** Every streamed frame is scaled by
  `LEDColor.scaled(by: config.brightness)` in `LightingEngine.renderAndSend`; there is no
  LED-brightness command in this family (PROTOCOL.md), so global brightness *is* RGB scaling in
  direct mode. This PRD promotes `LightingConfig.brightness` to a first-class, persisted global
  control. Confidence: confirmed (shipping).
- **(b) Idle dimming — split into a solid interim and an RE-gated "true" version.**
  - *Host-side interim (confirmed feasible):* a host inactivity timer — `KeyMonitor` for input
    plus `CGEventSource.secondsSinceLastEventType(...)` — ramps `config.brightness` down after
    N minutes and restores it on activity. Pure scaling, no protocol. Works only while the app
    / menu-bar agent (PRD-15) is running and the board is in direct mode.
  - *True firmware idle-dim (LOW confidence / needs RE):* there is **no idle field to write** on
    this model. The live idle-timeout and idle-dimming commands are empty, and the
    onboard lighting block (48 B) contains **no idle-timeout or idle-brightness field** —
    only the lock-key and Fn-key indicator settings and the background dimmer. The firmware's actual idle appearance
    is expressed as an **idle graphic** in its lighting-graphics engine, i.e. the opaque graphics format of
    **PRD-09**. So a device-resident idle-dim is bound to PRD-09's RE, not to a simple
    profile field. We therefore ship the host-side interim as the reliable path and do not
    present a fake "device idle timeout" control.
- **(c) Indicator lighting — onboard, via PRD-05 (grounded layout).** The onboard lighting
  block holds the lock-key indicator settings: a brightness byte, an RGB colour, and the
  four physical HID codes treated as indicators. The defaults are `83, 57, 71, 227` =
  Num-lock, Caps-lock, Scroll-lock, and the Left GUI (Cmd/Windows) key, `0xE3` (from descriptor). These
  are written as part of the schema-8 profile blob (PRD-05). Confidence: layout + defaults
  from descriptor; the live effect needs on-hardware validation because **no live
  command exists** to preview it.
- **(d) Meta-key highlight — onboard, ties to PRD-02 (grounded).** Also in the lighting
  block: a brightness byte and an RGB colour for the Fn-layer highlight, the 32-byte
  highlight mask, and a background-dimmer byte. The 32-byte mask is **256 bits, one per HID code**, marking
  which keys light up on the Fn layer; the rule the firmware applies (PRD-02 §3) sets a bit
  for every key that has a non-trivial meta-layer mapping — so the mask is *derived from
  PRD-02's Fn bindings*, not authored by hand. The background dimmer dims the non-meta keys
  while the Fn layer is engaged (default `10`, from descriptor). Confidence: layout + derivation grounded;
  behavior needs hardware validation.

## 4. Goals / Non-goals
- **Goals:** a global **master-brightness** control (live, RGB scale); a **host-side idle-dim**
  (timeout + target level + restore-on-activity); onboard **indicator** color/brightness and a
  choice of which keys are indicators (via PRD-05); onboard **meta-key highlight** color/
  brightness + background dimmer, with the mask auto-derived from Fn bindings (via PRD-02/05); a
  single **"Brightness & Idle"** section that clearly labels each control as *live* or
  *saved-to-keyboard*.
- **Non-goals:** a device-resident idle **timeout** as a settable field (blocked on PRD-09's
  opaque idle-graphic format — we offer host-side instead, and will not ship a control that
  silently does nothing); the Fn-binding editor itself (PRD-02); per-key base colors and running
  effects (PRD-08 / PRD-09).

## 5. User stories
- As a user, I drag one brightness slider and the whole board dims immediately.
- As a laptop user, I set "dim to 20 % after 5 minutes idle" and the board fades down when I
  step away and snaps back when I type.
- As a user, I make my Caps-lock key glow red so I can see lock state at a glance, and it stays
  after I quit the app.
- As a power user, every key that has an Fn binding lights up in orange while I hold Fn, so I can
  see my secondary layer.

## 6. Functional requirements
- FR-1: **Master brightness** 0–100 %, applied as RGB scaling to every streamed frame; persisted
  as an app setting.
- FR-2: **Idle dimming (host)** — enable/disable; timeout 1–60 min (or off); target level
  (dim % or full off); restore to prior brightness on any input. Active only in direct mode while
  the app/agent runs.
- FR-3: **Indicators (onboard)** — color and brightness for the indicator keys, plus a selectable
  set of up to **4** indicator HIDs (default Num/Caps/Scroll + Left GUI = `83,57,71,227`); written via
  PRD-05.
- FR-4: **Meta highlight (onboard)** — color and brightness for Fn-bound keys; the background dimmer
  0–100 %; the 32-byte highlight mask is generated from PRD-02 bindings, not hand-edited.
- FR-5: **Live-vs-onboard labeling** — every control states whether it takes effect immediately or
  only after "Save to Keyboard"; onboard controls are disabled with an explainer when PRD-05 is
  unavailable (or PRD-02 for the mask).
- FR-6: **No dead controls** — do not expose a firmware idle-timeout field backed by the stubbed
  APIs; idle is host-side unless/until PRD-09 provides a real device-resident path.

## 7. UX / UI design
- A **"Brightness & Idle"** section in `LightingView`:
  - **Master brightness** slider (live) at the top.
  - **Idle** card: enable, timeout, target level; a subtitle noting it applies while Apex Control
    (or the menu-bar agent) is running.
  - **Indicators** card: color well + brightness, and a key picker on the live `KeyboardView` to
    choose the ≤ 4 indicator keys; marked "Saved to keyboard."
  - **Meta highlight** card: color well + brightness + background-dimmer slider, with a live preview
    that highlights the keys currently carrying Fn bindings; marked "Saved to keyboard."
- **Onboard cards** carry a "Save to Keyboard" affordance wired to the PRD-05 save flow, and show a
  disabled/explainer state when PRD-05 (or, for the mask, PRD-02) isn't present.
- **Preview caveat:** because there is no live indicator/idle command, onboard cards preview only
  on the on-screen keyboard until the profile is actually saved.

## 8. Technical design
- **ApexKit:** extend the PRD-05 `OnboardProfile` model's lighting block with
  `lockKeys { brightness, color, physHids[4] }` and
  `metaKeys { brightness, color, mask[32], backgroundDimmer }`, serialized in the field order of the
  lighting block (48 B; layout in `docs/PROTOCOL.md`). The helper that builds
  the highlight mask from PRD-02 mappings already exists (`Mappings.metaHighlightMask`,
  HID-indexed bitmask) and `OnboardProfile` already patches it into the image. Confirm and reuse
  the default indicator HIDs `83,57,71,227`.
- **App:** promote the existing `LightingConfig.brightness` to a persisted global setting driving
  `LightingEngine`; add an `IdleDimmer` (timer + `secondsSinceLastEventType`, restore on `KeyMonitor`
  activity) that scales the engine's brightness; add a `BrightnessIdleView` section. `DeviceController`
  owns the idle timer and the brightness setting.
- **Data model:** `Codable` `IndicatorConfig` and `MetaHighlightConfig` folded into the onboard
  profile; idle settings (enabled, timeout, target) live in app preferences, not on the device.

## 9. Edge cases & risks
- **Direct-mode scope:** brightness scaling and host idle-dim only affect keys we are actively
  driving. When the app quits and the board shows its onboard profile, only the onboard
  lighting-block values apply — set this expectation in the UI.
- **Flash wear:** indicator/meta writes go through PRD-05 (explicit save only, never on slider drag).
- **No semantic validation:** the firmware colors whatever HIDs are in the indicator list even if
  they aren't real lock keys — the picker should guide, but odd choices are harmless.
- **Mask indexing:** the highlight mask is **HID-indexed** (bit `hid & 7` of byte `hid / 8`, as in
  command `0x3C`), not firmware-offset-indexed — do not confuse it with the onboard key-index tables.
- **Idle responsiveness:** the crispest idle reset uses `KeyMonitor` (Accessibility); without that
  permission, fall back to polling `secondsSinceLastEventType`.
- **Brightness = 0** produces a black board but keeps the effect running so it restores when raised.

## 10. Acceptance criteria
- AC-1: The master-brightness slider scales output smoothly from full to off, live.
- AC-2: With idle-dim enabled, the board ramps to the target level after the set timeout and
  restores on the next input.
- AC-3: After a PRD-05 save, unplugging and replugging on a software-free machine shows the chosen
  indicator key(s) in the chosen color/brightness.
- AC-4: After a save, the keys lit by the meta highlight exactly match the keys that have Fn bindings
  in PRD-02 (mask matches), and the background dims by the set amount while Fn is held.
- AC-5: There is **no** control that claims to set a device idle timeout while doing nothing — idle is
  either host-side or (later) backed by PRD-09.

## 11. Effort & milestones
**M.** M1: master brightness as a first-class, persisted live control. M2: host idle-dim (timer +
restore). M3: indicator config in `OnboardProfile` + save/verify (needs PRD-05). M4: meta-highlight
mask from PRD-02 + background dimmer.

## 12. Open questions
- Does writing the lighting block's indicator fields take effect on profile **load**, or only after
  a power cycle?
- Does the background dimmer apply only while Fn is held, or whenever a meta binding exists?
- Is there any `0x1642` route to a firmware idle **timeout** (a separate FlashFS setting) we simply
  haven't captured, or is host-side genuinely the only option until PRD-09?
- Units/curve of the indicator and highlight brightness bytes — linear 0–255, or gamma-encoded?
