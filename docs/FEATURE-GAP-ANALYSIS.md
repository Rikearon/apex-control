# Apex Control vs. SteelSeries GG — Feature Gap Analysis

**Scope:** the *keyboard* feature set of SteelSeries GG (the "Engine" app) for the
Apex Pro TKL Gen 3 (`1038:1642`), compared against what Apex Control does today.
Sonar (audio), Moments (capture), and non-keyboard devices are out of scope. GG
changes over time: its columns describe what we know it to offer and may be out of
date, and corrections are welcome.

**§G extends past parity.** Sections A–F are bounded by what GG can do; §G covers
the ground that comparison cannot reach — host-side capability, hardware breadth,
and the engineering a project needs to be trusted and maintained.

**Method.** The keyboard's firmware exposes a fixed set of commands. We identified
them from the vendor's description of this model and checked them against the
physical device; [PROTOCOL.md](PROTOCOL.md) says how sure each part is and where the
information came from. The command families we know of for `0x1642`, and what this
project does with each:

| Family | What it covers | Here |
|---|---|---|
| Lighting | per-key direct write, and handing lighting back | done |
| Actuation | primary and second-actuation thresholds | done |
| Rapid trigger | release mode and sensitivity | done |
| Rapid tap (SOCD) | enable, and the key pairs | done |
| OLED | live write, saved image, reset | done |
| Key bindings | write, read-back for each layer, the Fn trigger key | done |
| Macros | macro data | missing |
| Onboard profiles | switch slot, volatility, write and read of the flash image | done (bindings, actuation, rapid trigger, rapid tap and the Fn key) |
| Identity | firmware version, layout, region, name, GUID | read only |
| Firmware and region writes | firmware update, region write | deliberately not exposed |
| Idle timeout, idle dimming, lock-key colour | declared, but empty on this model | stubs (see §A) |

If a capability is not backed by one of these command families or by host-side logic, we
know of no way for any software to do it, so this analysis is bounded by what the
hardware exposes.

---

## A. Four nuances that dominate the whole roadmap

Read these first; they explain why several "small" features are actually large.

1. **Live vs. onboard is a hard split.** Commands come in two flavours:
   - *Live* commands (per-key colour writes `0x40`, thresholds `38 61`, release mode
     `38 62`, rapid trigger and rapid tap `38 65`–`38 67`, the live OLED write `1F 81`,
     and binding writes `0x36`) take effect immediately and are
     what Apex Control uses today. They are **volatile**: direct-mode lighting is
     lost when the keyboard is unplugged with no host driving it. (Actuation,
     rapid trigger, and remaps set live do persist in the active session but are
     overwritten by whatever onboard profile the keyboard loads on power-up.)
   - *Onboard* state (the 5 hardware profile slots) survives power loss and works
     on any computer with no software. Writing it requires the **full profile
     flash-write** (schema 8): a ~12 KB blob containing
     lighting + all key mappings + actuation + rapid-trigger + OLED image + macros
     + rapid-tap, chunked to flash with a CRC and validated with `0xB1`.

   ⇒ **Onboard Profile Persistence (PRD-05) is the keystone.** Genuine "set it and
   forget it" parity for lighting, brightness, idle, macros, and per-key config
   all flow through it.

2. **Brightness / idle-dim / lock-key lighting have no live command on this
   model.** The commands for idle timeout, idle dimming and lock-key colour are
   declared but **empty** for this model (*from descriptor*). These settings live
   only inside the onboard profile's lighting block (lock-key brightness and colour,
   Fn-key highlight brightness and colour, background dimmer). So "add a brightness slider that
   dims when idle" is **not** a quick command — it depends on PRD-05. In *direct*
   mode we can fake master brightness by scaling RGB (already done), but true
   idle-dim and Caps/Fn indicator lighting need onboard persistence.

3. **The Fn layer is not empty — it ships with the keyboard's own shortcuts.**
   Reading layer 1 off a stock board returns nine `function 0x62` entries with
   distinct payloads (F9–F12, Q/T/I/O, Left Cmd): the SteelSeries-key
   brightness, media, and OLED controls. `0x62` therefore means "run firmware
   function *n*", not "this is the Fn key" (that is the Fn-trigger command, `0x35`). Because
   every mapping write is a **complete frame for its layer**, a naïve "write my
   bindings" that leaves the Fn layer blank **erases those shortcuts**; we know of no
   command that restores them. Apex Control merges over the
   read-back and skips layers it has not read; "Reset all keys" leaves the
   Fn layer alone unless asked explicitly. Any future work on layers must keep
   this property.

