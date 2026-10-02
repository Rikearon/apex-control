# PRD-31: Device Simulator & Test Harness

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (enables everything else to be tested; pairs with PRD-30, which tests the *real* device)
- **Firmware basis:** none — this replaces the device.

## 1. Summary
Every test in this project stops at the byte builder. `ApexDevice` constructs its
own `HIDTransport`, so nothing above the packet layer — the read-back parser in
context, the layer-merge logic that protects the factory Fn shortcuts, reconnect
behaviour, profile apply ordering — can be tested at all without a keyboard
plugged into the machine running the tests. This PRD adds the seam and a
simulator behind it, so the app is testable in CI and developable without
hardware.

## 2. Background & GG parity
Not a parity feature; a project-health one. The specific risk it addresses has
already materialised twice in this codebase: the binding-write path went through
several revisions (blank semantics, layer merging, read-before-write ordering)
where a mistake would have silently destroyed a user's factory Fn layer, and the
only way to check any of it was to plug in a keyboard and read it back by hand.
That does not scale, it does not run on a contributor's machine who owns a
different model, and it does not catch a regression before it ships.

The second motivation is contribution: today, working on the UI at all requires
owning this exact keyboard.

## 3. Technical basis (grounded)
- **The missing seam** (confidence: certain, from the source): `ApexDevice` holds
  `private let transport: HIDTransport` created in `init()`. There is no protocol
  and no injection point. Every method calls `transport.sendFeatureReport` /
  `sendOutputReport` / `queryFeature` / `query` directly — a small, well-defined
  surface, which is what makes the refactor cheap.
- **What a simulator must model** to be useful (all of it known from the work
  already done): the 644-byte feature buffer; the "response slot holds the last
  command's answer" behaviour, including the `40 00` acknowledgement seen after a
  `direct_write`; the `0xB6` reply shape `[cmd][err][layer][count][blocks]`; the
  fact that the resting mapping state is a self-mapping; the nine `0x62` firmware
  functions on the Fn layer; connect/disconnect callbacks.
- **Record/replay**: `HIDTransport` is the only place that touches IOKit, so a
  recording decorator can capture `(direction, bytes, timestamp)` for a real
  session and a replay transport can serve it back. Fixtures captured from real
  hardware are the highest-value test data this project can own — they encode the
  quirks we discovered rather than the ones we assumed.
- **CI**: with a simulated transport, the entire app logic runs on a GitHub
  runner with no device.

## 4. Goals / Non-goals
- **Goals:** a `DeviceTransport` protocol with the real implementation behind it;
  a `SimulatedTransport` modelling the behaviours above; record/replay of real
  sessions to fixtures; tests for the logic that currently has none (read-back
  parsing in context, layer merge, reconnect, profile apply, rescue); a
  `--simulate` flag so the app and CLI run with no keyboard.
- **Non-goals:** simulating USB timing or errors faithfully enough to replace
  hardware testing (PRD-30 owns real-hardware truth); a graphical virtual
  keyboard product; emulating models we have never observed.

## 5. User stories
- As a maintainer, CI catches a regression in the binding merge before it reaches
  anyone's keyboard.
- As a contributor without this keyboard, I can run the app, see the UI with a
  plausible device, and submit a fix.
- As a reviewer, a bug report can come with a recorded session I can replay.
- As a developer, I can test "keyboard unplugged mid-write" without unplugging
  anything.
- As a maintainer, adding a model (PRD-27) comes with a simulated device to test
  it against.

## 6. Functional requirements
- FR-1: `DeviceTransport` protocol covering exactly the methods `ApexDevice`
  uses; `HIDTransport` conforms unchanged; `ApexDevice.init(transport:)` accepts
  any conformer, defaulting to the real one so no call site breaks.
- FR-2: `SimulatedTransport` maintains device state: three mapping layers seeded
  with the factory defaults (self-mappings plus the nine `0x62` Fn entries),
  actuation tables, rapid-tap pairs, an OLED buffer, and firmware/region/layout
  answers.
- FR-3: It models the **response slot**: a read after a write returns that
  command's acknowledgement; a read with no preceding command returns the last
  one; a malformed request returns `err = 1` with no payload.
- FR-4: Fault injection: disconnect at an arbitrary point, `ioReturn` errors on
  the *n*th write, short read replies, and timeouts — each triggerable from a
  test.
