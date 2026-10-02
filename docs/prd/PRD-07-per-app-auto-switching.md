# PRD-07: Per-Application Automatic Profile Switching

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** 06 — profile library + apply / switch primitives
- **Firmware basis:** **host-side only — no new protocol.** Reuses PRD-06's
  `apply(SoftwareProfile)` and the profile-load command (`B2 <id>`).

## 1. Summary
GG can automatically switch the active profile when a particular app or game comes to
the foreground — a competitive actuation arms itself on game launch, a dim "work"
lighting appears in the IDE. This PRD adds the same to Apex Control as a **pure
host-side automation layer**: watch which macOS app is frontmost, look it up in a
user-defined `{bundle ID → profile}` table, and apply the matching profile via PRD-06.
No new firmware commands are involved.

## 2. Background & GG parity
As far as we know, in GG a user associates a profile with an application; when that app becomes active the
keyboard reconfigures itself, and reverts (to a default) when they leave. This is the
payoff of having profiles at all — the right actuation/lighting appears without the user
ever opening the config app. Apex Control has profiles (PRD-06) but they are manual.
Gamers especially expect their competitive actuation to arm itself when the game
launches and relax back to a comfortable typing profile in chat or a browser; doing it
by hand defeats the purpose.

## 3. Technical basis (grounded)
- **Foreground detection (host-side, confirmed).** `NSWorkspace.shared.notificationCenter`
  posts `didActivateApplicationNotification` on every app switch; the payload's
  `NSWorkspaceApplicationKey` (an `NSRunningApplication`) yields `.bundleIdentifier`.
  `NSWorkspace.shared.frontmostApplication` gives the current one at startup. This is
  standard AppKit and requires **no entitlement and no Accessibility permission** to read
  the frontmost app's bundle identifier (unlike keystroke/Accessibility APIs).
  Confidence: **confirmed** (documented AppKit behavior).
- **Lookup + apply.** On each activation: read `bundleIdentifier`, find the
  highest-priority matching rule, and — if it differs from the currently-applied
  profile — call PRD-06 to apply it (software-profile push and/or the profile-load command onto the
  mapped onboard slot, `B2 <id>`). If no rule matches, apply the configured
  **default/fallback** profile. No new protocol — orchestration over PRD-06.
- **Debounce.** Rapid ⌘-Tab bursts fire many activations per second; applying a profile
  is several USB writes. A short coalescing debounce (~250–400 ms, tunable) ensures only
  the *settled* frontmost app triggers an apply. Confidence: host-side design choice.
- **No reliable full-screen / per-window signal.** macOS exposes the frontmost
  *application*, not a robust "is this a full-screen game" flag without extra APIs;
  full-screen games still post normal activations (so they work), but we cannot
  special-case them purely from `NSWorkspace`. Treated as an edge case (§9), not a
  blocker.

## 4. Goals / Non-goals
- **Goals:**
  - A **rules table**: rows of *application → profile*, evaluated on foreground change,
    plus a **default/fallback** profile for unmatched apps.
  - An **add-app picker**: choose from currently running apps or browse for a `.app`
    bundle; resolve and store its bundle identifier.
  - **Enable/disable** automation globally (master switch) and per rule.
  - **Priority / ordering** so overlapping rules resolve deterministically.
  - A **live indicator** of which rule/profile is currently auto-applied.
  - **Debounce** to avoid thrashing on fast app switches.
- **Non-goals:**
  - Any new firmware protocol — host-side only; the switch primitive is PRD-06.
  - Per-window, per-document, or per-URL rules (application granularity only).
  - Detecting specific games beyond their bundle identifier / executable.
  - Editing profile *contents* (PRD-06 owns that).

## 5. User stories
- As a gamer, I map `com.valvesoftware.csgo` to "CS2" so my 0.3 mm actuation arms itself
  when the game is focused and relaxes when I alt-tab to Discord.
- As a developer, I map my IDE's bundle ID to a dim, distraction-free lighting profile,
  and set "Default" for everything else.
- As a user, I pick a running app from a list instead of hunting for its bundle
  identifier.
- As a user, I toggle automation off entirely for manual control, without deleting my
  rules.
- As a user, I glance at the pane and see "Active: CS2 (via Counter-Strike 2)" so I know
  why the keyboard looks the way it does.

## 6. Functional requirements
- FR-1: Observe `NSWorkspace` `didActivateApplicationNotification`; on each event extract
  the frontmost app's `bundleIdentifier`.
- FR-2: Maintain an ordered list of rules `{ bundleID, profileID, enabled }` plus a
  **default profile** applied when no enabled rule matches.
- FR-3: On a settled activation, resolve the first enabled matching rule by priority
  order and, **if the resolved profile differs from the currently-applied one**, apply it
  via PRD-06; otherwise do nothing.
- FR-4: **Debounce** activations (default ~300 ms, configurable) so only the final
  frontmost app in a burst triggers an apply; never issue overlapping applies.
- FR-5: Add a rule via a picker listing running apps (name + icon + bundle ID) or an
  "Other…" file-browse to a `.app`; dedupe by bundle ID.
- FR-6: Edit a rule's target profile, reorder rules (priority), enable/disable a rule,
  and delete a rule.
- FR-7: A global **automation on/off** switch; when off, no activation triggers any
  apply and the last manual state is retained.
- FR-8: Persist rules + default + enabled state alongside the profile library (PRD-06
  store).
- FR-9: Surface the **currently auto-applied** profile and the app that triggered it;
  update it live on switches.
- FR-10: If a rule references a deleted profile, mark it invalid (no apply) and prompt
  the user to fix it, rather than failing silently.