4. **The onboard lighting *effect* format is only partially open.** The per-key
   *color* protocol is fully known, but the firmware's onboard effect engine
   (breathe/wave/reactive running on the keyboard itself) has no byte layout that
   we know of. Two consequences: (a) our software effects (PRD-08) are actually
   *more* capable than onboard effects; (b) making an effect run *on the keyboard*
   (PRD-09) requires further reverse engineering, for example from USB captures of
   an effect being saved to our own keyboard. This is the single biggest technical
   unknown in the backlog and is called out in PRD-09.

---

## B. Capability matrix

Status: ✅ done · ◐ partial · ✗ missing. "Basis" = what enables it.

### Lighting
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| Per-key static colors | per-key colour write (`0x40`) | ✅ | — |
| Software effects (wave, cycle, breathe, reactive) | host + per-key colour write | ✅ | rendered on the Mac; the effect set differs from GG's |
| Multi-stop gradients, per-zone/region effects, layers | host render | ✗ | PRD-08 |
| Effect direction / speed / per-key params | host render | ◐ | PRD-08 |
| Preset library, import/export lighting | host | ✗ | PRD-08 |
| Onboard effects (run on keyboard, 0% CPU, persist) | profile flash-write + an effect payload of unknown layout | ✗ | PRD-09 (partly opaque) |
| Master brightness | RGB scale (direct) / profile (onboard) | ◐ | PRD-10 |
| Idle dim after timeout | onboard profile only (live stubbed) | ✗ | PRD-10 |
| Caps/Scroll/Num-lock indicator lighting | onboard lighting block (lock keys) | ✗ | PRD-10 |
| Meta-key highlight (light keys that have Fn bindings) | onboard lighting block (Fn keys) | ✗ | PRD-10 / PRD-02 |
| Reactive/interactive (ripple, audio-visualizer) | host render | ◐ | PRD-08 |

### Performance (actuation)
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| Global actuation 0.1–4.0 mm | thresholds (`38 61`) | ✅ | — |
| Per-key actuation | thresholds (`38 61`) | ✅ | — |
| Rapid trigger + sensitivity | release mode (`38 62`), sensitivity (`38 65`) | ✅ | — |
| Rapid-trigger release modes 3/4 | release-mode values | ✅ | exposed as "Alternate mode 3/4", labelled unverified |
| Rapid tap / SOCD | rapid tap (`38 66`, `38 67`) | ✅ | — |
| Dual actuation / two-stage bindings | second thresholds (`38 61`, layer 2) + layer-2 bindings (`36 02`) | ✅ | thresholds + bindings + UI |
| Protection mode | in the profile image | ✗ | PRD-03 |

### Key configuration
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| Remap key → key/modifier combo | binding write (`0x36`), fn `0x51` | ✅ | round-trip verified on hardware |
| Remap → media/consumer | binding write, fn `0x61` | ✅ | 6 codes firmware-confirmed |
| Remap → mouse button / wheel / pan | binding write, fn `0x01–08,0x31–34` | ✅ | — |
| Disable a key | binding write, fn `0x51` + zero usages | ✅ | see PROTOCOL.md — fn `0x00` means *default*, not *dead* |
| Meta / Fn secondary layer | Fn trigger (`0x35`) + layer-1 bindings | ✅ | factory Fn shortcuts preserved (see §A.3) |
| Launch app / system fn / text | fn `0x72` EXTERNAL (host-assisted) | ✗ | PRD-14 (sentinel format still unknown) |
| Read current bindings from device | binding read-back (`0xB6`) | ✅ | all three layers, verified |

### Macros
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| Record/edit keystroke macros w/ timing | 9600 B onboard, fn `0x71`, chunked write | ✗ | PRD-04 |
| Assign macro to a key | binding write, fn `0x71` + macro id | ✗ | PRD-04 |
| Repeat/toggle/hold playback options | macro metadata | ✗ | PRD-04 |

### OLED
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| Custom text / image (live + persist) | live write (`1F 81`) / saved image (`38 83`) | ✅ | — |
| Live clock | host + live write | ✅ | — |
| System stats (CPU/GPU/RAM/net) | host data → OLED | ✗ | PRD-11 |
| Now-playing / media | host (MediaRemote) → OLED | ✗ | PRD-11 |
| Notifications (Discord, etc.) | host → OLED | ✗ | PRD-11 |
| Animated GIF playback | host loop ≤10 fps | ✗ | PRD-12 |
| Screensaver + auto-dim/off on idle | host / onboard | ✗ | PRD-12 |
| Multi-app carousel / layout editor | host | ✗ | PRD-11 |

