# PRD-06: Profile System & Switching

- **Priority:** P0
- **Status:** Implemented — software profiles, slot switching, import/export
- **Depends on:** 05 — onboard flash write/read (this PRD *calls* it, does not define it); unblocks 07
- **Firmware basis:** the profile-load command (Output `B2 <id>`, id 0–4), the profile-volatility command
  (Output `34 <0/1>`); onboard flash writes delegated to PRD-05; software profiles are
  **host-side only** (Codable JSON, no wire protocol).

## 1. Summary
Apex Control holds every setting in a single in-memory `DeviceController` that is
discarded on quit — there is no notion of a saved, named configuration. This PRD adds
a **two-tier profile system**: (a) unlimited **software profiles** — named JSON
snapshots of the *entire* app state stored on the Mac, and (b) the keyboard's **5
onboard hardware slots** (written via PRD-05, switched with the profile-load command). It is the
container that persistence (PRD-05) and per-app automation (PRD-07) plug into.

## 2. Background & GG parity
As far as we know, GG gives the user a library of named profiles they can create, edit, duplicate, and
switch between, a mapping of those profiles onto the keyboard's 5 onboard slots, and
import/export for sharing. Apex Control today has none of this: change a slider and
quitting the app throws it away; there is no library, no export, no "work" vs "game"
setup. Users expect a configurator to *remember* configurations and let them move
between them with one click. Without this tier, every other feature (lighting,
actuation, macros, OLED) is a transient live tweak rather than something the user owns
and can name, back up, and share.

## 3. Technical basis (grounded)
Two independent mechanisms, cleanly separated:

- **Software profiles (host-side, high confidence).** A `SoftwareProfile` is a
  `Codable` struct serialized to JSON under `~/Library/Application Support/…`. No
  firmware involvement — standard `FileManager` + `Codable`. Count and size are bounded
  only by disk; import/export is copying a JSON file.
- **Applying a software profile = pushing live settings** over the existing,
  hardware-verified live commands: lighting `40` (`docs/PROTOCOL.md` §Lighting),
  actuation `38 61`, rapid-trigger `38 62`/`38 65`, rapid-tap `38 66`/`38 67`, OLED
  `1F 81`/`38 83`, and key mappings (PRD-01). All are already implemented or specified —
  *apply* is orchestration, **not** new protocol.
- **Onboard slot switch:** the profile-load command — Output `B2 <id>`, `id` 0–4, no reply
  (`docs/PROTOCOL.md` §Queries, confirmed on hardware). A builder already exists in
  ApexKit.
- **Volatile vs sticky:** the profile-volatility command — Output `34 <0/1>`. A builder exists
  in ApexKit and the endpoint is listed among the device's endpoints
  (`FEATURE-GAP-ANALYSIS §B`), **but `0x34` is not in the byte-verified table in
  `docs/PROTOCOL.md`**, and which argument value means "revert on power cycle" vs
  "stick" is unconfirmed. Confidence: **needs on-hardware validation**; treat the
  argument direction as an open question (§12) and default to the safe, observable
  behavior.
- **Writing a software profile *into* an onboard slot** is the schema-8 flash write
  owned by **PRD-05**. This PRD only calls `ProfileStore.onboardBlob(for:)` →
  `ApexDevice.writeProfile(slot:)`; it defines **no** flash bytes.
- **Unknown:** no documented query reports *which* onboard slot is currently active;
  reflecting the true active slot depends on the `0xFFC1` input-report listener
  (PRD-14) or a read-back (PRD-17). Until then the app tracks the last slot it
  commanded.

## 4. Goals / Non-goals
- **Goals:**
  - Create, rename, duplicate, and delete **software profiles** (unlimited).
  - **Apply** a software profile: push its full state live (lighting + actuation +
    rapid trigger + rapid tap + bindings + macros + OLED).
  - **Map** software profiles onto the 5 onboard slots and trigger a PRD-05 flash write.
  - **Switch** the active onboard slot (`B2`) and expose the volatile/sticky
    choice.
  - **Import / export** a software profile as a portable JSON file.
  - A **Profiles pane**: software-profile list + editor + 5 onboard slot cards.
