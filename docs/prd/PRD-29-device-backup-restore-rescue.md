# PRD-29: Device Backup, Restore & Rescue Mode

- **Priority:** P0
- **Status:** Proposed
- **Depends on:** — **and PRD-05 should depend on this**, not the other way round
- **Firmware basis:** the binding read-back on all three layers (`0xB6`; implemented,
  hardware-verified), the macro read-back (`0xB7`), the onboard-profile reads
  (schema 3 / 6 / 8).

## 1. Summary
Apex Control can now write things into the keyboard that outlive the app —
bindings and flashed profile images today, macros tomorrow. It has no way to
capture what was there first. This PRD adds a complete, restorable snapshot of the
*device's own* state, taken before we change anything, plus a rescue path for a
keyboard that has been configured into unusability.

## 2. Background & GG parity
As far as we know, GG offers no backup of the device's own state either; what it
keeps is its own configuration (in a cloud account), which is not the same thing and
does not help if the device is left in a strange state by another tool. The gap
became concrete during PRD-01's implementation: reading layer 1 revealed nine factory
Fn shortcuts (`function 0x62`) that **we know of no command to restore** — if a write had
blanked them, they would be gone unless a dump existed. We added guards, but guards are not a backup.
And PRD-05 has since started writing *flash* (slot 0, read-modify-write, verified by
read-back), where the same mistake is permanent and reaches the profiles a user may
have spent hours on. Those guards are still not a copy the user can go back to.

The backup should have come before the flash write, not after it.

## 3. Technical basis (grounded)
- **Bindings** — all three layers read back reliably (verified on firmware
  1.19.7; `docs/PROTOCOL.md` §Reading bindings back). This is the part we know
  works.
- **Onboard profiles** — the schema-8 slot image reads back over the flash
  filesystem (`83 01`, 500-byte chunks). Confidence: *confirmed on hardware* for
  slot 0 (a full read parses and its CRC matches) and for the slot-4 write/read round
  trip (`docs/PROTOCOL.md` §Onboard profiles), and implemented as
  `ApexDevice.readOnboardProfile(slot:)` and `apexctl profile read`. The descriptor
  also lists read endpoints for other schema versions; those are *from descriptor*
  and unexercised. Reading is
  strictly safer than writing, and the app already reads slot 0 before every write.
- **Macros** — the macro read-back (`0xB7`) returns the full 9 600-byte macro region in
  chunks. Confidence: from descriptor, untested.
- **Live actuation state is not readable.** There is no read counterpart to
  the threshold (`38 61`), release-mode (`38 62`) and sensitivity (`38 65`) commands, or
  the rapid-tap ones. A backup can capture what an *onboard profile* holds, and what *we*
  last wrote, but not the current volatile state. The format must be honest about
  which fields are observed and which are inferred.
- **Rescue** — `resetAllBindings()` already exists and is hardware-verified; the
  missing pieces are reachability (before the UI loads, without the UI, and
  without the app running) and a documented factory-ish baseline.

## 4. Goals / Non-goals
- **Goals:** a one-file snapshot of everything readable off the device; automatic
  snapshot on first ever connect, before the app writes anything; manual
  snapshots on demand; restore with a preview of what will change; a rescue mode
  that starts the app inert; a panic reset reachable from the menu bar, the CLI,
  and a global hotkey; snapshot-before-flash-write as a hard gate on PRD-05.
- **Non-goals:** restoring things the device will not report (volatile actuation);
  a full firmware image backup (PRD-16 territory, and not readable anyway);
  versioned history of snapshots beyond a small rolling set; syncing snapshots
  (PRD-26 syncs *configuration*, not device captures).

## 5. User stories
- As a new user, the app quietly saves what my keyboard was like before it
  touched anything, so I can always get back.
- As someone who broke their Fn layer experimenting, I restore last Tuesday's
  snapshot and my brightness keys work again.
- As a user about to write an onboard profile, the app takes a backup first and
  tells me it did.
- As someone whose keyboard is now typing the wrong letters, I hold a key while
  launching and the app starts without applying anything.
- As someone whose keyboard is unusable, one CLI command puts every key back.

## 6. Functional requirements
- FR-1: A **snapshot** captures: firmware version, region, layout, all three
  mapping layers, the meta-highlight state we can infer, macro data, and each
  readable onboard profile slot, with a per-section `observed | unavailable`
  marker.
- FR-2: A snapshot is taken **automatically on the first connect of a given
  device** (identified as in PRD-27) and stored as `first-seen`, never
  overwritten.
- FR-3: Manual "Take snapshot now" produces a timestamped file; a rolling limit
  (default 10) prunes oldest, never `first-seen`.
- FR-4: **Restore** shows a diff of what will change *before* writing, section by
  section, and lets the user restore a subset (e.g. only the Fn layer).
- FR-5: Restore only writes sections marked `observed`; it must never write
  zeros for a section it could not read.
