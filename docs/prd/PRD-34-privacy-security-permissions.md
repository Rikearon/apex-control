# PRD-34: Privacy, Security & Permission Model

- **Priority:** P0
- **Status:** Partially implemented. Done: `SECURITY.md` with a private reporting
  channel (FR-9), and `docs/PRIVACY.md`, which says what the app stores and shows how
  to check the no-network promise (the plain-language core of FR-2; for FR-7, the
  guard in `make check` is a source-level search, not a check of the built binary).
  Not done: the threat-model document (FR-1), the in-app privacy statement and
  permissions page (FR-2, FR-3), input-hardening tests (FR-4), path consent (FR-5),
  trust tiers (FR-6), the local socket (FR-8) and data deletion (FR-10).
- **Depends on:** — (gates PRD-24 scripting; informs PRD-20, PRD-21, PRD-22, PRD-25, PRD-32)
- **Firmware basis:** none — but the device access we already have is the reason
  this matters.

## 1. Summary
This app reads your keystrokes when you choose Reactive lighting, opens a raw USB
HID interface, and accepts configuration files from other people; planned features
would add screen and audio capture and, eventually, scripts from the internet.
`docs/PRIVACY.md` and `SECURITY.md` now say what the app does and how to report a
problem, and `make check` fails on networking code, but there is no threat model
and none of the controls exist inside the app yet. This PRD writes the security
model, implements the controls that back it up, and makes the promises checkable.

## 2. Background & GG parity
Not a parity feature. One reason to run a community app is trust: no account, no
telemetry, no cloud. That is a claim made by absence rather than a commitment
anyone can verify, and the point of this PRD is to make it checkable —
"checkable" is the operative word. It makes no claim about how any other software
behaves.

There is also a concrete risk that grows with every feature. Profiles are
importable JSON (PRD-06 FR-9). Today they hold settings only — lighting,
actuation, rapid tap, bindings and the OLED settings — and nothing in a profile is
executed; the only path a profile carries is the OLED image path, which the app
opens as an image when it renders that profile. That changes if PRD-01's host
actions (FR-6: launch an app, insert text) are built: a profile could then name a
program to run, and importing a teammate's file would mean accepting that. That
is defensible with the right UI and indefensible without one, so the controls
below have to exist before the feature does.

## 3. Technical basis (grounded)
- **Permissions the app can request** and exactly why:
  - **Input Monitoring or Accessibility** — reactive lighting today. The app asks
    for both, and either is enough for a listen-only tap; PRD-20's analytics would
    use the same tap. PRD-19's key engine needs **Accessibility**, because it
    replaces or suppresses events. Accessibility is the most powerful permission
    the app asks for: it grants the ability to observe and synthesise input
    globally.
  - **Screen Recording** — PRD-21 ambient lighting and PRD-22 audio.
  - **Calendar** — PRD-23's meeting indicator only.
  - **HID device access** — needs no permission for vendor usage pages, which is
    itself worth stating, because users reasonably wonder.
- **Attack surfaces that exist now**: imported profile JSON (untrusted input into
  a decoder, including the OLED image path, which the app opens as an image when
  it renders that profile); the corrupt-file rename path in `ProfileStore`
  (writes a file named from a timestamp — safe, but the pattern needs review);
  `apexctl raw` (arbitrary bytes to the device, by design); and one subprocess:
  the "Quit and reopen" button the Lighting pane offers after Input Monitoring is
  granted (macOS applies that permission only to processes that start afterwards)
  makes `AppRelaunch` start `/bin/sh -c 'sleep 1; /usr/bin/open "$0"'` with the
  app's own bundle path as its only argument. Nothing from a file or a profile
  reaches that command line.
- **Attack surfaces coming**: PRD-25's local socket (any local process can drive
  the keyboard), PRD-24's script execution, PRD-32's update channel (which can
  replace the app binary).
- **What we can prove rather than assert**: no network code paths in the app
  today. `make check` (which CI runs) already fails on networking APIs under
  `Sources/`; a stronger check on the linked binary's symbols would fail if that
  changed without a corresponding entitlement-and-docs update.

## 4. Goals / Non-goals
- **Goals:** a written threat model and a `SECURITY.md`; a plain-language privacy
  statement in-app and in the README; least-privilege permission requests with
  in-context explanations; hardened handling of all untrusted input; explicit
  trust boundaries for imported artefacts; a no-network commitment enforced in
  CI; a vulnerability reporting path.
- **Non-goals:** sandboxing the app (incompatible with HID access, see PRD-32);
  encrypting local configuration (it protects nothing an attacker with file
  access could not get otherwise); a bug bounty.

## 5. User stories
- As a privacy-minded user, I can read one page that tells me exactly what leaves
  my machine (nothing) and what is stored locally.
- As a user, the app asks for a permission only when I turn on a feature that
  needs it, and tells me why before the system prompt.
- As a user importing a colleague's profile, I am told it contains an app-launch
  binding and shown the path before I accept it.
- As a security researcher, there is a documented way to report an issue.
- As a maintainer, CI fails if someone adds a network call.

## 6. Functional requirements
- FR-1: **Threat model document** covering: untrusted profile/effect files, the
  local IPC socket, the update channel, the device itself as an input, and a
  hostile local process — each with the mitigation and the residual risk.
- FR-2: **Privacy statement** in Settings and the README, in plain language:
  what is collected (nothing transmitted), what is stored, where, and how to
  delete it. It must enumerate every file the app writes.
- FR-3: **Permission hygiene**: each permission is requested at the moment of
  first use, preceded by an in-app explanation naming the feature; every feature
  that lacks its permission degrades with a readable state rather than failing;
  a Settings page lists each permission, whether it is granted, and what it is
  for, with a link to revoke.
