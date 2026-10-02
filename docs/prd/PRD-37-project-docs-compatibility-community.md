# PRD-37: Project Documentation, Compatibility Matrix & Community

- **Priority:** P1
- **Status:** Partially implemented. Done: the licence (MIT for code, CC BY 4.0 for
  `docs/PROTOCOL.md`), a governance and continuity statement, the trademark note and the
  README rework (FR-7, FR-9, FR-10; M1); `CONTRIBUTING.md` (FR-4; M2); audience-routed
  docs (FR-1); issue forms and a PR template (FR-6; M4); a hand-maintained
  `docs/COMPATIBILITY.md` (FR-2, without the generator); a changelog and a CI check of
  documentation links and PRD cross-references (FR-8, AC-7; M5). Not done: provenance tags on
  every `PROTOCOL.md` claim (FR-3), the sources-and-confidence page (FR-5), and the matrix
  generator.
- **Depends on:** — (consumes PRD-30's capability reports and PRD-27's model
  descriptions; governance decisions here gate PRD-32)
- **Firmware basis:** none — this is about the project, not the device.

## 1. Summary
The most valuable thing this project has produced is not the app; it is a
detailed, hardware-verified description of a protocol for which the vendor
publishes no specification that we know of. That knowledge currently lives in one
`PROTOCOL.md`, a set of PRDs, and the author's own captures and notes. This PRD
turns the project into something other people can use, verify, extend, and
outlive its author.

## 2. Background & GG parity
There is no parity comparison to make: the vendor publishes no protocol
specification for this keyboard that we know of. The relevant comparison is the
community projects this one already cross-checks against —
OpenRGB, apex-tux, OmniLED — each of which is valuable to people who will never
run their code, because they documented what they learned. That is the standard
to meet.

The problem this PRD was written to solve (the Status line above says how much of
it is now done): the repository had a README, a protocol reference, a gap analysis
and PRDs, but no contributing guide, no licence discussion in the README beyond an
implicit one, no issue templates, no compatibility matrix, no statement of which
firmware versions anything was verified against, and no description of how someone
would add a model or check the protocol findings for themselves. A contributor with
a different Apex keyboard had no path in.

## 3. Technical basis (grounded)
- **What is already verified and worth publishing**: the `0x1642` command set;
  the three-layer mapping protocol including the reply header order and the
  self-mapping resting state; the nine factory `0x62` Fn functions; the LED /
  mappable / analog set sizes (86 / 91 / 68) and why they differ; the full USB
  interface map including the mouse collection hidden behind a consumer primary
  usage. All of this was established on hardware, and as far as we know none of it
  is documented elsewhere.
- **What anyone with the hardware can check**: most wire findings can be tried on
  a real keyboard with `apexctl` (`apexctl raw` sends exactly the bytes you give it),
  and `PROTOCOL.md` says how each claim was verified. What the repository does not
  contain is any vendor file or code (see `CONTRIBUTING.md`), so a claim tagged
  *from descriptor* can be tested against a keyboard but not against the material
  it came from. Saying plainly which claims rest on what is what lets someone else
  verify our claims or extend to another model.
- **Licensing** (decided): MIT for the code, and CC BY 4.0 for the protocol
  *documentation*, because its value is in being copied.
- **Capability reports** (PRD-30) and **model descriptions** (PRD-27) are the
  natural unit of community contribution: both are data, verifiable, and
  submittable by someone who cannot write Swift.

## 4. Goals / Non-goals
- **Goals:** a documentation site or well-structured `docs/` with a clear entry
  point per audience; a compatibility matrix (model × firmware × what works ×
  who verified it); a contributing guide including how to add a model and how to
  check protocol claims on your own keyboard; issue and PR templates; explicit
  licences for code and docs; a governance and continuity statement; a changelog; a
  place for community capability reports.
- **Non-goals:** redistributing SteelSeries' files or code in any form (they are not
  ours to publish); a forum or chat we cannot staff; accepting binary
  contributions; a preset/effect gallery hosted by us (that needs the
  privacy and moderation answers in PRD-34 first).

## 5. User stories
- As someone with an Apex Pro TKL, I can tell at a glance whether my model and
  firmware are supported and what works.
- As a contributor, I can add support for my keyboard by following a written
  guide.
- As a researcher, I can check the protocol findings against my own keyboard
  rather than trusting them.
- As a maintainer, issues arrive with the information needed to act on them.
- As a user, I can see what changed between versions.
- As someone considering depending on this project, I can see how it is governed
  and what happens if the author stops.

## 6. Functional requirements
- FR-1: **Audience-routed docs**: a top-level index directing to *Using the app*,
  *Using the CLI*, *The protocol*, *Contributing*, *Adding a keyboard model*, and
  *Security & privacy* — each a real page, not a stub.
- FR-2: **Compatibility matrix** in `docs/COMPATIBILITY.md`: rows of
  model + PID + firmware version; columns for lighting, actuation, rapid trigger,
  rapid tap, bindings, read-back, OLED, onboard profiles; each cell
  verified / unsupported / untested, with the verifier and date. Generated from
  PRD-30's capability reports where they exist.
- FR-3: **Verification provenance**: every claim in `docs/PROTOCOL.md` is tagged
  *verified on hardware* (with firmware version), *from descriptor* (the vendor's
  description of the device, which this repository does not contain), or
  *inferred* — the discipline the document already mostly follows, made systematic
  and checkable.
