# PRD-35: Diagnostics, Protocol Console & Support Bundle

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (pairs with PRD-31's recording transport and PRD-30's probes)
- **Firmware basis:** none new — it observes and replays the commands we already
  send.

## 1. Summary
When something goes wrong on someone else's keyboard there is currently nothing
to look at. The app logs nothing, `apexctl raw` is the only way to inspect the
wire, and a bug report can say little more than "the lighting stopped". This PRD
adds structured logging, a live protocol console, and a one-click support bundle
so a problem can be diagnosed from a report instead of guessed at.

## 2. Background & GG parity
Not a parity feature. The need is sharper here than for a vendor's own app: this is
an independent implementation of a protocol we know of no public documentation for, running
against firmware versions we have never seen, on hardware variants we may not own.
Almost every interesting bug will be "the device did something we did not expect",
and that is exactly the class of bug that is invisible without a wire log.

The protocol work already done makes the case. The read-back investigation was
solved by dumping raw feature reports by hand and noticing an error byte in the
wrong position; the Fn-layer discovery came from reading bytes nobody had
printed before. Both would have been trivial with a console and impossible from a
user's description.

## 3. Technical basis (grounded)
- **A single choke point exists**: `HIDTransport` is the only place that touches
  IOKit, so every byte in and out of the device can be observed by decorating it
  — the same seam PRD-31 needs for record/replay.
- **Structured logging** (confidence: documented): `OSLog`/`Logger` with
  subsystem and per-area categories gives free integration with Console.app,
  privacy annotations, and no cost when disabled. `OSLogStore` can read the app's
  own entries back for the support bundle.
- **Decoding for humans**: we already have the full command table in
  `docs/PROTOCOL.md`, so a log line can say
  `→ Feature 644B  0x36 mappings layer=0 count=91` instead of a hex wall, with
  the raw bytes available on demand.
- **Privacy constraint**: the wire carries key *bindings* and OLED *content*,
  both of which can be personal (a bound text snippet, a name on the screen).
  Logs must be opt-in at the verbose level and redactable, and the support bundle
  must show the user what it contains before it is shared (PRD-34).

## 4. Goals / Non-goals
- **Goals:** levelled structured logging across device I/O, lifecycle, and
  errors; a live protocol console showing decoded traffic with a hex view; the
  ability to send a hand-written packet and see the reply; a support bundle
  containing logs, device info, capability report, app config (sanitised) and
  environment; a clear privacy review step before sharing.
- **Non-goals:** telemetry or automatic crash upload (PRD-34 forbids it); a
  general USB analyser; keeping logs forever; exposing the console to
  non-technical users by default.

## 5. User stories
- As a user whose keyboard behaves oddly, I can produce one file that lets a
  maintainer see what happened.
- As a maintainer, I can read a bug report and see the exact bytes the device
  received and returned.
- As someone reverse engineering, I can send a candidate packet and watch the
  reply without writing code.
- As a privacy-conscious user, I can see exactly what is in the bundle before I
  send it.
- As a developer, I can turn on verbose device logging and watch it in Console.app.

## 6. Functional requirements
- FR-1: **Logging** at four levels (error, notice, info, debug) across categories
  `device`, `protocol`, `lighting`, `profiles`, `bindings`, `lifecycle`,
  `automation`. Default is error+notice; verbose is opt-in and resets on
  relaunch.
- FR-2: **Wire logging** (debug level) records direction, report type, length,
  decoded command name, and the raw bytes, with a ring buffer capped by size
  (default 4 MB) so it cannot grow without bound.
- FR-3: **Protocol console**: a live, filterable list of decoded traffic; each
  row expands to a hex dump; a pause/clear; and an export.
- FR-4: **Packet composer**: enter bytes (with a picker for known commands to
  prefill), choose Feature/Output, send, and see the reply — the `apexctl raw`
  capability with a UI and the protocol table alongside it.
- FR-5: The composer requires an explicit "I understand this writes to my
  keyboard" acknowledgement once per session, and refuses the flash-touching
  commands (`0x75` region, firmware update) outright.
- FR-6: **Support bundle** (a `.zip`) containing: app version and commit; macOS
  version and hardware model; device info (VID/PID, firmware, region, layout,
  full report descriptors); the capability report (PRD-30); recent logs; the
  profile library **with user text redacted by default**; permission states; and
  a manifest listing every file included.