- FR-4: **Untrusted input hardening**: profile and effect decoding is bounded
  (maximum file size, maximum array lengths, no unbounded recursion); malformed
  input never crashes and never partially applies; every decoder has a fuzz or
  property test with malformed corpora.
- FR-5: **Path handling**: any path from a file (today the OLED image path; a
  `launchApp` path if PRD-01's host actions are built) is displayed to the user
  before first use, is never executed on import, and is resolved without
  following into unexpected locations; imported profiles with launch bindings, if
  they exist, are flagged in the import sheet.
- FR-6: **Trust tiers** are named and enforced: *data* (profiles, snapshots,
  images — inert), *paths* (require disclosure and consent), *code* (effect
  scripts — require explicit review and consent, PRD-24). A lower tier must never
  be able to escalate — specifically, a profile can never carry a script.
- FR-7: **No network**: the app makes no network connection. CI asserts that the
  binary links no networking symbol beyond what the update checker (PRD-32)
  requires, and the update checker is the *only* exception, is documented, and is
  disableable.
- FR-8: **Local socket** (PRD-25) is 0600 in the user's own container, is
  disableable, and is documented as "any process running as you can drive your
  keyboard" — which is true with or without us.
- FR-9: `SECURITY.md` with a reporting channel and expected response time (it
  exists: private reporting through GitHub, acknowledgement within about a week).
- FR-10: A **data deletion** action that removes every file the app has written,
  listed explicitly, with a confirmation.

## 7. UX / UI design
- **Settings → Privacy & Permissions**: a table of permissions (name, status,
  which feature needs it, revoke link), then the privacy statement, then
  "Delete all Apex Control data".
- **Permission pre-prompts**: a sheet before every system prompt, one paragraph,
  naming the feature and what the app will do with the access — never a generic
  "this app needs permissions".
- **Import review sheet** (profiles): a summary of what the file changes, with
  any file paths shown exactly as written — under a "This profile can launch
  programs" heading once launch bindings exist. Import is not the same as trust.
- **No dark patterns**: the "deny" path is always as prominent as "allow", and
  denying never nags.

## 8. Technical design
- **ApexKit:** decoding limits in the `Codable` layer (`HIDMap` already skips junk
  keys — extend the same tolerance-without-crashing discipline to every decoder);
  a shared `DecodingLimits` used by profile, effect, and snapshot decoders.
- **App:** `PermissionCenter` — one place that knows every permission, its
  status, the feature that needs it, and the explanation; views ask it rather
  than calling TCC APIs directly. `ImportReview` for the disclosure sheet.
  `DataInventory` — the single list of files the app writes, used by both the
  privacy statement and the delete action, so they cannot drift.
- **CI:** a job that greps the linked symbols for networking and fails on
  unexpected additions; fuzz corpora for the decoders committed to the repo.

## 9. Edge cases & risks
- **Input Monitoring and Accessibility are keylogger-class permissions.** Reactive
  lighting needs one of them today, and planned features want more. The honest
  framing is that granting either lets the app see everything you type, and the
  mitigation is that nothing is stored (PRD-20's aggregates are content-free by
  construction) and nothing is sent. That claim has to remain true as features
  are added, which is what makes the no-network CI check load-bearing rather than
  decorative.
- **The update channel is the highest-value target** — it can replace the binary.
  It must be signed, and "never install without consent" must hold.
- **Scripting (PRD-24) breaks the trust model if rushed.** This PRD should gate
  it: no script execution ships before the review sheet, the empty context, and
  the watchdog.
- **A local socket is not a vulnerability but looks like one** to a reviewer; the
  documentation must explain that any process running as the user could already
  open the HID device directly.
- **Over-promising privacy** is itself a risk: if a future feature needs the
  network (a preset gallery, PRD-37), the statement must change *before* the
  feature ships, not after.
- **Deleting all data** must not leave the device configured in a way the user
  cannot undo — it should offer to reset bindings too (PRD-29).

## 10. Acceptance criteria
- AC-1: `SECURITY.md`, the threat model, and the in-app privacy statement exist,
  and the statement's file list matches `DataInventory` exactly (asserted by
  test).
- AC-2: No permission is requested at launch; each is requested only when its
  feature is enabled, and each is preceded by an explanation.
- AC-3: A corpus of malformed profile and snapshot files decodes without a crash
  and without partial application.
- AC-4: A profile that names an OLED image path — and, once PRD-01's host actions
  exist, one containing a `launchApp` binding — shows the path in the import
  sheet, and importing it neither opens the file nor launches anything.
- AC-5: A test proves a profile file cannot carry effect-script source.
- AC-6: CI fails when a network symbol is introduced without updating the
  documented exception.
- AC-7: "Delete all data" removes every file listed in the privacy statement.

## 11. Effort & milestones
**M.** M1: threat model, `SECURITY.md`, privacy statement, `DataInventory`.
M2: `PermissionCenter` and pre-prompts across existing features. M3: decoder
limits and fuzz corpora. M4: import review sheet and trust tiers. M5: CI
no-network check and the delete action.

## 12. Open questions
- Is the no-network commitment absolute, or does the update checker make it
  "no network except an explicit, disableable update check"? The wording matters
  and should be settled before it is published.
- Should `apexctl raw` be gated behind a flag or a confirmation, given it can
  write arbitrary bytes to the device — or is a CLI escape hatch acceptable
  precisely because it is a CLI?
- How do we make the "content-free aggregates" claim in PRD-20 verifiable to a
  sceptical user — a documented schema, or a viewer that shows them exactly the
  stored file?
- Does accepting community-contributed *device models* (PRD-27) constitute a
  trust tier of its own, given a wrong model misconfigures hardware?
