# PRD-30: Protocol Conformance & Capability Probe

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** PRD-29 (never probe a device you cannot restore)
- **Firmware basis:** every implemented command, exercised against real hardware
  and observed at the host.

## 1. Summary
Large parts of this protocol are documented by inference, and the UI currently
labels several things "unverified" because nobody has actually checked them. This
PRD builds the thing that checks: a guided, reversible test suite that writes a
known configuration, observes what the keyboard really does through host event
monitoring, and produces a machine-readable capability report per firmware
version.

## 2. Background & GG parity
Not a parity feature. It exists because this is an independent implementation of a
protocol we know of no public documentation for, and its credibility rests on knowing the
difference between what the vendor's description of the device says and what the
hardware does. The project already has three live examples of that gap:

- `release_mode` values `0x03`/`0x04` are accepted by the firmware and their
  meaning is undocumented — the UI calls them "Alternate mode 3/4" because we
  genuinely do not know.
- Only six consumer usages are confirmed (the ones the firmware assigns to its
  own media buttons); the rest of the consumer page is offered with a caveat.
- Mouse bindings (`function 0x01–0x08`) looked inert from a naive interface
  enumeration and were only shown to have a transport by parsing the report
  descriptors and finding a second Generic Desktop/Mouse collection on the
  consumer interface.

Every one of those was resolved by an ad-hoc investigation that left no artefact.
A conformance suite turns that into a repeatable asset.

## 3. Technical basis (grounded)
- **Write side**: all builders exist and are tested at the byte level.
- **Read-back side**: the `0xB6` read-back verifies what the *device stored*,
  which is necessary but not sufficient — storing a binding does not prove the
  keyboard *emits* the right thing.
- **Observation side** (confidence: documented, and already used by
  `KeyMonitor`): a `CGEventTap` sees the resulting keyboard, consumer, and
  **mouse** events. This closes the loop: write a binding, ask the user to press
  the key, observe what arrived. Requires Input Monitoring or Accessibility, as
  `KeyMonitor` does.
- **Why a human is in the loop**: nothing can synthesise a *physical* key press.
  The probe must therefore be guided — "press the Ins key now" — with a timeout
  and a skip. That is acceptable for a tool run occasionally, not in CI.
- **What can be automated without a human**: write→read round trips for every
  function value, boundary behaviour (count fields, chunking, out-of-range
  levels), error-byte behaviour, and idempotency.
- **Safety**: every probe must be reversible, and PRD-29's snapshot is the
  precondition — this suite deliberately writes odd values to a real keyboard.

## 4. Goals / Non-goals
- **Goals:** an automated round-trip suite over every command and every
  documented value; a guided suite for behaviours only a human press can confirm;
  a `CapabilityReport` keyed by model + firmware version, committed to the repo;
  UI copy driven by that report instead of hard-coded caveats; a regression check
  when firmware changes.
- **Non-goals:** fuzzing the device with random bytes (risk of bricking with no
  upside); probing anything that writes flash (region, firmware, onboard
  profiles) — those are one-way and belong to their own PRDs; running as part of
  normal app startup.

## 5. User stories
- As a maintainer, I run one command and learn exactly what this firmware
  supports.
- As a user on newer firmware, the app's caveats reflect *my* firmware, not the
  one the developer happened to own.
- As a contributor with a different model, I can submit a capability report
  without writing code.
- As a user, the app stops telling me a feature is "unverified" once it has been
  verified on my hardware.
- As a reviewer, a firmware update that breaks a command is caught by a suite,
  not by a bug report.

## 6. Functional requirements
- FR-1: **Precondition**: the probe refuses to run without a current snapshot
  (PRD-29) and restores the device at the end, including on failure or
  interruption.
- FR-2: **Automated round trips**: for every `function` value 0x00–0x08, 0x30–0x34,
  0x51, 0x61, 0x62, 0x71, 0x72, write it to a chosen key on each layer and read
  it back; record accepted/normalised/rejected.
- FR-3: **Boundary probes**: mapping chunk counts (1, 2, 90, 91, 106, 107),
  actuation levels (0, 1, 40, 41), rapid-tap pair counts (0, 10, 11), and OLED
  payload sizes; record which are accepted and how failures present.
- FR-4: **Guided probes** with an on-screen prompt and a live event readout:
  does a KEYBOARD combo emit all its usages; does each consumer usage produce a
  system action; do mouse bindings emit mouse events; does a "disabled" key emit
  nothing; what do `release_mode` 3 and 4 change about key behaviour; does the
  second actuation layer fire at the configured depth.