### Profiles & automation
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| Named software profiles on the computer | host | ✅ | — |
| Save config to 5 onboard slots (portable) | profile flash-write | ◐ | PRD-05 — slot 0 auto-persist of bindings/actuation/rapid-trigger/rapid-tap/Fn key is done (read-modify-write, CRC verified on hardware); multi-slot UI, naming, and onboard lighting remain |
| Switch active profile | load profile (`B2`), profile volatility (`34`) | ✅ | volatility verified: neither argument makes live writes persist |
| Auto-switch profile per application/game | host foreground detection | ✗ | PRD-07 |
| Import/export / backup / share configs | host | ✅ | JSON, atomic writes |
| Import existing GG configs | — | ✗ | not planned: the format is undocumented (PRD-18 §4). Apex Control's own profiles export and import as JSON |

### System, integration & UX
| GG capability | Basis | Status | Gap / PRD |
|---|---|---|---|
| GameSense — games drive lighting/OLED | host event server + our engine | ✗ | PRD-13 |
| Reflect on-device Fn changes (bright/profile/actuation) in UI | `0xFFC1` input reports | ✗ | PRD-14 |
| Menu-bar app, launch at login, background apply | host | ✅ | — |
| Firmware update | the firmware-update command is deliberately not implemented | ✗ | not planned. PRD-16 only shows the version and points to the vendor's updater |
| App icon, onboarding, accessibility, localization | host | ✗ | PRD-18 |

---

## C. Dependency graph

```
PRD-05 Onboard Profile Persistence  ─┬─► PRD-06 Profile System ──► PRD-07 Per-App Switching
 (flash write, schema 8)             ├─► PRD-10 Brightness / Idle / Indicator lighting
                                     ├─► PRD-09 Onboard (persisted) effects
                                     └─► PRD-04 Macros (onboard storage)  ◄── PRD-01 Remapping
PRD-01 Remapping ──► PRD-02 Meta/Fn layer ──► PRD-03 Dual-bind actuation
PRD-17 Device Read-Back  ──► accurate UI for PRD-01/04/06
PRD-13 GameSense  ──► reuses PRD-08 lighting engine + PRD-11 OLED
PRD-14 Hardware Event Sync, PRD-15 Menu-bar, PRD-18 Polish — independent
```

**Keystone:** PRD-05 unblocks the most parity. **Cheapest high-value wins:**
PRD-01 (remapping), PRD-11 (OLED apps), PRD-15 (menu-bar/login), PRD-03 (expose
dual actuation — kit already has the threshold command).

---

## D. Prioritization

**P0 — core parity, mostly unblocked**
- PRD-01 Key Remapping & Bindings
- PRD-05 Onboard Profile Persistence *(keystone)*
- PRD-06 Profile System & Switching
- PRD-15 Menu-bar, Launch-at-Login, Background

**P1 — high value, depends on P0 or moderate effort**
- PRD-02 Meta/Fn Layer · PRD-03 Dual-Bind Actuation · PRD-04 Macros
- PRD-10 Brightness / Idle / Indicator Lighting
- PRD-11 OLED GameSense Apps · PRD-07 Per-App Switching
- PRD-17 Device State Read-Back

**P2 — depth, polish, or higher risk/unknowns**
- PRD-08 Advanced Lighting Authoring · PRD-09 Onboard Effects *(RE unknown)*
- PRD-12 OLED GIF/Screensaver · PRD-13 GameSense Integration
- PRD-14 Hardware Event Sync · PRD-18 Product Polish & Onboarding
- PRD-16 Firmware Update *(information only; flashing is not planned)*

---

## E. Where Apex Control differs from GG

Worth stating so the backlog is honest: our software effect engine renders any
effect the Mac can compute (unlimited per-key animation, reactive to arbitrary
host events) rather than being limited to the firmware's onboard modes, and there
is no telemetry, account, or cloud dependency. GG offers things this project does
not yet (see §B). The gaps below are about *breadth of parity*.

---

## F. PRD index

Each PRD is a standalone file in [`docs/prd/`](prd/). All follow the same template
([`docs/prd/_TEMPLATE.md`](prd/_TEMPLATE.md)).

