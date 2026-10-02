# PRD-17: Device State Read-Back & Sync

- **Priority:** P1
- **Status:** Partially implemented — button mappings read back on all three layers
- **Depends on:** — (foundational for PRD-01, PRD-04, PRD-05, PRD-06)
- **Firmware basis:** the binding read-back (`0xB6`, all three layers), the macro
  read-back (`0xB7`), the onboard-profile reads for the schema-8, 6 and 3 layouts,
  the region (`0xF5`) and layout (`0xF2`) reads; FlashFS read `0x83 01 <id> <u16 size> <u32 offset>`.

## 1. Summary
Apex Control reads the key bindings back on connect, and the boot profile in slot 0
(adopting its actuation, rapid tap and Fn key when the app holds no settings of its
own); for everything else it shows its *own* defaults, not what is actually stored on
the keyboard. This PRD adds a full read/parse layer that reads the device's real state
on connect and reflects it: current per-key bindings, second-actuation bindings,
stored macros, the 5 onboard profiles' contents, and region/layout. It enables an
"Import from Keyboard" action, keeps the UI honest, and provides the round-trip
verification that PRD-05's flash writes depend on.

## 2. Background & GG parity
As far as we know, GG reads the keyboard on launch and shows what is genuinely on it,
and keeps in step when something changes on the keyboard itself. Apex Control reads
the key bindings back on connect and the boot profile in slot 0 (adopting its actuation,
rapid tap and Fn key when the app holds no settings of its own), but reads nothing
else and does not listen for changes made on the keyboard, so after
a user tweaks the board with other software — or on a second app launch — our UI can
silently disagree with hardware. Read-back is the quiet foundation under remapping
(PRD-01), macros (PRD-04), persistence (PRD-05), and profiles (PRD-06).

## 3. Technical basis (grounded)
- **Read commands** (the `0xB6` binding reads on all three layers are confirmed on
  hardware; the rest are from descriptor):
  - Binding read-back — Feature request `00 B6 <layer> <count> [hid,0,0,0,0,0]…`,
    returns 6-byte mapping blocks (`hid, function, key_codes[4]`) per key.
    `layer 0x00` = primary, `0x01` = meta/Fn (PRD-02).
  - The same request at `layer 0x02` reads the second-actuation bindings, over the
    68 analog keys (the second-actuation layer exists on this model).
  - Macro read-back — the 9600-byte macro region, chunked with `0xB7 <u16
    offset-events> <u16 length-events>` (PRD-04).
  - Onboard-profile read (schema 8, slots 0–4) — the full profile image for
    each of the 5 slots.
- **FlashFS read op (confirmed on hardware).** Profile reads use
  `83 01 <id> <u16 size> <u32 offset>` (Feature: write the request, then read the
  reply), the read twin of PRD-05's write `03 01` / erase `02 01`;
  `id = 0x80 + slot`. Chunk size is **500 bytes**, so the ~12 KB schema-8 image reads
  in ~25 chunks, paced with the same ~13 ms inter-chunk delay PRD-05 uses
  (`OnboardProfile.interChunkDelay`). A full slot-0 read parses and its CRC matches
  (`docs/PROTOCOL.md`); `ApexDevice.readOnboardProfile(slot:)` and
  `apexctl profile read` implement it.
- **Region / layout (confirmed on hardware — already in the app).** `F5` → `F5
  <err> <region_id>`; `F2` → `F2 <err> <layout_id>` (0=US,1=EU,2=JP). This PRD
  extends the existing query layer, not replaces it.
- **Schema detection (slot images confirmed on hardware; other schemas from
  descriptor).** Every slot image carries two schema numbers — profile schema 3 and
  device schema 8 (firmware ≥ 1.19.0) — and `OnboardProfile.Image` refuses anything
  else. Other firmware generations use other device schemas (from descriptor: 6, and a
  legacy layout); none of them is modelled here. Refuse to parse a blob whose schema
  we don't model.
- **Parsing must mirror the writer.** The schema-8 image is the layout in
  `docs/PROTOCOL.md` (schema number, name, lighting block, bindings, actuation, OLED
  bitmap, rapid tap, macro region, GUID, then the trailing CRC) — the same layout
  PRD-05 serializes, read in the opposite direction.
- **Sync-on-change pattern (from descriptor; *needs RE* for the exact trigger).** A
  `0x03` change notification on `0xFFC1` (event type `2` = assign, `4` = delete) is
  the likely cue to re-read mappings and macros, and `0x02` a profile switch — the
  basis for a live "keep in sync" listener (cross-ref the
  `0xFFC1` work in PRD-14, which lists the notification formats seen in captures; the
  `0x03` payload is not among them yet).
- **Confidence:** the `0xB6` reads and the FlashFS read of a slot image are
  *confirmed on hardware*, including the image layout and CRC
  (`docs/PROTOCOL.md`); the `0xB7` macro read, the other schemas, the empty-slot
  sentinel and the sync trigger are from descriptor and need on-hardware validation
  before the parsed values drive the UI.

## 4. Goals / Non-goals
- **Goals:** a read/parse layer in ApexKit mirroring the write structs; a
  sync-on-connect flow that reflects real device state; an explicit "Import from
  Keyboard" action; conflict handling when device state and app state differ; a
  reusable read-back/verify hook for PRD-05; a subtle "synced with keyboard" status.
