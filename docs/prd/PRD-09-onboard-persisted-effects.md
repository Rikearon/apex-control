# PRD-09: Onboard (Persisted) Lighting Effects

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-05 (onboard profile write) **+ reverse engineering** (see §3)
- **Firmware basis:** the firmware's **lighting-graphics engine** (`lighting_config`:
  foundation / reactive / idle graphics, zones, gradients)
  — byte layout only **partially** known, and not confirmed on `0x1642`; the schema-8
  onboard profile write for the profile that carries the indicator lighting.

## 1. Summary
A host-streamed effect dies the moment the app quits and, while it runs, costs host CPU and
a steady stream of USB frames. To make an effect run on the **keyboard's own controller** —
persisting with the app closed, 0 % host CPU, working on any machine with no software — we
have to write the firmware's onboard lighting format. That format is only partially known:
we have the outline of its sections but cannot yet *author* it, and for this exact model we
do not even know where a persisted effect is stored. This PRD is therefore an **RE plan plus
an honest interim**, not a build-it-now feature. It is the single largest technical unknown
in the backlog (gap analysis §A.4).

## 2. Background & GG parity
As far as we know, GG lets a user pick an onboard effect — static, breathe, color shift, wave, reactive — that
the keyboard plays by itself with GG closed. That is the lighting half of the "works on a
console or LAN box with no software" story that PRD-05 delivers for actuation. Without it,
all of our lighting is "while Apex Control is running" only. Note this is genuinely
*narrower* than what our host engine already does (PRD-08) — the value here is **persistence
and 0 % CPU**, not new looks.

## 3. Technical basis (grounded) — and the honest unknowns
There are **two separate persistence mechanisms**, and the one we already understand does
*not* carry running effects:

- **(1) The onboard profile we can already write (PRD-05) does not hold an effect.** The
  schema-8 image holds a schema number, a name, a lighting block, the keyboard settings
  (bindings, actuation, OLED image and macro region; see `docs/PROTOCOL.md`
  §"Onboard profiles & the flash filesystem") and a GUID. Its only lighting field is the
  48-byte lighting block, which is purely **indicator** lighting — lock-key and Fn-key
  colours and a background dimmer (PRD-10). There is **no per-key color map and no
  effect/animation field anywhere in the profile image.** (Grounded in
  the image layout in `docs/PROTOCOL.md`, which a full slot image read off a real unit
  parses against exactly.) So a running effect is stored by some *other* mechanism.
- **(2) The firmware has a separate lighting-graphics engine, and part of its format is
  known.** From the vendor's description of the Apex 7 line (not included in this
  repository; `0x1642` may differ, and nothing below has been confirmed on it), a
  `lighting_config` payload is a sequence of length-prefixed sections (graphics,
  gradients, triggers, zones and idle settings). These compose **foundation / reactive / idle** graphics
  with per-key **zones**, direction/speed/scale, and steady / breathe / colorshift
  color ramps — i.e. the same concepts as our host effects. Confidence: this outline is
  **from descriptor, for the Apex 7 line only** — low confidence for `0x1642` until a
  blob has been read off the device; effect semantics map cleanly onto PRD-08's model.

- **What is missing (LOW confidence / needs RE) — two independent gaps:**
  1. **The forward serializer.** What we know describes how a blob is laid out, not how to
     *build* one. The pieces needed to write it — the numeric codes for the effect types
     (steady / breathe / colorshift), the phase tables, the direction-type codes and
     the exact rules for building each section — are **not known to us**. We know the
     outline of a blob but cannot yet author one.
  2. **The transport/destination for `0x1642`.** No command to *write* a `lighting_config`
     is known for `0x1642`, and it is not a field of the schema-8 image. Where a persisted
     effect is stored for this exact model — a separate FlashFS entry, or a
     device-specific command — is unknown, and so is where one could be *read* from.

  ⇒ Both the **encoding** and the **destination** are unknown. **We will not guess or invent
  bytes and write them to flash.** This is the crux and the reason for the interim below.

- **RE plan (either route unblocks; pursue in parallel):**
  - **(a) Capture an onboard-lighting change.** Capture, on our own keyboard, the USB
    traffic of an onboard-lighting change made with any tool on `0x1642`, isolate the
    flash-write that lands the effect, and work out its layout: change one field,
    re-capture, compare, and read back. This is the authoritative source for `0x1642`
    specifically.
  - **(b) Work the writer out from what we know.** The section outline above gives section
    order and struct sizes; write the encoder from it, recover the missing constants and
    phase tables by experiment on our own keyboard, then **byte-diff** our output against
    a captured blob until they match.

## 4. Goals / Non-goals
- **Goals:** bake a chosen effect into the keyboard so it persists across app-quit **and**
  power loss with 0 % host CPU; author the subset the firmware can actually express; verify
  by read-back / observation before trusting a write; expose it as a "Save lighting to
  keyboard" step in the PRD-05 save flow. **Ship an interim now that needs no RE:** a
  "keep lighting running in the background" mode via the menu-bar agent (PRD-15) so
  host-rendered effects survive window-close.
- **Non-goals:** host-only effects that can *never* run onboard — audio visualizer and
  screen ambient need live host data (PRD-08); the authoring UI itself (PRD-08); firmware
  update (PRD-16); guessing the byte format without a capture or a completed inversion.

## 5. User stories
- As a competitor, I bake a static red look into slot 1 so my keyboard lights correctly on a
  tournament PC with no software.
- As a user, I set a breathing effect, tick "Save lighting to keyboard," and it still
  breathes after I quit the app and replug.
- As a tinkerer, I inspect the effect already stored on my board to learn the format.
- As a realist, when onboard baking isn't available yet, I switch on "keep running in the
  background" so my software effect persists across closing the window (accepting it stops on
  power loss).