- **Non-goals:**
  - The onboard flash-write byte format and CRC (PRD-05).
  - Per-application automatic switching (PRD-07) — this PRD only exposes the manual
    switch primitive it builds on.
  - Importing SteelSeries GG's own stored profiles (not planned; see PRD-18 §4).
  - Cross-model profile portability.

## 5. User stories
- As a user, I save my current lighting/actuation as "Work" and another as "CS2" and
  switch between them from a list with one click.
- As a competitor, I duplicate "CS2", nudge the actuation, and keep both — without
  clobbering the original.
- As a user, I map "CS2" onto onboard slot 1 so it lives on the keyboard (PRD-05), then
  flip the keyboard to that slot.
- As a user, I export "CS2" to a `.json` file and send it to a teammate, who imports it
  and gets my exact setup.
- As a user, I rename and delete profiles I no longer use, and the app remembers my
  library across restarts.

## 6. Functional requirements
- FR-1: A `SoftwareProfile` captures the full app state — lighting config, per-key
  actuation, rapid trigger, rapid tap, key mappings, macros, OLED image — plus metadata
  (stable `id`, name, created/modified dates, schema version). Fields for
  not-yet-built subsystems (PRD-01 bindings, PRD-04 macros) are
  **optional/forward-compatible** so older *and* newer files still load.
- FR-2: Create a profile from current live state ("Save current as…"), and create an
  empty/default profile.
- FR-3: Rename, duplicate (new `id`, copied contents), and delete, with a confirm on
  delete.
- FR-4: **Apply** pushes every subsystem's live command in a defined, idempotent order;
  a **full** lighting frame is sent (per §Lighting, partial frames leave stale keys).
  Applying is safe to repeat.
- FR-5: Persist the library to `Application Support` as JSON; load on launch; survive
  restart. Writes are **atomic** (temp-file + rename) so a crash cannot corrupt the
  library.
- FR-6: Maintain an **onboard slot map** (slot 0–4 → software-profile `id`, or empty).
  "Write to slot N" hands the mapped profile to PRD-05's flash writer.
- FR-7: Switch the active onboard slot via the profile-load command (`B2 <id>`), `id` constrained
  to 0–4 before any USB write.
- FR-8: Expose the **volatile/sticky** choice via the profile-volatility command (`34 <0/1>`),
  with copy explaining the effect; default to whichever value is verified
  non-destructive (§12).
- FR-9: Export a profile to a chosen `.json`; import a `.json`, validating schema and
  assigning a fresh `id`; reject malformed files with a clear error (never crash).
- FR-10: Track and display the currently *applied* software profile and the
  last-commanded onboard slot; mark a profile "modified" when live state diverges from
  it.

## 7. UX / UI design
- A new **Profiles** pane (also home to PRD-05's slot actions and PRD-07's Automation
  section), in two columns:
  - **Left — Software profiles:** a reorderable list; each row shows name + a one-line
    summary (actuation mm, effect name, OLED on/off). Toolbar: `+` (new), duplicate,
    delete, import, export. Selecting a row loads it into the editor; a clear **Apply**
    button pushes it to the keyboard. The applied profile is badged; a profile edited
    since it was applied shows a "modified" dot.
  - **Right — Onboard slots:** 5 cards (slots 0–4), each showing the mapped profile's
    name (or "Empty"), with *Assign profile…*, *Write to keyboard* (→ PRD-05),
    *Switch to this slot* (`B2`), and a **Volatile / Sticky** toggle.
- **Empty state:** first launch auto-creates one "Default" profile seeded from current
  live settings, so the list is never blank.
- **Error/edge states:** import failure shows the reason inline; switching to a slot the
  app believes is empty warns first; a "modified" profile prompts
  "Apply / Save changes / Discard" when switching away.

## 8. Technical design
- **ApexKit:**
  - Reuse the existing profile-load (`B2`) and profile-volatility (`34`) builders;
    add `ApexDevice.loadProfile(_ id: UInt8)` and `setProfileVolatile(_:)` wrappers with
    `id` range-checked to 0…4.
  - No new wire protocol here; the flash write path lives in PRD-05.
