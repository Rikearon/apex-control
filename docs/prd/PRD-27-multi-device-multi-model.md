# PRD-27: Multi-Device & Multi-Model Support

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (a refactor of ApexKit; unblocks PRD-28 and widens every other PRD's audience)
- **Firmware basis:** the same command families, parameterised. From the vendor's
  description of the device (not included in this repository), the `0x1642` protocol
  is largely shared with at least one other keyboard; each model's differences still
  have to be established, on hardware, before that model is supported.

## 1. Summary
ApexKit is hard-wired to one keyboard. `ApexProTKLGen3` is a namespace of
constants, `HIDTransport` binds to the first matching device, and the feature
report size is a literal in three files. This PRD introduces a device model
abstraction so the same engine drives the rest of the Apex line, and so a person
with two keyboards can configure both.

## 2. Background & GG parity
As far as we know, GG supports the whole SteelSeries catalogue from one app and treats multiple
connected devices as normal. Apex Control supports exactly one product ID and
assumes exactly one unit. That is defensible for a project that began as "make
*my* keyboard work", but it caps the audience at one SKU, and every feature we
add — bindings, profiles, lighting — is written against constants that will have
to be untangled later anyway. The cost of the abstraction only grows.

## 3. Technical basis (grounded)
- **The 2024 model shares the 2022 model's command set** (confidence: from the
  vendor's description of the device; not verified on hardware). The `0x1642`
  protocol builds on the one used by the Apex Pro TKL (2022), PID `0x1628`. Everything
  we implemented — `0x40`/`0x41` lighting, `0x38 61/62/65/66/67` actuation,
  `0x36`/`0xB6` mappings, `0x1F 81`/`0x38 83` OLED, `0x90`/`0xF2`/`0xF5`
  queries — belongs to that shared set. The 2024 model differs in the actuation
  curve, one firmware range, the lighting layout (adds LED `0xFB`) and the OLED
  frame packing.
  ⇒ **Supporting `0x1628` should be close to free** and is the natural first proof
  that the abstraction is real, but it needs a contributor who owns one to verify it
  (see §9).
- **The older TKL** (`1038:1614`, from the vendor's description of the device) uses a
  **different**, older command set. Supporting it is a genuine second protocol, not a
  parameter change.
- **Other models would each have to be established from evidence a contributor
  produces** — captures and reads of their own keyboard, and public projects;
  contributors must not supply vendor files (see `CONTRIBUTING.md`) — and each needs a
  contributor who owns the hardware. The full-size Gen 3 (`0x1640`) and the wireless variants
  (`0x1644` / `0x1646`) are believed to use different command sets
  (`docs/PROTOCOL.md`; untested). Once the evidence exists, adding a model is bounded work
  rather than research; the evidence has to come from someone who has the keyboard.
- **What actually varies between models** (confidence: from the vendor's description
  of the device): vendor/product id, feature report size (`645` here, smaller on other
  wired Apex boards), the firmware's key-slot table and therefore all three key sets,
  the actuation curve, whether a second-actuation layer exists, the size of the macro
  region, the physical layout geometry, whether an OLED exists, and the lighting zone
  list.
- **What our code hard-codes today** (confidence: certain, from the source):
  `ApexProTKLGen3.*` referenced directly in `DirectLighting`, `Actuation`,
  `Mappings`, `LightingRender`, every view, and `apexctl`; `featurePayloadSize =
  644` duplicated in `DirectLighting`, `Actuation`, `Mappings`, `OLED`;
  `HIDTransport` stores a single `device`.

## 4. Goals / Non-goals
- **Goals:** a `DeviceModel` value type carrying everything that varies; protocol
  builders parameterised by it; a device registry that can hold several connected
  devices; per-device UI with a device switcher; support for `0x1628` as the
  first second model; a documented "how to add a model" guide.
- **Non-goals:** mice, headsets, or non-keyboard devices; the older single-byte
  command set; wireless (PRD-28); making every feature work on every model —
  capability flags let a model opt out.

## 5. User stories
- As an owner of the 2022 Apex Pro TKL, the app works on my keyboard too.
- As someone with a TKL at home and a full-size at the office, one app handles
  both and remembers a profile for each.
- As a user with two identical keyboards, I can tell them apart and configure
  them independently.
- As a contributor, I can add a model by writing one description file, without
  touching the protocol code.
- As a user of an unsupported model, the app says so clearly instead of
  half-working.

## 6. Functional requirements
- FR-1: `DeviceModel` describes: `vendorID`, `productID`, usage page/usage,
  feature and output report sizes, `deviceKeyIndexToHID`, ignored codes, LED
  list, actuation curve, layout geometry, and a `capabilities` set
  (`oled`, `secondActuation`, `rapidTap`, `bindings`, `macros`).
- FR-2: All protocol builders take the model (or a context holding it); no
  builder references a concrete model type.
- FR-3: A `DeviceRegistry` discovers **all** matching devices, keyed by a stable
  identity (`LocationID` + product, since these devices report no serial), and
  publishes attach/detach.
- FR-4: Each device gets its own `ApexDevice`, controller, and lighting engine;
  frame streaming for two devices must not interfere (independent timers,
  independent throttling).
- FR-5: The UI gains a device switcher when more than one is present, and is
  unchanged when exactly one is. Profiles record which model they were authored
  for and refuse to apply to an incompatible one, with an explanation.
- FR-6: A feature whose capability flag is absent is **hidden**, not disabled —
  a keyboard with no OLED should not show an OLED pane.
- FR-7: Adding `0x1628` requires only a new model description plus its actuation
  curve; this is the acceptance test for the abstraction.
- FR-8: An unknown SteelSeries keyboard is detected and reported ("Apex 5
  detected — not supported yet") rather than ignored silently.
- FR-9: `apexctl` gains `--device <id>` and a `devices` subcommand; with one
  device connected, behaviour is unchanged.

## 7. UX / UI design
- With one device: **no visible change at all.** That is a hard requirement —
  this refactor must not tax the common case.
- With several: a compact device switcher in the sidebar header showing model
  name and a per-device connection dot; the rest of the app follows the
  selection.
- Profiles list shows a small model tag when the library contains profiles for
  more than one model.
- **Unsupported device state:** a card naming the model, linking to the
  "add a model" guide, and offering to file an issue with the report descriptor
  attached (ties to PRD-35's support bundle).

## 8. Technical design
- **ApexKit:**
  - `DeviceModel` (value type) + a `Models` namespace with `apexProTKLGen3`,
    `apexProTKL2022`, …
  - `ApexProTKLGen3` becomes a deprecated alias over `Models.apexProTKLGen3` so
    the migration is mechanical and reviewable.
  - Builders move from `enum` namespaces to methods on a `ProtocolBuilder`
    holding a model, or take `model:` as a first parameter — the former reads
    better at call sites.
  - `HIDTransport` gains multi-device matching and an identity; `ApexDevice`
    takes a model and a specific device handle.
- **App:** `DeviceRegistry` (`ObservableObject`) owning `[DeviceSession]`, each
  with its own `DeviceController`; `AppEnvironment` holds the registry, and views
  read the selected session.
- **Data model:** `SoftwareProfile` gains `modelID: String?` (optional, so
  existing profiles keep loading per PRD-06 FR-1).

## 9. Edge cases & risks
- **This is a wide refactor of code that is currently correct and
  hardware-verified.** The mitigation is that the protocol tests are already
  golden-byte tests: they must be re-expressed per model and must produce
  byte-identical output for `0x1642` before and after.
- **Identity without serial numbers** — two identical keyboards can only be told
  apart by USB topology, which changes when they are re-plugged into different
  ports. The UI must let the user name them and must not silently apply device A's
  profile to device B after a re-plug.
- **Bandwidth**: two keyboards at 30 fps each doubles USB control traffic; the
  power budget (PRD-36) needs to account for it.
- **Model descriptions drift from firmware** — a model whose curve or key table
  is wrong will misconfigure a stranger's keyboard. Every added model needs
  either hardware verification or a clear "community-contributed, unverified"
  label in the UI.
- **Capability flags hiding real features** — a wrong flag makes a feature
  invisible with no error; the model description needs its own tests.

## 10. Acceptance criteria
- AC-1: Every existing protocol test passes with byte-identical output after the
  refactor.
- AC-2: `Models.apexProTKL2022` is added with no changes to protocol code.
- AC-3: With two devices connected, both appear, both can be configured, and a
  change to one does not affect the other.
- AC-4: A profile authored for a model with an OLED refuses to apply to one
  without, with a readable message.
- AC-5: With one device connected, the UI is pixel-identical to before.
- AC-6: An unsupported SteelSeries keyboard produces the "not supported yet"
  card and a copyable report descriptor.

## 11. Effort & milestones
**L.** M1: `DeviceModel` + parameterised builders, with byte-identical golden
tests. M2: registry, multi-device transport and identity. M3: per-device sessions
and the switcher. M4: add `0x1628`; capability gating. M5: unsupported-device
reporting and the contributor guide.

## 12. Open questions
- Is USB `LocationID` a good enough identity for two identical keyboards, or
  should we ask the user to name each and match on "last seen at this port"?
- Do we attempt `0x1640` (full-size Gen 3) without hardware to test on, marked
  unverified, or refuse to ship models nobody has verified?
- Should `apexctl` default to "all devices" or "the only device", and what does
  it do when several are present and none is specified?
- Does the older single-byte command set deserve support at all, or is drawing the
  line at the 2022 platform the right scope?