## 7. UX / UI design
- An **Automation** section within the Profiles pane (PRD-06):
  - A master **Enable automatic switching** toggle at the top.
  - A **rules table**: columns *App* (icon + name), *Profile* (picker of software
    profiles), *Enabled* (checkbox), and a drag handle for priority. A pinned
    **Default (fallback)** row at the bottom that can't be deleted.
  - **Add app** button → sheet with two tabs: *Running apps*
    (live `NSWorkspace.runningApplications`, regular activation-policy apps only) and
    *Browse…* for a `.app`.
  - A status line: "Active profile: **CS2** — triggered by Counter-Strike 2", or
    "Automation off".
- **Empty state:** with no rules, show an explainer and the Default row; automation
  defaults **off** until the user adds at least one rule.
- **Error states:** a rule whose profile was deleted renders in a warning style with
  "Choose a profile"; a `.app` with no readable bundle ID is rejected in the picker.

## 8. Technical design
- **ApexKit:** none — no protocol changes. All device effects go through PRD-06's
  `apply` / the profile-load command.
- **App:**
  - `AppSwitchMonitor` — wraps `NSWorkspace.shared.notificationCenter` observation of
    `didActivateApplicationNotification`, publishing a debounced `frontmostBundleID`.
    Started/stopped by the automation master switch. Debounce via a Combine `debounce`
    (or a `Task` + `Clock.sleep`) on the main actor.
  - `AutomationEngine` — holds `[SwitchRule]` + `defaultProfileID`, subscribes to
    `AppSwitchMonitor`, resolves the target profile, and calls
    `DeviceController.apply(_:)` (PRD-06) only when the resolved profile changes.
  - `AutomationView` — the rules table + add-app sheet + status line, inside the Profiles
    pane.
  - App picker uses `NSWorkspace.shared.runningApplications` filtered to
    `.activationPolicy == .regular`, showing `localizedName`, `icon`,
    `bundleIdentifier`.
- **Data model:**
  ```
  struct SwitchRule: Codable, Identifiable {
    let id: UUID
    var bundleID: String
    var profileID: UUID
    var enabled: Bool
  }
  struct AutomationConfig: Codable {
    var isEnabled: Bool
    var rules: [SwitchRule]        // order = priority
    var defaultProfileID: UUID?
  }
  ```
  Persisted with the PRD-06 store (same Application Support location).

## 9. Edge cases & risks
- **Rapid app switching (⌘-Tab):** without debounce, dozens of applies fire and the
  keyboard visibly thrashes; the debounce (FR-4) plus "skip if unchanged" (FR-3) prevent
  it. Never let two applies overlap.
- **App with no rule:** falls through to the **default** profile; if no default is set,
  do nothing (keep current state) rather than blanking the keyboard.
- **App quitting / desktop focus:** quitting a game returns focus to Finder or another
  app, which re-evaluates normally. If focus lands on Apex Control itself, do **not**
  treat that as a trigger to change (optionally ignore our own bundle ID).
- **Full-screen games:** they post normal activations so switching works, but some games
  grab the device or mask activation; if a game doesn't trigger, the user can still
  switch manually, and we document the limitation.
- **Onboard-slot rules vs live-push rules:** a rule may map to a profile that also lives
  on an onboard slot; prefer the live software push for instant, non-flash switching and
  only use the profile-load command when the user explicitly wants the onboard slot — **never write
  flash on an automatic switch** (flash-wear safety; the flash ops `0x02`/`0x03`/`0xB1`
  belong to PRD-05 and must never fire here).
- **Deleted/renamed profile referenced by a rule:** invalidate the rule (FR-10); never
  apply a missing profile.
- **Privacy:** we read only the frontmost app's bundle identifier via public AppKit — no
  Accessibility permission, no keystroke access, no window contents. State this in copy
  so the automation doesn't look invasive.

## 10. Acceptance criteria
- AC-1: With a rule `bundleID(game) → "CS2"` and default "Work", focusing the game
  applies "CS2" and focusing another app applies "Work", verified by the keyboard's live
  state.
- AC-2: A fast ⌘-Tab burst across three apps results in **exactly one** apply — the
  settled frontmost app's profile (debounce works).
- AC-3: Adding an app via the running-apps picker stores the correct bundle identifier
  and immediately participates in switching.
- AC-4: Toggling automation off stops all automatic applies; toggling on resumes without
  a relaunch.
- AC-5: A rule pointing at a deleted profile does not apply and is flagged in the UI.
- AC-6: No automatic switch ever triggers a flash write — confirmed by the absence of
  `0x02`/`0x03`/`0xB1` (PRD-05) traffic on switches; only live pushes / the profile-load command
  appear.

## 11. Effort & milestones
**M.** M1: `AppSwitchMonitor` (observe + debounce) with a visible "frontmost app"
readout. M2: `AutomationEngine` + rule model + resolve/apply against PRD-06. M3:
Automation UI (rules table, add-app sheet, status line, master toggle). M4: persistence
+ edge-case handling (deleted profiles, fallback, self-ignore).

## 12. Open questions
- Should leaving a matched app **revert** to the previously-applied profile, or only ever
  move to the *default* when the new app has no rule? (Revert-stack vs flat default.)
- Debounce default — is ~300 ms the right balance between responsiveness and anti-thrash
  for a fast alt-tabber?
- Do we ignore Apex Control's own activation (so opening the app to edit doesn't change
  the keyboard), and menu-bar/agent apps with `.activationPolicy != .regular`?
- Is bundle-ID granularity enough, or will users want per-executable rules for launchers
  (e.g. Steam) that shell out to a different process?
- Should a *manual* profile switch temporarily **pin** (suspend automation) until the
  user un-pins, so automation doesn't immediately override a deliberate choice?