- **App:**
  - `ProfileStore` — `@MainActor ObservableObject` owning `[SoftwareProfile]`, the
    onboard slot map, the applied/active selection, JSON persistence, and import/export.
    This is the exact `ProfileStore` referenced by PRD-05 §8: it supplies
    `onboardBlob(for:)` mapping a `SoftwareProfile` → `OnboardProfile`.
  - `DeviceController` gains `apply(_ profile: SoftwareProfile)` sequencing the live
    pushes, and `captureCurrent() -> SoftwareProfile`.
  - `ProfilesView` (list + editor + slot cards) added to the pane set.
- **Data model:**
  ```
  struct SoftwareProfile: Codable, Identifiable {
    let id: UUID
    var name: String
    var schemaVersion: Int
    var createdAt, modifiedAt: Date
    var lighting: LightingConfig
    var actuation: ActuationConfig
    var rapidTrigger: RapidTriggerConfig?
    var rapidTap: RapidTapConfig?
    var bindings: KeyMap?          // PRD-01
    var macros: [Macro]?           // PRD-04
    var oledImage: OLEDBitmap?
  }
  struct OnboardSlotMap: Codable { var slots: [UUID?] }   // count 5, slots 0–4
  ```
  - **Storage:** `~/Library/Application Support/ApexControl/profiles.json` (single file,
    atomic write) or one file per profile under `…/Profiles/` — decided in §12.
    `schemaVersion` gates forward migration.

## 9. Edge cases & risks
- **Schema drift:** profiles written by a newer build must load (ignore unknown keys)
  and older ones must upgrade; `schemaVersion` + optional fields + a migration step
  guard this. A hand-edited/corrupt JSON must fail soft (skip that file, surface an
  error), never crash the store.
- **Onboard/flash divergence:** the app cannot cheaply know what's *actually* in a flash
  slot (no active-slot query — PROTOCOL.md); the slot map is the app's *intent*, and a
  mismatch (e.g. a slot rewritten by GG) is possible until PRD-17 read-back exists. UI
  copy must not over-promise.
- **Apply atomicity:** applying is several USB writes; a mid-apply disconnect leaves a
  partial live state — detect the transport error, stop, and mark the profile *not fully
  applied* rather than showing it as active.
- **Volatile semantics unverified:** the profile-volatility command (`0x34`) with the wrong argument
  could make an onboard switch unexpectedly permanent or transient; gate behind
  on-hardware validation and a clear toggle (§12).
- **Deleting an applied/mapped profile:** must not leave a dangling slot-map entry or a
  phantom "applied" badge — clear references and confirm.
- **No flash wear here:** applying/duplicating/switching software profiles never writes
  flash; only the explicit "Write to keyboard" (PRD-05) does. Keep that boundary strict
  so casual profile editing never wears the keyboard.

## 10. Acceptance criteria
- AC-1: Creating "Work" and "CS2", quitting, and relaunching restores both with their
  exact settings from JSON.
- AC-2: Applying "CS2" changes the keyboard's lighting **and** actuation to match that
  profile (verified live), and re-applying is visually a no-op.
- AC-3: Duplicating a profile and editing the copy leaves the original byte-identical.
- AC-4: Exporting a profile and importing it into a fresh library reproduces identical
  settings with a new `id`.
- AC-5: The profile-load command to slot N switches the keyboard's active onboard profile
  (observable on hardware); an out-of-range id is rejected before any USB write.
- AC-6: A malformed imported JSON produces a clear error and leaves the existing library
  intact.

## 11. Effort & milestones
**M.** M1: `SoftwareProfile` model + `ProfileStore` with atomic JSON persistence and
CRUD. M2: `apply()` orchestration over live commands + `captureCurrent`. M3: Profiles
pane UI (list + editor). M4: onboard slot map + profile-load switch + volatile toggle
+ import/export. (Flash write itself is PRD-05; per-app automation is PRD-07.)

## 12. Open questions
- The profile-volatility command (`34 <0/1>`): which argument is volatile vs sticky, and is it
  required around a profile load or an onboard write? Verify on hardware before
  shipping the toggle.
- Is there any way to query the *currently active* onboard slot, or must we rely on the
  `0xFFC1` listener (PRD-14) / read-back (PRD-17)?
- Single `profiles.json` vs one file per profile — which is friendlier for export,
  diffing, and iCloud/Git backup?
- Profile-schema migration policy: silent upgrade on load, or explicit versioned
  migrators?
- Should "Apply" also offer a "temporary preview" that auto-reverts, given
  lighting/actuation are live-volatile anyway?