- FR-6: **Snapshot before flash**: any onboard-profile write (PRD-05) refuses to
  proceed unless a snapshot of that slot exists or the user explicitly overrides.
- FR-7: **Rescue mode**: holding a modifier during launch (and a
  `--safe` CLI flag) starts the app connected but **inert** — no apply on
  connect, no effects, no OLED writes — with a banner explaining and a Restore
  action prominent.
- FR-8: **Panic reset** available from: the menu bar, `apexctl reset-bindings`,
  and a user-configurable global hotkey; it resets the normal and second-actuation
  layers and, on confirmation, the Fn layer.
- FR-9: Snapshots are plain JSON with byte arrays in hex, documented well enough
  that a person could restore by hand.
- FR-10: A snapshot taken on one device must refuse to restore to a different
  model, and warn when restoring to a different unit of the same model.

## 7. UX / UI design
- A **Device** section in Settings: "Snapshots" list (date, firmware, size,
  sections captured), with Take, Restore…, Reveal in Finder, Delete.
- Restore opens a sheet with a section list, each showing a plain summary
  ("Fn layer: 9 firmware shortcuts, 2 custom") and a checkbox, plus a warning
  when a section is unavailable.
- **First-run:** a single unobtrusive note the first time a snapshot is taken —
  "Saved a copy of your keyboard's original setup" — with a link to it.
- **Rescue banner:** persistent, orange, with "Restore a snapshot", "Reset
  bindings", and "Exit rescue mode".

## 8. Technical design
- **ApexKit:**
  - Macro read-back (`0xB7`) builders and parsers, and multi-slot use of the
    existing `readOnboardProfile(slot:)` with its inter-chunk pacing.
  - `DeviceSnapshot` — `Codable`, with `Section<T> { value: T?, status:
    observed/unavailable/failed }` so absence is explicit.
  - `ApexDevice.captureSnapshot()` and `restore(_:sections:)`.
- **App:** `SnapshotStore` (list, prune, protect `first-seen`), a restore sheet,
  and the rescue-mode flag wired into `AppEnvironment.bootstrap()` so it
  short-circuits `applyAll()`.
- **Data model:** `~/Library/Application Support/ApexControl/Snapshots/<deviceID>/`,
  one JSON per snapshot.

## 9. Edge cases & risks
- **A partial read must never become a destructive write.** This is the central
  risk: a snapshot with a silently truncated section, restored later, would wipe
  what it failed to capture. Hence FR-1's per-section status and FR-5.
- **Flash reads are not free** — a full slot read is ~25 chunk round trips, about a
  second of control-pipe traffic (`ApexDevice.readOnboardProfile`); snapshots should
  not be automatic on every connect, only the first.
- **Restoring to the wrong unit** is easy with two identical keyboards and no
  serial number; FR-10's warning is the only defence.
- **Rescue mode must work when the UI is broken**, so the CLI path must not
  depend on the app running or on any saved state being readable.
- **Global hotkey conflicts** — a panic hotkey that shadows a system shortcut is
  its own problem; default to unset and let the user choose.
- **Snapshot size**: five onboard profiles at ~12 KB plus 9.6 KB of macro data is
  ~80 KB per snapshot — negligible, but the rolling limit keeps it tidy.

## 10. Acceptance criteria
- AC-1: First connect on a clean install produces a `first-seen` snapshot
  containing all three mapping layers with status `observed`.
- AC-2: Deliberately clearing the Fn layer, then restoring that snapshot's Fn
  section, returns all nine firmware shortcuts, verified by read-back.
- AC-3: A snapshot section that fails to read is marked `unavailable` and is not
  offered for restore.
- AC-4: `apexctl --safe` (or launching in rescue mode) connects and writes
  nothing to the device — verified by a traffic log showing no writes.
- AC-5: The panic hotkey restores normal typing on a keyboard whose every key
  was disabled.
- AC-6: Restoring a snapshot to a different model is refused with a clear reason.

## 11. Effort & milestones
**M.** M1: snapshot of the three mapping layers (all commands already work) +
store + restore with diff. M2: rescue mode and the panic paths. M3:
the macro read-back. M4: snapshots of all five onboard slots (the slot read itself is
already implemented) and the snapshot-before-flash gate for PRD-05.

## 12. Open questions
- Do slots 1–3 read back the same way on a factory unit? (Slots 0 and 4 are
  confirmed on firmware 1.19.7; see `docs/PROTOCOL.md`.)
- Should the volatile actuation state be *inferred* into the snapshot from what
  we last wrote (useful, but it is our record, not the device's), or omitted
  entirely for honesty?
- Is a modifier-at-launch rescue trigger discoverable enough, or should there be
  a visible "Safe mode" item in the menu bar?
- How should snapshots interact with PRD-27 multi-device identity when a keyboard
  moves between USB ports?