## 6. Functional requirements
- FR-1: **Onboard-bakeable subset** — support the effect classes the firmware expresses:
  static (steady), breathe, colorshift/wave (animated gradient), and per-key static (steady +
  zones). Reactive-onboard is a stretch pending RE.
- FR-2: **Expressibility check** — before baking, classify the current effect as
  *onboard-capable* vs *host-only* and show which features will survive (see table in §8);
  never silently drop unsupported layers.
- FR-3: **Verify before trust** — after any lighting write, read it back / observe it and
  compare; do not report success on mismatch (reuse the PRD-05 read-back verification).
- FR-4: **Interim background mode** — a menu-bar (PRD-15) option that keeps the host render
  running with the window closed; clearly labeled as *not* power-loss-durable and *not*
  0 % CPU.
- FR-5: **Safety gate** — the encoder ships behind a feature flag disabled until an RE route
  validates against a captured `0x1642` blob; until then only the **decoder/inspector** and
  the interim are user-visible.
- FR-6: **Coexistence** — baking an effect must not corrupt the indicator lighting block
  (PRD-10) or the rest of the PRD-05 profile.

## 7. UX / UI design
- In the PRD-05 **Save to Keyboard** flow, a **"Save lighting to keyboard"** toggle:
  - When the encoder is not yet validated, the toggle is **disabled** with a plain-language
    explainer ("running effects on the keyboard needs a format we're still reverse-engineering")
    and offers the interim **"Keep lighting running in the background"** instead.
  - When enabled, an effect picker shows which features of the current look will/won't
    survive baking (from FR-2).
- A developer-facing **"Inspect onboard lighting"** view (behind the same area) that reads
  and pretty-prints whatever effect is already on the board — useful during RE and honest
  about what's stored.

## 8. Technical design
- **ApexKit — decoder first (low risk, high learning).** Write a Swift `OnboardLighting`
  decoder for the section layout in §3, to inspect any `lighting_config` blob we obtain
  from our own device (route (a) says where to read it from) and to correct the layout
  wherever the device disagrees with it. Then, behind a feature flag, an **encoder** once
  route (a)/(b) lands; its output is written either into the PRD-05 profile write or its own
  flash entry once the destination is known.
- **App:** `LightingEngine` gains a **background-persist** mode owned by the menu-bar agent
  (PRD-15) for the interim. The bake action lives in the PRD-05 save flow.
- **Data model:** reuse PRD-08's `LightingProject`; add an `onboardBakeable(_:) -> BakeReport`
  validator that flags unsupported layers.
- **Expressibility (grounded in the firmware's effect types + our host set):**

  | Effect | Onboard (firmware) | Host-only |
  |---|---|---|
  | Static / per-key static | ✓ steady graphic + zones (post-RE) | — |
  | Breathe | ✓ breathe gradient (post-RE) | — |
  | Colorshift / wave | ✓ animated gradient (post-RE) | — |
  | Reactive (keypress) | ◐ reactive graphic — stretch, needs RE | ✓ today |
  | Ripple / comet / image sweep | ✗ | ✓ |
  | Audio visualizer | ✗ (needs live host audio) | ✓ |
  | Screen-color ambient | ✗ (needs live host screen) | ✓ |

## 9. Edge cases & risks
- **Flash wear:** bake only on explicit user action, never on a slider/timer; reuse PRD-05's
  erase → write → validate → read-back discipline.
- **Wrong bytes:** a bad `lighting_config` could be rejected or leave a corrupt lighting
  entry; mitigate by gating all writes behind read-back verification, keeping the known-good
  PRD-05 profile write path separate, and providing a clear-and-reload restore.
- **Model divergence:** the layout in §3 is what we know of the **Apex 7 line**; `0x1642`
  may differ. Treat a captured `0x1642` blob as the authority over that description whenever
  they disagree.
- **Interim honesty:** background-persist still uses CPU/USB and stops on power loss — it must
  be labeled so users don't mistake it for true onboard baking.
- **Coexistence:** confirm a baked effect and the 48-byte indicator lighting block don't
  fight (which one wins on profile load?).

## 10. Acceptance criteria
- AC-1: The Swift decoder round-trips a `lighting_config` read from the device (parse →
  re-emit → byte-match) — provable with **no** RE of the encoder (it does need route (a)
  to say where to read it from).
- AC-2 (post-RE): a baked static or breathe effect still plays after quitting the app and
  replugging on a machine with no software installed.
- AC-3: The expressibility check correctly labels host-only effects (audio/ambient/ripple)
  and never bakes them silently.
- AC-4: A failed or aborted lighting write never bricks lighting — a `clear_direct_write`
  (`0x41`) + profile reload restores a working board.
- AC-5: The interim background mode keeps an effect visible with the window closed and states
  plainly that it ends on app-quit/power-loss.

## 11. Effort & milestones
**L (RE-gated).** M0 (parallel, no RE): interim background-persist via PRD-15. M1: Swift
decoder + on-device "inspect onboard lighting." M2: USB-capture harness + one templated
`0x1642` lighting write. M3: encoder for static / breathe / colorshift / wave with read-back
verify. M4: wire into the PRD-05 save-to-slot flow behind the feature flag.

## 12. Open questions
- **Where** does `0x1642` store a persisted `lighting_config` — a profile-adjacent FlashFS
  entry, or a dedicated command? (The profile struct has no room for it.)
- Are the effect-type constants, direction types, and phase tables identical to the
  Apex 7 line's, or model-specific?
- Does a baked effect **override** or **coexist** with the indicator lighting block
  (PRD-10) on profile load?
- Is onboard **reactive** feasible at all on `0x1642`, or is keypress-reactive effectively
  host-only here?
