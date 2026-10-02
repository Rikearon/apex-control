# PRD-04: Macro Engine

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** PRD-01 (remap path for assignment), PRD-05 (onboard storage)
- **Firmware basis:** binding write with fn `0x71` (MACRO), inline macro write `0x00 0x37`,
  the macro read-back (`0xB7`), the onboard macro region (9600 B) inside the
  schema-8 onboard profile image; no standalone live macro-deploy command.

## 1. Summary
Apex Control cannot record, store, or fire keystroke macros. This PRD adds a macro
engine: the host records key events with timing (via a `CGEventTap`, the same
Accessibility path reactive lighting already uses), lets the user edit the event
list, and assigns a macro to a key through a **MACRO (`0x71`) binding** (PRD-01).
Because this firmware has **no standalone live macro-deploy command**, a macro
only *runs* once it lives inside the onboard profile blob's 9600-byte macro region —
so durable macros ride the PRD-05 flash write. A host-side macro library holds macros
independently of what is on the board.

## 2. Background & GG parity
As far as we know, GG ships a macro editor: record a sequence, see it as a timeline of key-down /
key-up events with delays, edit those delays (recorded vs. fixed), pick a playback
mode (once, repeat-while-held, toggle), and bind it to any key. Users automate
combos, text strings, and repetitive inputs. Without macros Apex Control has no
automation story at all.
The keyboard runs the macro itself once stored, so it works with the app closed.

## 3. Technical basis (grounded)
- **Onboard region.** The profile image contains a 9600-byte macro region (from
  descriptor; the 9600-byte region is confirmed in the flash image layout in
  `docs/PROTOCOL.md`). This is the *entire*
  macro budget for the slot, shared across every macro bound in that profile.
- **No live-only path (confidence: from descriptor).** The firmware exposes no
  independent "deploy this macro live" command. Macro bytes travel as chunks
  *inline in the `mappings` write* —
  `00 37 <u16 offset-in-events> <u16 length-in-events> <data…>` (Feature, alongside
  the `0x36` binding chunks) — and only survive power-loss inside the onboard
  profile (§A.1 live-vs-onboard split). ⇒ full macro function depends on **PRD-05**.
- **Event size (from descriptor).** All offset/length arithmetic is in *events =
  bytes ÷ 4*, so a macro event is **4 bytes** (a key/button event plus its
  delay/timing). Total budget = 9600 B ÷ 4 = **2400 events** per profile.
- **Chunking (from descriptor, computed).** The chunk size is the largest
  factor of 2400 events that fits `(report size − 6) ÷ 4 = (645 − 6) ÷ 4 =
  159` events per report → **150 events = 600 bytes**, so the region streams in
  **16 chunks**. Read-back uses the same chunking with command `0xB7`.
- **Assignment (from descriptor + needs RE).** A key is mapped to a macro with a
  6-byte mapping block (`hid, function, key_codes[4]`) whose `function = 0x71`
  (MACRO) — the function value is confirmed; how the macro *id/reference* is
  packed into the 4 `key_codes` bytes is not spelled out and needs RE. Assignment
  therefore reuses the PRD-01 remap write.
- **Per-event byte layout — the main unknown (needs RE).** The concrete encoding
  of each 4-byte event (event type, HID/button code, delay units) is not described:
  the descriptor treats the macro region as an opaque byte array, so the layout must be
  reverse-engineered from USB captures of our own keyboard and proven by read-back
  diff.
- **Confidence:** region size, budget, `0x37`/`0xB7`/`0x71` and 4-byte event size
  are from the descriptor; the per-event bit layout and macro-id packing are the
  parts to prove on hardware first.

## 4. Goals / Non-goals
- **Goals:** record key events with real timing; an editable event timeline
  (insert / remove / reorder / adjust delay; per-event fixed-vs-recorded timing);
  playback modes (once / repeat-while-held / toggle); a host-side macro library;
  assign a macro to a key via a `0x71` binding; persist onboard through PRD-05;
  surface the 9600-byte budget so users never silently overflow.
- **Non-goals:** the flash-write mechanics themselves (PRD-05); the general remap
  UI (PRD-01); recording raw mouse *movement* paths (key/button events only);
  cross-model macro portability.

## 5. User stories
- As a gamer, I record a "cast → swap → cast" combo and bind it to a side key so
  it fires on a single press, with the app closed.
- As a writer, I capture a text string with human-looking delays and toggle it on.
- As a tinkerer, I open a recorded macro, delete the accidental extra keypress,
  and set every delay to a fixed 20 ms.
- As a user near the limit, I see "7,800 / 9,600 bytes used" before I save and
  trim a macro rather than getting a rejected write.

