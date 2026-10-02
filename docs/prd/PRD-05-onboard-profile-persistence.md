# PRD-05: Onboard Profile Persistence

- **Priority:** P0 *(keystone)*
- **Status:** Partially implemented — the persistence core is done and
  **verified on hardware** (fw 1.19.7): `OnboardProfile` (ApexKit) reads,
  patches, CRCs, writes, and read-back-verifies the schema-8 slot image;
  the app auto-persists bindings + Fn key + actuation + rapid trigger +
  rapid tap into slot 0 after edits settle (`DeviceController.persistToKeyboard`),
  and `apexctl profile read|save|restore` is the CLI surface. Remaining:
  the "safe abort" path (FR-6, AC-4: a failed write can leave the slot erased, see
  KNOWN-ISSUES), multi-slot UI, slot naming, onboard *lighting* authoring (PRD-09
  territory), macros (PRD-04). See PROTOCOL.md §"Onboard profiles & the flash filesystem"
  for the byte-level truth.
- **Depends on:** — (unblocks 06, 07, 09, 10; consumed by 04)
- **Firmware basis:** the schema-8 onboard-profile write and read
  (device schema 8), the profile-volatility command (`0x34`), the profile-load
  command (`0xB2`); FlashFS ops `0x02 01` (erase) / `0x03 01` (write) / `0xB1`
  (validate).

## 1. Summary
Apex Control currently drives the keyboard *live*; its settings are volatile and
vanish when the keyboard is unplugged with no host, or when the keyboard loads an
onboard profile on power-up. This PRD adds the ability to serialize a full
configuration (lighting + all key mappings + actuation + rapid trigger + rapid tap
+ OLED image + macros) into one of the keyboard's **5 hardware profile slots**,
so the setup survives power loss and works on any computer with no software — true
parity with GG's "save to keyboard."

## 2. Background & GG parity
As far as we know, GG stores up to 5 profiles on the keyboard itself; users rely on this so their
competitive actuation/lighting works on a LAN machine or console with GG absent.
Without it, Apex Control is a "while running" utility, not a configurator. This is
the single most requested class of parity and the dependency for brightness/idle
(PRD-10), onboard effects (PRD-09), and portable profiles (PRD-06).

## 3. Technical basis (grounded)
- **Schema:** device profile **schema 8** (FW ≥ 1.19.0; our unit is 1.19.7). The
  flash image (~12 KB) holds, in order: a schema number, the 24-byte name, the 48-byte
  lighting block, the bindings (Fn key, normal layer, Fn layer), the actuation
  settings (including the second actuation point), the 640-byte OLED bitmap, the
  51-byte rapid-tap block, a 9600-byte macro region, a 16-byte GUID, and a trailing
  **STM32 CRC-32** (little-endian); the last write chunk is padded with `0xFF`. The
  byte offsets are in the layout table in `docs/PROTOCOL.md`.
- **Write sequence** (confidence: from descriptor; confirmed on hardware, fw 1.19.7 — see
  §12):
  1. Host-side pacing: allow a long timeout for the erase (not a wire packet).
  2. Output `02 01 <fs>` — erase the flash entry (`fs = 0x80 + slot`).
  3. Feature, in 500-byte chunks: `03 01 <fs> <u16 size> <u32 offset> <data…>`.
  4. Output `B1 <slot>` — validate/commit.
- **CRC** is computed over the payload (STM32 CRC-32); getting the polynomial/seed
  and the exact byte span right was the main correctness risk → validate by reading
  the slot back and byte-comparing.
- **Confidence:** command bytes and struct layout are from descriptor; the CRC and
  chunk offsets were the parts to prove on hardware first, and now are (§12).

## 4. Goals / Non-goals
- **Goals:** serialize current app state → schema-8 blob; write to a chosen slot
  (0–4); name the slot; verify by read-back; switch active slot; keep the keyboard
  usable (never leave it in a half-written state).
- **Non-goals:** firmware update (PRD-16); cross-model profile portability;
  editing another program's stored profiles.

## 5. User stories
- As a competitor, I save my 0.4 mm + rapid-trigger config to slot 1 so it works
  on a tournament PC with no software.
- As a user, I set my lighting + OLED image and "Save to Keyboard" so it persists
  after I quit the app and unplug.
- As a tinkerer, I read a slot back to confirm exactly what's stored.

## 6. Functional requirements
- FR-1: Assemble a schema-8 profile blob from the app's current lighting,
  mappings, actuation, rapid trigger, rapid tap, OLED image, and macros.