- FR-5: **Report**: a JSON `CapabilityReport { model, firmware, date, results:
  [{ probe, outcome, evidence }] }`, written to disk and offered for submission.
- FR-6: The app **consumes** the report: a verified consumer usage loses its
  "unverified" label; an unsupported function is hidden or marked.
- FR-7: Reports for known firmware versions ship with the app so a user sees
  accurate labels before ever running the probe.
- FR-8: Every probe is individually skippable and the suite is resumable.
- FR-9: The suite never writes flash and never touches region, firmware, or
  onboard profiles.
- FR-10: A `--ci` mode runs only the probes that need no human and no risk
  (byte-level round trips), for use against a keyboard on a build machine.

## 7. UX / UI design
- Lives in a **Developer** section of Settings, hidden behind a disclosure —
  this is a tool for people who opt in, not a feature to stumble into.
- The runner is a sheet: a checklist of probes, a running log, and for guided
  probes a large "Press the **Ins** key" prompt with a live list of the events
  received.
- **Before starting:** a plain warning that the probe will change the keyboard's
  configuration and restore it afterwards, with the snapshot state shown.
- **Result:** a summary table (verified / rejected / unknown), an export button,
  and a link to open an issue with the report attached.

## 8. Technical design
- **ApexKit:** a `Probe` protocol (`name`, `run(device) throws -> Evidence`) and
  a `ProbeSuite`; probes are declarative so contributors can add one without
  touching the runner.
- **App:** `ProbeRunner` (owns the snapshot precondition, the restore `defer`,
  and the event tap), `ProbeView`, and `CapabilityReportStore` which the UI reads
  for labels.
- **apexctl:** `apexctl probe [--ci] [--only <name>]` producing the same report.
- **Data model:** `CapabilityReport` in ApexKit so both the app and the CLI share
  it; shipped reports live in the bundle as resources.

## 9. Edge cases & risks
- **This PRD deliberately misconfigures a real keyboard.** Restore-on-failure
  must be a `defer` around the whole run, and the CLI must restore even on
  SIGINT.
- **A guided probe with the keyboard mid-probe** — if the key under test is the
  one the user needs to cancel, the suite has trapped them. Never probe Escape,
  Enter, or the modifiers needed to quit, and always leave a mouse-reachable
  cancel.
- **Input Monitoring or Accessibility** is required for the guided half; without
  either, the suite must still run the automated half rather than refusing
  entirely.
- **False negatives**: a consumer usage that macOS ignores looks identical to one
  the firmware dropped. The report must distinguish "no event observed" from
  "event observed but no system action", and only claim what it saw.
- **Firmware variance** is the whole point, so the report must be keyed by
  firmware version and never merged across versions.
- **Time**: a full guided suite with ~30 consumer codes is tedious; group probes
  so a user can verify the six that matter in a minute.

## 10. Acceptance criteria
- AC-1: Running the suite leaves the keyboard byte-identical to before, verified
  by a read-back diff, including when interrupted mid-run.
- AC-2: The automated half runs with no human input and produces a report.
- AC-3: The guided half correctly identifies that a KEYBOARD binding of
  Cmd+Shift+4 emits all three usages.
- AC-4: The suite determines empirically whether mouse bindings emit mouse
  events, and the answer is recorded in the report and reflected in the UI.
- AC-5: A consumer usage verified by the probe loses its "unverified" label in
  the Bindings inspector.
- AC-6: Running without a snapshot is refused with a clear message.

## 11. Effort & milestones
**M.** M1: probe protocol, runner, snapshot precondition and restore. M2:
automated round-trip and boundary probes. M3: event-tap observation and guided
probes. M4: report format, shipped reports, UI label consumption. M5: `--ci` mode.

## 12. Open questions
- What *is* `release_mode` 3 and 4? A guided probe can characterise the behaviour
  (does the key re-trigger without full release? at what depth?) even if we never
  learn what the firmware calls it.
- Can we distinguish "firmware dropped this consumer usage" from "macOS has no
  action bound to it" without special-casing each usage?
- Should reports be submitted anywhere central (a repo folder of community
  reports), and if so how do we keep that from becoming a privacy leak?
- Is there a safe subset of *flash* probing (e.g. read-only onboard profile
  reads) worth including once PRD-29 proves the read path?
