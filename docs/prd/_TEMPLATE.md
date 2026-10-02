# PRD-NN: Short title

- **Priority:** P0 / P1 / P2
- **Status:** Proposed
- **Depends on:** [PRD numbers or —]
- **Firmware basis:** [endpoints from FEATURE-GAP-ANALYSIS §B, or "host-side only"]

## 1. Summary
Two or three sentences: the problem, and the proposed solution.

## 2. Background & GG parity
What SteelSeries GG offers here (state only what you can support; otherwise say "as
far as we know"), why users want it, and what breaks without it. Compare, do not
judge: no put-downs of GG or of anyone else's software.

## 3. Technical basis (grounded)
The exact protocol commands / host APIs that enable this, with **confidence**
(confirmed on hardware / from descriptor — the vendor's description of the
device, which this repository does not contain / needs RE) and any **unknowns**.
Cite byte formats from `docs/PROTOCOL.md` where relevant. Describe behaviour in
your own words; do not quote vendor files or code.

## 4. Goals / Non-goals
- **Goals:** bullet list of what this delivers.
- **Non-goals:** explicitly out of scope (to avoid scope creep).

## 5. User stories
"As a *user*, I want *capability* so that *benefit*." 3–6 stories.

## 6. Functional requirements
Numbered, testable requirements (FR-1, FR-2, …). Include ranges, defaults, limits.

## 7. UX / UI design
Where it lives in the app, layout, interactions, empty/error states.

## 8. Technical design
- **ApexKit** changes (new protocol builders, models).
- **App** changes (views, controller, persistence).
- **Data model** (Codable structs, storage location).

## 9. Edge cases & risks
Failure modes, hardware quirks, safety (flash wear, bricking), permissions.

## 10. Acceptance criteria
Concrete, verifiable pass conditions (AC-1, AC-2, …), including hardware checks.

## 11. Effort & milestones
Rough size (S/M/L), and a milestone breakdown if multi-step.

## 12. Open questions
Things to resolve during implementation.