- FR-2: Compute the CRC and chunk the blob per the write sequence in §3.
- FR-3: Write to a user-selected slot 0–4 with a user-supplied name (≤24 bytes).
- FR-4: **Verify** by reading the slot back and comparing; surface a clear error
  and do not mark success on mismatch.
- FR-5: Switch the active onboard profile (`B2`) and honor
  the profile-volatility command (`0x34`) semantics.
- FR-6: A "safe abort" path — if a write fails mid-way, guide re-write; never
  claim success on a partial write.

## 7. UX / UI design
- A **Profiles** pane (shared with PRD-06): 5 slot cards showing name + a summary
  (actuation, effect, has-OLED). Actions: *Save current → slot*, *Load slot*,
  *Rename*, *Read/Inspect*.
- A prominent **"Save to Keyboard"** button on the main toolbar that targets the
  active slot with a confirmation showing what will be written.
- Progress + explicit success/failure (with the read-back result).

## 8. Technical design
- **ApexKit:** `OnboardProfile` module — Codable model mirroring the flash image;
  `serialize() -> [UInt8]` (little-endian, packed), `crc32stm()`,
  `chunk()`; `ApexDevice.writeProfile(slot:blob:)` / `readProfile(slot:)` using the
  `0x02/0x03/0xB1` ops; a `verify()` that round-trips.
- **App:** `ProfileStore` (see PRD-06) provides the current-state → `OnboardProfile`
  mapping; the Profiles view drives write/verify/switch.
- **Data model:** reuse existing `LightingConfig`, `ActuationConfig`, mappings
  (PRD-01), macros (PRD-04), OLED bitmap; add a `ProfileMeta { name, slot, guid }`.

## 9. Edge cases & risks
- **Flash wear:** writing flash repeatedly wears it. Implemented policy: writes
  are **diff-gated and debounced** — a save only happens ≥3 s after the last
  edit, and only when the patched image differs byte-for-byte from what flash
  already holds, so a slider drag costs at most one write and an unchanged
  session costs none. (The PRD originally said "explicit user action only";
  that was revised because the bug this feature fixes was precisely users
  believing "written to the keyboard" meant persisted — an explicit extra save
  button recreates that trap.)
- **Half-write safety:** an interrupted write could corrupt a slot; always erase →
  write → validate → read-back, and document recovery (re-save or restore via GG).
- **CRC correctness:** wrong CRC ⇒ firmware rejects or ignores the slot; gate all
  writes behind the read-back verification during development.
- **Schema detection:** confirm FW ≥ 1.19.0 → schema 8 before writing; refuse
  otherwise.

## 10. Acceptance criteria
- AC-1: Saving to slot N, unplugging, and replugging on a machine with no software
  reproduces the lighting/actuation/OLED that was saved.
- AC-2: Read-back of a freshly written slot byte-matches the blob that was sent.
- AC-3: A deliberately corrupted CRC is rejected (proves the verify path works).
- AC-4: The keyboard remains fully usable after any failed/aborted write.

## 11. Effort & milestones
**L.** M1: serialize + CRC + read-back diff harness (prove CRC on hardware).
M2: single-slot write/verify. M3: 5-slot UI + switch. M4: integrate all
subsystems' state into the blob.

## 12. Open questions — all answered on hardware (fw 1.19.7)
- ~~Exact STM32 CRC parameters?~~ Poly `0x04C11DB7`, seed `0xFFFFFFFF`, no
  reflection, no final XOR, 32-bit little-endian words, over the 12 320-byte
  body (the image minus the trailing CRC). Confirmed by reproducing the
  stored CRC of factory images on two slots.
- ~~Final partial chunk behavior?~~ Every chunk declares size 500; the payload
  is padded with `0xFF` past the CRC. 25 chunks for the 12 324-byte image;
  read-back of a written slot byte-matches.
- ~~Does the profile-volatility command (`0x34`) need toggling around writes?~~ No. Verified:
  with either argument, live `0x36` writes never reach flash, and the flash
  write sequence needs no volatility preamble. The firmware also does not
  overwrite a slot from its live state on its own.
- New knowledge worth keeping: the normal-layer bindings in the image have **100**
  slots (the full `deviceKeyIndexToHID` table: 91 rebindable keys + 3 empty +
  6 media buttons with factory CONSUMER entries), 5 bytes each, indexed by
  firmware slot — unlike `0x36` frames, which are HID-prefixed.