- FR-5: `RecordingTransport` wraps any transport and writes a fixture; a fixture
  replays deterministically and fails loudly if the code under test sends a
  request the recording does not contain.
- FR-6: `--simulate` on the app and `apexctl` uses the simulator, with the UI
  showing an unmistakable "Simulated device" badge so nobody mistakes it for real
  hardware.
- FR-7: CI runs the full suite with no device attached and fails on any test that
  requires one.
- FR-8: A fixture captured on real hardware is committed for at least: a full
  binding read, a connect sequence, and a profile apply.

## 7. UX / UI design
- Invisible in normal use. In `--simulate`, a persistent badge in the sidebar
  footer where the connection dot lives, coloured differently from "connected",
  reading "Simulated".
- A **Developer** section item to record the current session to a file, so a user
  reporting a bug can attach a replayable trace (ties to PRD-35's support
  bundle).
- Fixture files are plain JSON with hex payloads and comments where a byte
  sequence is a known command, so they are reviewable in a diff.

## 8. Technical design
- **ApexKit:**
  - `protocol DeviceTransport { start/stop, isConnected, onConnectionChange,
    sendFeatureReport, sendOutputReport, getFeatureReport, queryFeature, query }`.
  - `HIDTransport: DeviceTransport` (no behaviour change).
  - `SimulatedTransport: DeviceTransport` — a state machine over the command
    table, deliberately written from `docs/PROTOCOL.md` rather than from our
    builder code, so a bug in the builders cannot be mirrored in the simulator
    and hide itself.
  - `RecordingTransport` / `ReplayTransport` decorators.
- **App:** `AppEnvironment.bootstrap()` chooses the transport from a launch
  argument; the badge reads a `isSimulated` flag off the controller.
- **Tests:** a new `ApexKitIntegrationTests` target covering the logic that has
  no coverage today, plus `ApexControlAppTests` for the controller.

## 9. Edge cases & risks
- **A simulator that agrees with our bugs is worse than none.** Writing it from
  the protocol document, and validating it against recorded real fixtures, is the
  defence — a fixture replay that disagrees with the simulator is a finding, not
  a flake.
- **Fixture rot**: recordings encode one firmware's behaviour; they must record
  the firmware version and the test must state it.
- **Refactor risk**: introducing the protocol touches every `ApexDevice` method.
  Mitigated by the existing byte-level tests, which must pass unchanged.
- **`--simulate` reaching users** — a simulated session that a user mistakes for
  real would produce confusing bug reports; hence the loud badge and a log line
  on every launch.
- **Over-modelling**: the simulator should reproduce behaviours we have
  *observed*, not behaviours we imagine; anything speculative belongs in a probe
  (PRD-30), not a fake.

## 10. Acceptance criteria
- AC-1: `swift test` passes on a machine with no keyboard attached, and the suite
  covers the read-back parser, the layer merge, reconnect, and profile apply.
- AC-2: A test proves that writing bindings when the Fn layer has never been read
  leaves the Fn layer untouched.
- AC-3: A test proves that a disconnect mid-apply surfaces an error and does not
  mark the profile applied.
- AC-4: A real recorded fixture replays green against the current code.
- AC-5: `--simulate` launches the full UI with a plausible device and an
  unmistakable badge.
- AC-6: Existing byte-level protocol tests pass unchanged after the refactor.

## 11. Effort & milestones
**M.** M1: `DeviceTransport` protocol + injection, existing tests green.
M2: `SimulatedTransport` with the mapping/actuation/OLED state and the response
slot. M3: fault injection + the untested-logic test suite. M4: record/replay and
committed fixtures. M5: `--simulate` in app and CLI, CI wiring.

## 12. Open questions
- Should the simulator live in the shipping library (small, always available for
  `--simulate`) or in a test-only target (cleaner, but then the app cannot run
  simulated)?
- How faithfully should the response slot's *decay* be modelled — real hardware
  appeared to drop the reply after a delay, which we never fully characterised.
- Do we want a fixture format that a person can hand-author to describe a
  hypothetical firmware, or only machine recordings?
- Does the UI-level snapshot harness that already exists belong under the same
  `--simulate` umbrella, so screenshots can be generated deterministically?