| # | Title | Priority | Status | Keystone dep |
|---|---|---|---|---|
| 01 | Key Remapping & Bindings | P0 | ✅ done | — |
| 02 | Meta / Fn Secondary Layer | P1 | ✅ done | 01 |
| 03 | Dual-Bind & Advanced Actuation | P1 | ✅ done | 01 |
| 04 | Macro Engine | P1 | ✗ | 01, 05 |
| 05 | Onboard Profile Persistence *(keystone)* | P0 | ◐ persistence core done (slot 0, verified on hardware) | — |
| 06 | Profile System & Switching | P0 | ✅ done (software tier) | 05 for flash writes |
| 07 | Per-Application Auto-Switching | P1 | ✗ | 06 |
| 08 | Advanced Lighting Authoring | P2 | ✗ | — |
| 09 | Onboard (Persisted) Lighting Effects | P2 | ✗ | 05 + RE |
| 10 | Brightness, Idle Dimming & Indicator Lighting | P1 | ◐ direct-mode brightness; the Fn-highlight mask is kept in step in the profile image | 05 |
| 11 | OLED GameSense Apps (stats, media, notifications) | P1 | ✗ | — |
| 12 | OLED Image, GIF & Screensaver | P2 | ✗ | — |
| 13 | GameSense / Game Event Integration | P2 | ✗ | 08, 11 |
| 14 | Hardware Event Sync (0xFFC1 listener) | P2 | ✗ | — |
| 15 | Menu-Bar App, Launch-at-Login & Background | P0 | ✅ done | — |
| 16 | Firmware Update (Information Only) | P2 | ✗ | — |
| 17 | Device State Read-Back & Sync | P1 | ◐ bindings and slot 0 read back; lighting and the other slots not | — |
| 18 | Product Polish & Onboarding | P2 | ✗ | — |
| 19 | Host Key Engine (tap-hold, chords, one-shot modifiers) | P1 | ✗ | — |
| 20 | Typing Analytics & Actuation Tuner | P2 | ✗ | — |
| 21 | Ambient (Screen-Mirror) Lighting | P2 | ✗ | 08 |
| 22 | Audio-Reactive Lighting | P2 | ✗ | 08 |
| 23 | System & Notification Lighting | P2 | ✗ | 08 |
| 24 | Effect Scripting & Plugin API | P2 | ✗ | 08, 34 |
| 25 | Automation & Integration Interface | P1 | ✗ | 06 |
| 26 | Config-as-Code & Profile Sync | P2 | ✗ | 06 |
| 27 | Multi-Device & Multi-Model Support | P1 | ✗ | — |
| 28 | Wireless Variants & Battery | P2 | ✗ | 27 |
| 29 | Device Backup, Restore & Rescue Mode | P0 | ✗ | — |
| 30 | Protocol Conformance & Capability Probe | P1 | ✗ | 29 |
| 31 | Device Simulator & Test Harness | P1 | ✗ | — |
| 32 | Distribution, Signing, Notarization & Updates | P0 | ◐ tag-triggered ad-hoc release workflow (written, not yet run on GitHub); no notarization or updates yet | — |
| 33 | Accessibility & Internationalization | P1 | ✗ | — |
| 34 | Privacy, Security & Permission Model | P0 | ◐ security policy and privacy page done; threat model, in-app privacy page and hardening tests not | — |
| 35 | Diagnostics, Protocol Console & Support Bundle | P1 | ✗ | — |
| 36 | Power & Performance Budget | P1 | ✗ | — |
| 37 | Project Documentation, Compatibility Matrix & Community | P1 | ◐ docs, policies and templates done; no generated matrix | — |

