# PRD-26: Config-as-Code & Profile Sync

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-06 (profile model and store); pairs with PRD-25 (`apexctl apply` over IPC)
- **Firmware basis:** **host-side only.**

## 1. Summary
Profiles today are opaque UUID-keyed records in one `profiles.json` that the app
owns. This PRD adds the other way to work: a human-authored, version-controllable
configuration file that fully describes a setup, an `apexctl apply` that converges
the machine to it, and a sync story for people with more than one Mac.

## 2. Background & GG parity
As far as we know, GG keeps configuration in a local database plus a cloud
account, and has no plain-text form that can be diffed or kept in version control.
The audience for this project overlaps heavily with people who keep dotfiles in
git: they expect to check their keyboard config in next to their editor config, and
to reproduce it on a new machine with one command. The existing export (PRD-06
FR-9) produces a JSON blob with a UUID and timestamps in it, which is technically a
file but not something you want in a diff.

## 3. Technical basis (grounded)
- **Everything needed already exists**: `SoftwareProfile` is `Codable`, the
  per-key maps already serialise as readable hex-keyed objects
  (`HIDMap` encodes `"0x2C"`), and all apply paths are implemented and
  hardware-verified. This PRD is a *format and lifecycle* change, not a protocol
  one.
- **What blocks diffability today** (confidence: certain, from the current
  format): `id: UUID`, `createdAt`, `modifiedAt`, and dictionary ordering.
  Sorted keys are already on (`JSONEncoder.outputFormatting = [.sortedKeys]`), so
  the remaining work is a *declarative* schema that omits identity and time.
- **Format choice**: JSON is already there and needs no dependency. TOML/YAML
  read better for hand editing but each adds a parser. A defensible answer is
  JSON with a documented schema plus a JSON Schema file for editor completion —
  no new dependency, real editor support.
- **Sync**: iCloud Drive is a folder — writing the config there is free and needs
  no entitlement if the app is not sandboxed. `NSFileCoordinator`/`NSFilePresenter`
  handle multi-machine writes. Git is out of our hands and better for it.
- **Convergence**: `apply` must be idempotent, which the live command set already
  is (full frames everywhere), so a second `apply` is a visual no-op.

## 4. Goals / Non-goals
- **Goals:** a declarative, identity-free config format covering every setting;
  `apexctl apply <file>` / `export` / `diff` / `validate`; a JSON Schema; a
  watched-file mode that re-applies on change; optional iCloud/folder sync of the
  library with conflict handling; stable, review-friendly output.
- **Non-goals:** our own cloud service or accounts; a merge algorithm for
  conflicting edits (last-writer-wins plus a preserved copy is enough); syncing
  *device* state rather than *our* configuration (that is PRD-29); supporting
  arbitrary config languages.

## 5. User stories
- As a dotfiles user, my keyboard config lives in my repo and a new Mac is one
  command away from correct.
- As a reviewer, a change to my config shows up as three readable lines in a
  diff, not a re-serialised blob.
- As a team, we share a "studio standard" config file that everyone applies.
- As a two-Mac user, my profiles follow me without me exporting anything.
- As a cautious user, `apexctl diff` tells me what would change before I let it
  change anything.

## 6. Functional requirements
- FR-1: A **declarative document** describes zero or more named profiles, the
  onboard slot map, and app preferences. Names are the identity; no UUIDs, no
  timestamps in the file.
- FR-2: Keys are addressed by **name where unambiguous** (`"Caps"`, `"W"`) and
  by `0xNN` otherwise; the writer emits names, the reader accepts both.
- FR-3: `apexctl apply <file>` converges the machine: creates missing profiles,
  updates changed ones, optionally prunes ones absent from the file (`--prune`,
  off by default), and applies the file's active profile.
- FR-4: `apexctl diff <file>` prints a human-readable change list and exits
  non-zero when changes exist, so it is usable in CI or a pre-commit hook.
- FR-5: `apexctl validate <file>` checks schema and semantics (unknown key names,
  actuation out of range, more than 10 SOCD pairs, a key in two pairs) with line
  numbers, and never touches the device.
- FR-6: `apexctl export [--profile name]` writes the declarative form of the
  current state, and `export` followed by `apply` is a **no-op round trip**.
- FR-7: A JSON Schema is published in the repo and referenced from the file via
  `$schema`, so editors offer completion and inline validation.
