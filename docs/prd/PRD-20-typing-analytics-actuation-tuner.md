# PRD-20: Typing Analytics & Actuation Tuner

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** — (uses the existing actuation write path; shares the event tap with PRD-19)
- **Firmware basis:** **host-side only.** The keyboard does **not** report key
  travel — there is no analog/gamepad collection on any of its five HID
  interfaces (`docs/PROTOCOL.md` §interface map). Everything here is derived from
  keystroke *timing*, not from sensor values.

## 1. Summary
Apex Control lets you set an actuation point per key from 0.1 mm to 4.0 mm and
gives you no way to know whether you chose well. This PRD closes that loop: a
local, privacy-preserving record of your own typing (counts, timing, and
suspected double-fires) that turns into a concrete recommendation — "your `e` is
double-firing at 0.4 mm; try 0.8 mm" — plus the heatmaps that make the data
worth looking at.

## 2. Background & GG parity
We are not aware of GG or any other keyboard software offering this. It exists
because hall-effect keyboards create a problem mechanical ones do not: a very
shallow actuation point is fast but chatters, and users have no feedback loop
other than frustration. Today the honest advice in our own UI is a set of
presets named "Hair Trigger / Gaming / Balanced / Typing", which is guesswork
dressed as guidance. Without this, per-key actuation stays a toy that almost
nobody tunes past the global slider.

## 3. Technical basis (grounded)
- **Data source** (confidence: proven — `KeyMonitor` already does this).
  A `CGEventTap` in `.listenOnly` mode gives key-down and key-up with
  timestamps. Requires Input Monitoring or Accessibility (either is enough for a
  listen-only tap, as `KeyMonitor` already relies on). Key-up needs adding to the
  existing mask (`.keyUp`), which today only watches `.keyDown`.
- **Double-fire detection** (confidence: sound inference, needs calibration).
  A chatter event looks like `down/up/down` for the same key inside a window far
  shorter than a human repeat — practically < 40 ms with no intervening key. The
  threshold must be tuned against real data before it is surfaced as advice.
- **What we cannot do** (confidence: confirmed on hardware): read the analog
  position of a key, show a live travel graph, or calibrate the hall sensor.
  None of that leaves the keyboard. Any UI implying otherwise would be a lie.
- **What we can infer**: per-key frequency, per-key hold duration, inter-key
  intervals, bigram timing, error-correction rate (Backspace/Delete following a
  key), and same-key repeat intervals.
- **Actuation write path** is already implemented and hardware-verified
  (`0x38 0x61`, per-key levels).

## 4. Goals / Non-goals
- **Goals:** opt-in local recording; per-key usage and timing heatmaps on the
  existing `KeyboardView`; double-fire detection; per-key actuation
  recommendations with one-click apply; a before/after comparison so a change can
  be judged; full data export and delete.
- **Non-goals:** anything leaving the machine; keylogging of *content* (we store
  counts and timings, never sequences that reconstruct text); WPM leaderboards or
  gamification; sensor calibration; claiming to measure travel distance.

## 5. User stories
- As a user, I see which keys I actually press so per-key actuation is worth the
  effort.
- As someone getting stray double letters, the app tells me which keys chatter
  and what to change.
- As a gamer, I set WASD shallow and confirm from data that I did not make the
  rest of my typing worse.
- As a privacy-minded user, I can see exactly what is stored, export it, and
  delete it in one click.
- As a tuner, after changing actuation I get a "since the change" comparison
  instead of having to remember how it felt.

## 6. Functional requirements
- FR-1: Recording is **off by default** and requires an explicit opt-in that
  states plainly what is stored and where.
- FR-2: Stored per key: press count, mean/median hold duration, and a histogram
  of same-key repeat intervals. **No key sequences and no timestamps that could
  reconstruct typed text** — inter-key intervals are aggregated into histograms,
  not logged as a stream.
- FR-3: Modifier-bearing chords are counted as the base key only; no combination
  is recorded (that would leak content).
- FR-4: A key is flagged as **suspected double-fire** when repeats under the
  chatter threshold exceed a rate (default: > 0.5 % of that key's presses, with
  at least 20 presses of evidence).
- FR-5: Recommendation rule: for a flagged key, propose the current level + 4
  (0.4 mm deeper), clamped to 40, and never propose a change to a key with
  insufficient evidence.