## 6. Functional requirements
- FR-1: Record key-down/key-up events with millisecond timing via `CGEventTap`
  (Accessibility permission), with an explicit start/stop and a visible indicator.
- FR-2: Represent a macro as an ordered event list; allow insert, delete, reorder,
  and delay edit; each event's timing is either *recorded* or a *fixed* value.
- FR-3: Playback mode per macro: **once**, **repeat-while-held**, **toggle**
  (start on press, stop on next press).
- FR-4: A host-side macro library (create, rename, duplicate, delete) that persists
  on the Mac independently of the keyboard's contents.
- FR-5: Assign a library macro to a key by writing a `0x71` MACRO mapping block
  via the PRD-01 remap path.
- FR-6: Enforce and display the **2400-event / 9600-byte** onboard budget per
  profile — per-macro size and the profile total — and block a save that exceeds it.
- FR-7: Durable storage is via PRD-05 (the macro region is serialized into the
  onboard profile blob and verified by read-back); never claim a macro is "on the
  keyboard" until a profile write + verify has succeeded.

## 7. UX / UI design
- A **Macros** pane: left, the library list with sizes; right, the selected
  macro's editor.
- Editor: a big **Record** button (with the Accessibility-permission prompt/empty
  state), then an **event timeline** — one row per event (▼/▲ key-down/up, key
  name, delay field, timing-mode toggle) that can be edited and reordered.
- A **playback-mode** selector and an **Assign to key…** action (opens the PRD-01
  key picker).
- A **budget meter** ("used / 9,600 bytes") for the active profile, turning red on
  overflow, with per-macro contribution shown.

## 8. Technical design
- **ApexKit:** a `Macro` module — `Macro` (Codable: `[MacroEvent]`, `playback`),
  `MacroEvent { type, code, delayMs, timingMode }`; `serializeMacros(_:) -> [UInt8]`
  packing the shared 9600-byte region (encoding is the RE target) and `chunk()` /
  `parseMacroRegion(_:)` mirrors for PRD-17; assignment via the PRD-01
  `buttonMapping(function: 0x71, …)` builder.
- **App:** a `MacroLibraryStore` (host-side, `Codable` on disk); a `Macros` view
  driving record/edit/assign; a `MacroRecorder` wrapping `CGEventTap`; the onboard
  serialization is handed to `ProfileStore`/`OnboardProfile` (PRD-05) at save time.
- **Data model:** `Macro`, `MacroEvent`, `PlaybackMode`; the onboard region is a
  field of the schema-8 `OnboardProfile` (PRD-05); key→macro links live in the
  mappings model (PRD-01).

## 9. Edge cases & risks
- **Unknown event encoding:** the highest-risk item; gate everything behind a
  read-back diff harness (write region → macro read-back → byte-compare) before
  trusting playback.
- **Budget overflow:** two big macros can exceed 9600 B together; validate the
  *profile total*, not just one macro, and fail closed.
- **Flash wear:** macros only reach the board through a PRD-05 flash write — never
  auto-save on each keystroke edit; write on explicit "Save to Keyboard" only.
- **Runaway playback:** repeat-while-held / toggle must have a firmware- or
  host-side stop; document behavior if a bound key is itself remapped or disabled.
- **Permission:** no Accessibility grant ⇒ recording is unavailable; show the same
  guided prompt reactive lighting uses, and allow manual event entry without it.
- **Timing fidelity:** confirm whether the firmware or the host owns playback timing
  and what delay unit the 4-byte event uses (open question).

## 10. Acceptance criteria
- AC-1: A recorded macro round-trips: written into a profile, the macro read-back
  returns byte-identical data.
- AC-2: A key bound with `function = 0x71` fires the assigned macro on the physical
  keyboard with the app closed (after a PRD-05 save).
- AC-3: Editing a delay and re-saving changes the observed inter-key timing.
- AC-4: A macro set exceeding 9600 B is rejected before any write, with a clear
  budget error.
- AC-5: repeat-while-held stops when the key is released; toggle stops on second press.

## 11. Effort & milestones
**L.** M1: host recorder + library + event-timeline editor (no device I/O).
M2: RE the 4-byte event encoding + macro-id packing, prove with a read-back diff
harness on hardware. M3: assignment via the PRD-01 `0x71` write. M4: onboard
persistence + budget integration through PRD-05.

## 12. Open questions
- Exact per-event byte layout (event-type/code/delay fields) and the delay unit?
- How is a macro id referenced inside a `0x71` mapping's `key_codes[4]`?
- Is there a per-macro event cap distinct from the 2400-event profile budget?
- How are repeat count / toggle semantics encoded — in the event stream or the
  binding — and does the firmware or the host drive playback timing?