- FR-4: **`CONTRIBUTING.md`** covering: building, running tests without hardware
  (PRD-31), the code conventions the project actually uses, how to add a device
  model, how to submit a capability report, and what will not be accepted.
- FR-5: **Sources and confidence page**: what each protocol claim rests on and how
  sure it is (confirmed on hardware, from the vendor's description of the device,
  taken from a public community project, or inferred), and an explicit statement
  that no vendor files are redistributed here.
- FR-6: **Issue templates**: bug (with a request for a PRD-35 support bundle),
  device support request (with report descriptors), and protocol finding.
- FR-7: **Licence**: a stated code licence in `LICENSE` and referenced in the
  README; a separate, permissive licence for `docs/PROTOCOL.md` so the protocol
  knowledge can be reused by other projects.
- FR-8: **Changelog** maintained per release, generated from PRs and edited for
  humans; referenced by the in-app update sheet (PRD-32).
- FR-9: **Governance & continuity**: who maintains it, how decisions are made,
  what happens to the signing identity and release channel if the maintainer
  stops (ties directly to PRD-32's open question).
- FR-10: A **legal/trademark note**: this is an independent project, not
  affiliated with SteelSeries; "SteelSeries" and "Apex" are used nominatively.
  The README says the first half of this already; it should be complete and in
  one place.

## 7. UX / UI design
- The repository *is* the UI here. The entry point is the README, which should
  answer, in order: what is this, does it work with my keyboard, how do I install
  it, what can it do, and where is the protocol.
- The compatibility matrix is the highest-traffic page after the README and
  should be a table a person can scan in ten seconds, not prose.
- In-app: an About panel linking to the docs, the protocol reference, the
  licence, and the compatibility matrix — so the app is a route into the project
  rather than a dead end.
- If a documentation site is built, it should be generated from the same
  `docs/` markdown, so there is exactly one source.

## 8. Technical design
- **Docs:** keep everything in `docs/` as markdown; optionally publish with a
  static generator via CI. The constraint is that the repo must stay the source
  of truth and readable on its own.
- **Matrix generation:** a script turning committed `CapabilityReport` JSON files
  (PRD-30) into `docs/COMPATIBILITY.md`, so the matrix cannot drift from the
  evidence.
- **Templates:** `.github/ISSUE_TEMPLATE/*.yml` with structured fields, and a PR
  template that asks which PRD a change relates to.
- **CI:** link checking across `docs/`, and a check that every PRD referenced in
  the gap analysis exists and vice versa.

## 9. Edge cases & risks
- **Provenance.** The position the project takes is that the *findings* are
  documented and checked against hardware, while the vendor's files and code are
  neither redistributed nor needed to use this software, and contributors must not
  add them (`CONTRIBUTING.md`). That is stated explicitly, in the README and in
  `docs/PROTOCOL.md`, rather than left implicit.
- **A compatibility matrix implies a support promise.** Cells must be labelled
  with who verified them and when, so an untested model reads as "nobody has
  tried" rather than "broken".
- **Community model contributions can damage hardware settings** if wrong
  (PRD-27 §9); the contribution guide must require either hardware verification
  or an explicit unverified label.
- **Documentation rot** is the default outcome; the CI link check and the
  generated matrix are the only parts that resist it automatically. Everything
  else depends on the habit of updating docs in the same PR — which this project
  has so far kept.
- **Governance is uncomfortable to write** and easy to postpone, but PRD-32 needs
  an answer before a signing identity is created.

## 10. Acceptance criteria
- AC-1: A new visitor can determine, from the README alone, whether their
  keyboard is supported and how to install the app.
- AC-2: `docs/COMPATIBILITY.md` exists, is generated from committed capability
  reports, and marks every cell with a source and date.
- AC-3: Every claim in `docs/PROTOCOL.md` carries a provenance tag.
- AC-4: A contributor can add a device model by following `CONTRIBUTING.md`
  without asking a question that the guide does not answer.
- AC-5: `LICENSE` exists, the README states it, and the protocol document carries
  its own licence.
- AC-6: Issue templates exist and a filed bug arrives with a support bundle
  attached.
- AC-7: CI fails on a broken internal documentation link or a PRD referenced but
  missing.

## 11. Effort & milestones
**S–M.** M1: licence, governance statement, trademark note, README rework.
M2: `CONTRIBUTING.md` and the sources-and-confidence page. M3: provenance tags
across `PROTOCOL.md`. M4: compatibility matrix generator + issue templates.
M5: changelog and the docs link check in CI.

## 12. Open questions
- Which code licence? A permissive one maximises reuse by other projects
  (OpenRGB is GPL-2.0, OmniLED GPL-3.0, apex-tux the Unlicense); the protocol document
  arguably wants CC-BY or public domain regardless of the code's licence.
  **Decided:** MIT for the code and CC BY 4.0 for `docs/PROTOCOL.md`.
- What may the repository contain from vendor material? **Decided:** nothing — no
  vendor files or code, and contributors must not add any (see
  `CONTRIBUTING.md`). It publishes the findings and how confident each one is.
- Should community capability reports live in this repo, or would that create an
  implicit endorsement of hardware nobody here has tested?
- Is a documentation site worth the maintenance, or does a well-organised `docs/`
  folder serve the audience better for a project this size?