- FR-6: Heatmap modes on the shared keyboard view: **frequency**, **hold time**,
  **suspected chatter**, and the existing **actuation level**.
- FR-7: "Apply recommendations" writes per-key levels through the existing
  actuation path and records a marker so the next report can compare.
- FR-8: Data is capped (rolling window, default 30 days) and stored in one file
  under Application Support; size shown in the UI.
- FR-9: One-click **Export** (JSON) and **Delete all data**, both always
  reachable, including when recording is off.
- FR-10: Recording pauses automatically while Secure Input is active.

## 7. UX / UI design
- A new **Insights** pane. Before opt-in it shows a single explanatory card and
  an Enable button — no empty charts, no dark patterns.
- After opt-in: the shared `KeyboardView` with a heatmap-mode segmented control,
  a "Findings" card (flagged keys, plain language, each with Apply / Dismiss),
  and a "Your data" card (rows recorded, file size, Export, Delete).
- **Comparison:** when an actuation change was applied from here, the Findings
  card gains a "since 3 Aug: chatter on `e` down from 1.2 % to 0.0 %" line.
- **Empty/low-data state:** "Not enough presses yet to say anything useful"
  rather than a chart of noise.
- Colour: heatmaps must not rely on hue alone (see PRD-34) — pair colour with a
  value label on hover and a numeric legend.

## 8. Technical design
- **ApexKit:** no protocol changes. Add nothing device-side.
- **App:**
  - Extend `KeyMonitor` to report key-up as well as key-down and to run in a
    shared "input observation" service so PRD-19 and this feature use one tap.
  - `TypingStats` — an actor owning the aggregates; updates are O(1) per event
    and flushed to disk on a timer, never per keystroke.
  - `ActuationAdvisor` — pure functions from `TypingStats` → `[Finding]`, unit
    tested against synthetic distributions.
  - `InsightsView` + heatmap modes on `KeyboardView` (already parameterised by
    `colorFor`).
- **Data model:** `~/Library/Application Support/ApexControl/typing-stats.json`,
  atomic write, schema-versioned, containing only per-key aggregates and
  histograms.

## 9. Edge cases & risks
- **Privacy is the whole risk.** Aggregates must be provably content-free; the
  review checklist is "could this file reconstruct anything I typed?" If a future
  feature wants sequences, it needs its own opt-in and its own PRD.
- **Multiple keyboards** — the tap sees every keyboard, so stats may include the
  laptop's built-in. Either filter (hard, see PRD-19 §12) or state it clearly.
- **Bad advice is worse than no advice.** The chatter threshold must be
  calibrated on real data before shipping; until then, findings ship behind a
  "beta" label and never auto-apply.
- **Repeat vs chatter**: holding a key produces OS auto-repeat, which must be
  excluded (auto-repeat events carry `kCGKeyboardEventAutorepeat`).
- **The key-event permission** (Input Monitoring or Accessibility) is shared with
  reactive lighting, and PRD-19 needs Accessibility itself; revoking it must
  degrade all three gracefully.
- Storage growth on a heavy typist; the rolling window and the visible size
  readout are the mitigation.

## 10. Acceptance criteria
- AC-1: With recording off, no tap is created and no file exists.
- AC-2: The stored file contains no field from which a typed word can be
  recovered (reviewed against a written checklist, and asserted in a test).
- AC-3: A synthetic stream with injected 15 ms repeats on one key flags exactly
  that key and no other.
- AC-4: Auto-repeat from a held key produces no chatter flag.
- AC-5: Applying a recommendation changes that key's actuation on hardware and
  is visible in the actuation heatmap.
- AC-6: Delete removes the file and resets the UI to the pre-opt-in state.

## 11. Effort & milestones
**M.** M1: shared input-observation service with key-up + auto-repeat filtering.
M2: `TypingStats` aggregates and storage with the privacy assertions. M3:
heatmap modes. M4: `ActuationAdvisor`, findings UI, apply + comparison.

## 12. Open questions
- What chatter threshold is actually correct for this switch? Needs a data
  collection round before any advice ships.
- Can we attribute events to this keyboard (shared question with PRD-19)? If
  not, is mixed-keyboard data still useful enough to act on?
- Should hold-duration data inform a *rapid trigger sensitivity* recommendation
  as well as an actuation one?
- Is a 30-day rolling window the right default, or should it be press-count
  based so light users still accumulate evidence?
