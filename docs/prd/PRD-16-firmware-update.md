# PRD-16: Firmware Update (Information Only)

- **Priority:** P2 *(read-only subset; flashing is not planned)*
- **Status:** Proposed — the read-only subset only (see §4). Flashing firmware is
  **not planned**.
- **Depends on:** — (builds on the firmware-version read, which is done)
- **Firmware basis:** `fw_version` (`90 00`, done) and the LED-controller firmware
  version (`90 01`, from descriptor, not yet checked on hardware). Both are
  read-only queries. There is no firmware-write command in this project and none is
  planned.

## 1. Summary
Apex Control already reads and displays the keyboard's running firmware (1.19.7 on
our unit). As far as we know, SteelSeries GG can also *flash* new firmware. This PRD
proposes only the **safe subset** — show the running firmware and the LED-controller
firmware, and say where updates come from: the vendor's own updater. Apex Control
**does not flash firmware**, from the app or from `apexctl`, and that is **not
planned**: a bad flash can leave a keyboard permanently unusable, and this project has
no way to recover a unit that a bad flash has damaged.

## 2. Background & GG parity
The Apex Pro TKL Gen 3 ships with firmware and receives occasional updates; users
reasonably want to know what they are running. But firmware flashing is the one
operation where a bug does not merely misconfigure the keyboard — it can leave it
non-functional. So the parity target here is deliberately minimal: show the
*version* and leave checking for updates, and installing them, to the vendor's own
updater. (Telling users whether a newer version exists would need either network
access, which the app deliberately does not have (`docs/PRIVACY.md`), or reading
another program's private files, which is not planned.) Everything else in this
backlog can be retried after a mistake; a botched flash cannot.

## 3. Technical basis (grounded)
- **Read current firmware (done, confirmed on hardware).** `ApexDevice.firmwareVersion()`
  sends Output `90 00` and parses the ASCII reply (`Queries.parseFirmware`),
  yielding `1.19.7`. `Queries.ledFirmwareVersionRequest()` (`90 01`) for the
  LED-controller firmware exists but is not yet surfaced, and its reply has not been
  checked on hardware (*from descriptor*).
- **Whether a newer version exists: not determined by this project.** The keyboard
  does not say, and the two ways to find out (a network request, or another
  program's files) are both out of scope (§4).
- **Flashing: not planned.** No firmware-write command is implemented, and `ApexKit`
  has no builder for one. The only firmware-related traffic in this project is the
  read-only version query.
- **Confidence summary:** *read* = confirmed on hardware; *LED firmware read* = from
  descriptor.

## 4. Goals / Non-goals
- **Goals:**
  - Display the running keyboard firmware (done) and the LED-controller firmware.
  - Tell the user, in one fixed line, that firmware updates come from the vendor's own
    updater (SteelSeries GG, on a computer where it runs) and that Apex Control never
    flashes firmware, with a link to the vendor's support page.
- **Non-goals:**
  - **Flashing firmware — from the app, from `apexctl`, or as an "experimental"
    option. Not planned.** Writing firmware is irreversible, the payoff is small (the
    vendor's own updater is the supported route, which we have not evaluated), and this
    project has no way to recover a unit that a bad flash damages. If the maintainers
    ever reconsider, that would be a new PRD with its own review, not a milestone here.
  - **Checking whether a newer version exists**, by asking a server or by reading
    another program's files. The app makes no network connections
    (`docs/PRIVACY.md`), and another program's private files have no documented format.
  - Reading, parsing or storing firmware images.
  - Downloading anything.
  - Downgrade/rollback and cross-model firmware.

## 5. User stories
- As a user, I want to see my firmware version, so I can put it in a bug report or
  tell whether it is the one this project was checked on.
- As a cautious user, I want the app to send me to the vendor's updater for the
  actual flash, so I do not risk my keyboard on this project's code.

## 6. Functional requirements
- FR-1: Show the running keyboard firmware (done) and add the LED firmware via
  `90 01`, once its reply has been checked on hardware.
- FR-2: *Withdrawn.* Reading another program's records to learn which version is
  "latest" is not planned (see §4).
- FR-3: *Withdrawn.* With no source for a newer version there is nothing to compare
  against.
- FR-4: Show a fixed note beside the versions — firmware updates come from the
  vendor's own updater, and Apex Control never flashes firmware — and **never**
  auto-download or auto-flash anything.
- FR-5: A **Learn more** link opens the vendor's support page in the browser. There is
  no flash button.
- FR-6: *Withdrawn.* Parsing firmware images is not planned (see §4).
- FR-7: *Withdrawn.* No flash path, experimental or otherwise, is planned (see §4).

## 7. UX / UI design
- Firmware lives in an **About / Device** pane (shared with PRD-18): current
  firmware, LED firmware, region, layout, and the fixed note with its **Learn more**
  link.
- There is no flash control anywhere in the UI, hidden or otherwise.

## 8. Technical design
- **ApexKit:** a `FirmwareInfo` model (running + LED versions). There is deliberately
  no firmware-write builder.
- **App:** an About / Device pane. **No** background polling and no network request
  (see §9, privacy).
- **Data model:** `FirmwareInfo { running, led }`, each a version string as the
  keyboard reports it.

## 9. Edge cases & risks

**Why this PRD stops at showing the version.** Flashing is uniquely *irreversible*; the
payoff is *small* (the vendor's own updater is the supported route, which we have not
evaluated); the failure mode is a bricked keyboard and a justifiably angry user;
and recovery would depend on the vendor's own tools or a warranty replacement, so this
project would inherit all of the risk and little of the value. That is why flashing is
**not planned**.

- **Wrong model.** The full-size Gen 3 (`0x1640`) and wireless variants
  (`0x1644` / `0x1646`) share the "Gen 3" name but are believed to use different
  command sets (`docs/PROTOCOL.md`). The app does not talk to them at all, so it shows
  no firmware for them either.
- **Privacy.** The pane reads nothing from other programs and makes no network
  connection (aligns with `docs/PRIVACY.md`, FEATURE-GAP §E and PRD-18). Opening the
  support page happens in the user's browser, on their click.
- **The link and `make check`.** The app's no-network promise is enforced by
  `make check`, which also refuses a URL literal under `Sources/`. The **Learn more**
  link therefore needs a deliberate, reviewed exception in `Scripts/check-repo.py`,
  not a workaround.

## 10. Acceptance criteria
- AC-1: The app shows the correct running firmware (`1.19.7` on our unit) and the
  LED firmware.
- AC-2: *Withdrawn.* There is no update check to test (see §4).
- AC-3: *Withdrawn.* There is no version comparison (see FR-3).
- AC-4: The pane shows the fixed note and the **Learn more** link, and no flash
  control.
- AC-5: No code path in the app or in `apexctl` (apart from `apexctl raw`, which sends
  exactly the bytes you give it) writes firmware.
- AC-6: *Withdrawn.* There is no flasher to gate (see §4).

## 11. Effort & milestones
**Safe subset = S; flashing is not planned.**
- M1: LED firmware read + About / Device pane + the fixed note.
- M2: *Withdrawn* (an update check).
- M3, M4: *Withdrawn* (a research spike and an experimental flasher — not planned).

## 12. Open questions
- Does the LED firmware query (`90 01`) answer on this unit, and in what format?