- **Non-goals:** writing anything (that is PRD-01/04/05); firmware update (PRD-16);
  importing another program's settings files (not planned; see PRD-18 §4) — this is
  on-device state only.

## 5. User stories
- As a user, I open Apex Control and the UI already shows the actuation, lighting,
  and bindings that are actually on my keyboard, not blank defaults.
- As someone who configured the board in GG, I click "Import from Keyboard" and get
  my 5 onboard profiles pulled into the app to edit.
- As a developer, I use read-back to prove a PRD-05 write byte-matches what I sent.
- As a user who changed a setting on the keyboard itself, I see the app notice and
  offer to refresh rather than silently overwrite it.

## 6. Functional requirements
- FR-1: On connect, read region, layout, primary + meta + second-actuation bindings,
  the macro region, and the active onboard profile; populate the UI from them.
- FR-2: Parse each read into the same models the write path uses (bindings, macros,
  `OnboardProfile`), keyed by schema (8/6/legacy), refusing unknown schemas.
- FR-3: An **"Import from Keyboard"** action that reads all 5 onboard slots and
  materializes them as editable profiles (PRD-06).
- FR-4: A `verify(slot:)` that reads a slot back and byte-compares against a blob —
  the primitive PRD-05 gates its writes on.
- FR-5: Conflict handling — when read-back differs from unsaved app state, present a
  clear choice (keep app / adopt device) rather than silently discarding either.
- FR-6: Handle uninitialized/empty slots (e.g. all-`0xFF`) as "empty," not corrupt.
- FR-7: A non-blocking status indicator reflecting in-sync / reading / diverged.

## 7. UX / UI design
- A subtle **"Synced with keyboard"** indicator in the toolbar (with reading and
  "diverged" states), not a modal.
- An **Import from Keyboard** action (Profiles pane + File menu) with per-slot
  progress and a summary of what was found.
- A **conflict sheet** when device and app disagree: side-by-side summary and
  keep-app / adopt-device actions; never auto-resolve destructively.

## 8. Technical design
- **ApexKit:** a `DeviceReadback` module — `readButtonMappings(layer:)`,
  `readSecondActuationMappings()`, `readMacroData()`, `readProfile(slot:)` built on
  the `0x83 01` FlashFS read and the `0xB6`/`0xB7` chunked reads; parsers that are
  the exact inverse of PRD-05's serializers, sharing the struct definitions.
- **App:** a `SyncCoordinator` run on connect (throttled, off the main thread) that
  populates stores and raises conflicts; the Profiles/remap/macro views observe it;
  the "synced" indicator binds to its state.
- **Data model:** reuse `LightingConfig`, `ActuationConfig`, mappings (PRD-01),
  macros (PRD-04), `OnboardProfile` (PRD-05); add a `DeviceSnapshot { region,
  layout, activeSlot, slots[5], bindings, macros }` and a `SyncState` enum.

## 9. Edge cases & risks
- **Parse drift:** a wrong offset silently mis-reads settings; validate against
  known-good captures and gate UI adoption on the round-trip diff passing.
- **Schema mismatch:** older FW exposes schema 6/legacy — detect and either map or
  decline, never mis-parse as schema 8.
- **Empty slots:** distinguish never-written (`0xFF`/blank) from genuine data so the
  UI doesn't show garbage as a "profile."
- **Long reads:** ~25 chunks/slot × 5 slots is slow; keep the inter-chunk delay,
  read lazily/on demand where possible, and never block the UI.
- **Mid-read disconnect:** treat a partial read as "unknown," not as truth; retry or
  fall back to app defaults without corrupting state.
- **Read/write interleave:** these are request-then-reply pairs on the same control
  pipe as the writes, and must not race a PRD-05 write — serialize device access.

## 10. Acceptance criteria
- AC-1: With a keyboard configured in GG, connecting Apex Control shows matching
  actuation, bindings, and lighting without any manual step.
- AC-2: "Import from Keyboard" yields 5 profiles whose summaries match the board.
- AC-3: `verify(slot:)` returns true for a freshly written slot and false for a
  deliberately corrupted one (shared with PRD-05 AC-2/AC-3).
- AC-4: Changing a binding on the keyboard and reconnecting surfaces a conflict
  rather than a silent stale UI.
- AC-5: An empty slot is reported as empty, never as corrupt or as random data.

## 11. Effort & milestones
**M–L.** M1: FlashFS read + `0xB6`/`0xB7` chunked reads in ApexKit with a raw-dump
harness. M2: schema-8 parsers mirroring PRD-05 structs, validated by byte diff.
M3: sync-on-connect + "synced" indicator. M4: Import from Keyboard + conflict UI.

## 12. Open questions
- What does an empty or never-written slot look like on real hardware? (The schema-8
  field offsets are already confirmed on slots 0 and 4 — see `docs/PROTOCOL.md`.)
- Must the profile-volatility command be toggled around reads?
- Which reads are cheap enough for every connect vs. deferred to explicit Import?
- Should the sync listener consume `0xFFC1` notifications now (overlaps PRD-14) or
  stay poll/connect-only for v1?