- FR-7: Before saving, the bundle shows a **review sheet** listing its contents
  with a toggle for the optional parts (logs, profiles) and a preview of the
  manifest.
- FR-8: Redaction: OLED text and image paths, profile names, and — if PRD-01's
  host actions are built — `launchApp` paths and `insertText` contents are
  replaced with placeholders unless the user opts to include them.
- FR-9: `apexctl diagnose` produces the same bundle from the command line.
- FR-10: Logs never contain frame pixel data, audio samples, or keystroke
  content — asserted by test, consistent with PRD-34.

## 7. UX / UI design
- A **Diagnostics** section in Settings, behind a disclosure: log level, "Open
  Console…", "Protocol console…", "Create support bundle…".
- The console is a separate window: a table (time, direction, decoded summary),
  a detail pane with hex + ASCII, a filter field, and the composer docked at the
  bottom.
- Decoded rows use the names from `docs/PROTOCOL.md` so the console teaches the
  protocol as you watch it.
- **Bundle review sheet:** a plain list — "Logs (2.1 MB) · Profiles (redacted) ·
  Device info · Capability report" — with toggles and a "Show manifest" link.
- **Error surfacing:** errors that today appear as a transient banner also land
  in the log with a correlation id shown in the banner, so a user can quote it.

## 8. Technical design
- **ApexKit:**
  - `LoggingTransport` decorator over `DeviceTransport` (PRD-31) emitting to a
    `WireLog` ring buffer and to `OSLog`.
  - `PacketDecoder` — bytes → a human summary, driven by a table that mirrors
    `docs/PROTOCOL.md`; unit tested so the console cannot drift from the docs.
- **App:** `DiagnosticsStore` (log level, ring buffer access), `ConsoleWindow`,
  `SupportBundleBuilder` (with `DataInventory` from PRD-34 as the source of what
  exists), and the review sheet.
- **apexctl:** `diagnose` and a `--verbose` that turns on wire logging.

## 9. Edge cases & risks
- **A support bundle is an exfiltration path.** It is created by the user and
  shared deliberately, but the defaults must be safe: redaction on, logs
  truncated, and a manifest the user can read. Getting this wrong turns a help
  feature into a privacy incident.
- **Verbose logging in normal use** costs performance on a 30 fps stream; wire
  logging must be off by default and cheap to test for (`if logger.isEnabled`).
- **The composer can brick settings** — it writes arbitrary bytes. The refusal
  list (region write, firmware) is the minimum; a snapshot precondition
  (PRD-29) would be better.
- **Log retention**: a ring buffer in memory is lost on crash, which is exactly
  when it is wanted. A small on-disk tail (last N KB, rotated) is the compromise,
  and it must be included in the delete-all-data action.
- **Decoder drift** — a console that mislabels a command is worse than raw hex;
  hence the table-driven decoder with tests.

## 10. Acceptance criteria
- AC-1: With verbose logging on, applying a profile produces decoded log lines
  naming each command in order.
- AC-2: The console shows a `0xB6` read request and its reply, decoded, with the
  error byte and count called out.
- AC-3: The composer sends a hand-entered `0x90 0x00` and shows the firmware
  string in the reply.
- AC-4: The composer refuses `0x75` (region write).
- AC-5: A support bundle contains the manifest, and with redaction on it contains
  no OLED text, no launch paths, and no profile names.
- AC-6: A test asserts no keystroke content, frame data, or audio appears at any
  log level.
- AC-7: With logging at the default level, the 30 fps lighting stream shows no
  measurable overhead.

## 11. Effort & milestones
**M.** M1: `OSLog` categories and levelled logging across existing code.
M2: `LoggingTransport` + `PacketDecoder` + ring buffer. M3: console window and
composer. M4: support bundle with review and redaction. M5: `apexctl diagnose`.

## 12. Open questions
- Should the console ship in release builds or only in a developer build? It is
  the single best tool for community protocol work, which argues for shipping it
  behind a disclosure.
- How much on-disk log tail is worth keeping for post-crash diagnosis, given the
  privacy cost of anything persisted?
- Should the composer require a PRD-29 snapshot, making diagnostics depend on
  backup — safer, but a heavier prerequisite for a debugging tool?
- Is there value in decoding *inbound* `0xFFC1` notification packets in the
  console before PRD-14 implements them properly? (Probably yes — it is how that
  PRD's unknowns get resolved.)