- FR-8: **Watch mode** (`apexctl apply --watch`) re-applies on file change,
  debounced, with errors printed and the last good state retained.
- FR-9: **Sync**: an optional setting moves the library to a user-chosen folder
  (iCloud Drive, Dropbox, a git worktree). File changes made externally are
  picked up; a conflicting external change is preserved as
  `profiles-conflict-<timestamp>.json` and surfaced, never silently discarded.
- FR-10: Comments are supported in the authored file (JSON with `//` stripped
  before parsing, or a documented `_comment` convention) — a config format people
  cannot annotate does not get used.

## 7. UX / UI design
- Mostly a CLI feature, with three touchpoints in the app:
  - Settings → **Library location**: default, or a chosen folder, with a warning
    that sync services can produce conflicts.
  - Profiles pane → **Export as config…** producing the declarative form.
  - A conflict banner when an external change is detected, offering
    "Reload from disk" / "Keep mine".
- The CLI output is the real UI: `diff` must read like `git diff` — grouped by
  profile, one line per changed setting, with old → new.

## 8. Technical design
- **ApexKit:**
  - `DeclarativeConfig` — the authored schema, distinct from `SoftwareProfile`,
    with `init(from: SoftwareProfile)` and `func materialise() -> SoftwareProfile`.
    Keeping them separate is what lets the storage format evolve without breaking
    people's checked-in files.
  - `ConfigDiff` — pure comparison producing a printable change list; the same
    type powers `diff` and the app's conflict banner.
  - Key-name resolution reusing `ApexProTKLGen3.name(forHID:)` and `HIDUsage`.
- **App:** `ProfileStore` gains a relocatable directory, an `NSFilePresenter` for
  external changes, and conflict preservation.
- **apexctl:** `apply` / `diff` / `validate` / `export` subcommands, routed
  through PRD-25's socket when the app is running so the UI updates live.

## 9. Edge cases & risks
- **Two sources of truth.** The app writes `profiles.json`; the user writes
  `apex.json`. If both are authoritative, someone loses work. The resolution:
  the declarative file is *input*, never written by the app except on explicit
  export, and the app's library remains the runtime store.
- **Sync services and file locking** — iCloud can present a file mid-upload;
  `NSFileCoordinator` is mandatory, not optional.
- **Prune is destructive** and must stay opt-in with a confirmation.
- **Name collisions** — names are identity in the file but the library allows
  duplicates today (it appends " 2"); the importer must define exactly what
  happens.
- **Schema drift**: a file written for a newer app must fail loudly on `apply`
  (it may reference settings we cannot honour) while `validate` explains, rather
  than silently applying a subset.
- **Secrets**: nothing sensitive belongs in this file, and the schema should have
  no free-form fields that tempt people to put paths or tokens in it — except
  `launch app` bindings (if PRD-01's host actions are built), which are paths by
  nature and should be documented as such.

## 10. Acceptance criteria
- AC-1: `apexctl export > apex.json && apexctl apply apex.json` changes nothing
  and `apexctl diff apex.json` exits 0.
- AC-2: Editing one actuation value produces a one-line diff.
- AC-3: `apply` on a clean machine reproduces a full setup, verified by reading
  bindings and actuation back off the device.
- AC-4: `validate` catches an out-of-range actuation, an unknown key name, and a
  key used in two SOCD pairs, each with a line number.
- AC-5: An external edit to the synced library is picked up by the app, and a
  simultaneous edit produces a preserved conflict file plus a banner.
- AC-6: `apply --prune` requires confirmation and removes only profiles absent
  from the file.

## 11. Effort & milestones
**M.** M1: `DeclarativeConfig` + round-trip tests. M2: `apply`/`export`.
M3: `diff`/`validate` + JSON Schema. M4: watch mode. M5: relocatable library and
conflict handling.

## 12. Open questions
- JSON-with-comments vs. adding a TOML dependency — which does the target
  audience actually prefer, and is one dependency acceptable?
- Should the declarative file be able to describe *onboard slot contents* before
  PRD-05 exists, or would that promise something we cannot deliver?
- Is `--prune` worth the risk at all, or should removal always be manual?
- For sync, do we support "the library is a git repo" as a first-class mode
  (running `git pull` ourselves), or stay dumb and let the user's tooling do it?