**Next up.** Remapping, layers, profiles, background operation and the core of
flash persistence (PRD-05) are done. The open P0 PRDs are **PRD-29** (backup,
restore and rescue; it argues that PRD-05's flash writes should have depended on
it), **PRD-32** (distribution beyond ad-hoc signing, whose tag-built release
pipeline is written but has not yet run on GitHub) and **PRD-34** (the privacy and permission model).
Among the P1s, **PRD-04** (macros, which need PRD-05's chunked `0x37` writes),
**PRD-11** (OLED apps: cheap and self-contained) and **PRD-07** (per-app
switching, which now only needs foreground detection on top of the profile
system) were called out earlier as the natural next steps.

---

## G. Beyond GG parity — what no PRD had claimed

Sections A–F measure this project against SteelSeries GG. That comparison has a
ceiling: it can only ever describe a keyboard configurator, and it says nothing
about whether the thing is trustworthy, testable, installable, or usable without
sight. PRDs 19–37 cover what a sweep for *unclaimed* ground turned up.

The sweep was bounded the same way §B was. Every endpoint we know of for `0x1642`
is now claimed by some PRD, so we know of no unexploited *firmware* surface: each
endpoint was checked against the index. The profile name and the GUID have no
working live command either (*from descriptor*: declared but empty); their content
lives inside the onboard profile (PRD-05), and we found no polling-rate, debounce,
NKRO, or win-lock endpoint for this model at all. What remains unclaimed is
therefore host-side capability, hardware breadth, and project health.

Two hardware facts from the sweep bound whole categories:

- The keyboard exposes **five HID interfaces** and the consumer one carries a
  second Generic Desktop/**Mouse** collection — so mouse bindings have a real
  transport, which a naive enumeration would have said they did not.
- **No interface declares an analog/gamepad collection.** We know of no way to read
  key *travel* from the host, so "use a key as a joystick axis" and live travel graphs
  are not achievable through any documented channel. Anything in that direction would
  have to come from the `0xFFC1` input stream, which has not been examined.

### Input & analysis
| # | Title | Priority | Why it is not in §B |
|---|---|---|---|
| 19 | Host Key Engine (tap-hold, chords, one-shot mods) | P1 | firmware mappings are 1:1 with no timing, so this needs host-side logic |
| 20 | Typing Analytics & Actuation Tuner | P2 | per-key actuation currently ships with no feedback loop at all |

### Lighting beyond the firmware
| # | Title | Priority | Why it is not in §B |
|---|---|---|---|
| 21 | Ambient (Screen-Mirror) Lighting | P2 | needs display capture |
| 22 | Audio-Reactive Lighting | P2 | now possible driver-free via ScreenCaptureKit audio |
| 23 | System & Notification Lighting | P2 | host-side answer to PRD-10's indicators, plus classes the firmware's own indicators do not cover |
| 24 | Effect Scripting & Plugin API | P2 | the effect library cannot grow without a release otherwise |

### Automation, configuration, breadth
| # | Title | Priority | Why it is not in §B |
|---|---|---|---|
| 25 | Automation & Integration Interface | P1 | the CLI cannot talk to the running app; nothing can script it |
| 26 | Config-as-Code & Profile Sync | P2 | exported profiles carry UUIDs and timestamps, so they do not diff |
| 27 | Multi-Device & Multi-Model Support | P1 | ApexKit is hard-wired to one PID; `0x1628` looks similar (per the vendor's description; untested) |
| 28 | Wireless Variants & Battery | P2 | a battery changes every assumption the 30 fps engine makes |

### Trust, correctness, safety
| # | Title | Priority | Why it is not in §B |
|---|---|---|---|
| 29 | Device Backup, Restore & Rescue Mode | **P0** | **PRD-05 should depend on this** — a flash write cannot be undone without a backup |
| 30 | Protocol Conformance & Capability Probe | P1 | several shipped features are labelled "unverified" with no way to verify |
| 31 | Device Simulator & Test Harness | P1 | nothing above the byte builders is testable without hardware |
| 34 | Privacy, Security & Permission Model | **P0** | imported profiles are data that can remap keys and carry an image path; scripting is queued |

### Product & project
| # | Title | Priority | Why it is not in §B |
|---|---|---|---|
| 32 | Distribution, Signing, Notarization & Updates | **P0** | releases are ad-hoc signed and not notarized, so every user has to approve the app by hand |
| 33 | Accessibility & Internationalization | P1 | a keyboard app that needs a mouse, in English only |
| 35 | Diagnostics, Protocol Console & Support Bundle | P1 | remote bugs are currently undiagnosable |
| 36 | Power & Performance Budget | P1 | any resource comparison with GG is unmeasured |
| 37 | Project Docs, Compatibility Matrix & Community | P1 | the protocol knowledge is the project's most valuable output |

### What this changes about the order of work

Three of these are **P0 and unblocked**, and two of them should come before more
features:

1. **PRD-32 (distribution)** — releases are meant to be built by CI (the workflow
   has not yet run on GitHub), and are ad-hoc signed and not notarized, so every user
   has to approve the app by hand, and there is no update channel.
2. **PRD-29 (backup & rescue)** — PRD-05's flash writes are already shipped, and
   the Fn-layer discovery in §A.3 showed that some device state cannot be recovered
   without a copy made beforehand, and that our instinct to write full frames is
   dangerous without a way back, so
   a backup and a rescue mode should come before more features that write flash.
3. **PRD-34 (security model)** — gates PRD-24, and formalises promises the
   project already makes implicitly.

Then **PRD-31 (simulator)** and **PRD-27 (multi-model)** are force multipliers:
the first makes everything else testable, the second multiplies the audience for
every feature already built.
