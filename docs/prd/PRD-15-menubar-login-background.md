# PRD-15: Menu-Bar App, Launch-at-Login & Background Operation

- **Priority:** P0
- **Status:** Implemented
- **Depends on:** — (independent; complements PRD-09 by making software effects
  survive reboots without onboard RE; pairs with PRD-06 profiles)
- **Firmware basis:** host-side only (AppKit / SwiftUI: `NSStatusItem`,
  `SMAppService`, `NSApplication` activation policy, `NSWorkspace` notifications).
  Reuses the existing `direct_write` enable/frame path on wake.

## 1. Summary
Apex Control today is a **regular windowed app** (activation policy `.regular`): it
drives lighting/OLED only while open, occupies the Dock, and **stops driving effects
the moment it quits**. GG runs as a background utility that keeps the
keyboard configured across reboots. This PRD turns Apex Control into a proper macOS
background companion: a **menu-bar item** with quick controls, **launch at login**
via `SMAppService`, **background operation** with the main window closed (optionally
Dock-less), and **automatic re-apply of the last profile on login and wake**. This is
what makes our software lighting/effects persist across reboots **without** the risky
onboard-effect reverse engineering of PRD-09.

## 2. Background & GG parity
Users expect a peripheral app to be invisible and always-on: set it once, reboot, and
the keyboard still looks and behaves the way it was left — no window to reopen, no Dock
clutter. As far as we know, GG runs a background service for this. Because our best
lighting (PRD-08) is *software-rendered on the host*, "persistence" for those effects
is fundamentally a **host uptime** problem, not a firmware one: if the app is running
in the background from login, the effects are simply always there. That makes this the
cheapest high-value route to "my keyboard looks right after every reboot," and a
complement to (not a substitute for) genuine onboard persistence.

## 3. Technical basis (grounded)
- **Menu-bar item.** `NSStatusBar.system.statusItem(withLength:)` yields an
  `NSStatusItem`; attach an `NSMenu` (or a SwiftUI `MenuBarExtra` on macOS 13+) with
  the quick controls. Confidence: **standard AppKit**, no device dependency.
- **Launch at login.** `SMAppService.mainApp.register()` (macOS 13+) registers the
  app itself as a login item; `.unregister()` removes it; `.status` reflects the
  System Settings › General › Login Items state (the user can also toggle it there).
  For a Dock-less agent variant, `SMAppService.loginItem(identifier:)` / a bundled
  `LoginItems` helper is the fallback for older systems. Confidence: **documented
  Apple API**; requires the app to be code-signed and (for reliable registration)
  in `/Applications`.
- **Background & Dock icon.** `NSApplication.setActivationPolicy(_:)` switches
  between `.regular` (Dock + menu bar, today's behaviour) and `.accessory` (menu-bar
  only, **no Dock icon**, no app menu). Keeping the process alive with no window
  requires `applicationShouldTerminateAfterLastWindowClosed → false` so closing the
  window backgrounds rather than quits the app. The 30 fps `LightingEngine` and OLED
  loop keep running unchanged. Confidence: **standard AppKit**.
- **Login / wake re-apply.** Apply the last profile in
  `applicationDidFinishLaunching` (login) and on
  `NSWorkspace.didWakeNotification` (via `NSWorkspace.shared.notificationCenter`).
  On wake/replug the keyboard does **not** auto-restore host direct mode — per
  PROTOCOL.md it needs the enable (`4B`) sent again and a fresh full frame (and a
  `41` clear when handing back), and the OLED image re-pushed. Optionally pause the
  engine on `willSleepNotification` to save power and re-arm on wake.
- **Confidence:** entirely host-side and built on documented AppKit/`ServiceManagement`
  APIs; the only device interaction (re-enable + resend on wake) reuses commands
  already **confirmed on hardware**.

## 4. Goals / Non-goals
- **Goals:** an `NSStatusItem` menu with quick controls; a Settings toggle for
  **start at login** (`SMAppService`); **run in background** (engine + OLED alive
  with the window closed); a **show/hide Dock icon** option (`.regular` ↔
  `.accessory`); **auto-apply last profile** on login and on wake; safe re-enable of
  direct mode on wake/reconnect.
- **Non-goals:** onboard flash persistence (PRD-05) or onboard effects (PRD-09) —
  this is the *host-uptime* answer, not the *firmware* one; a fully headless
  daemon with no UI at all; auto-update; multi-user/system-wide install.

## 5. User stories
- As a user, I close the window and the keyboard keeps its effect and OLED running —
  the app just moves to the menu bar.
- As a user, I enable "Start at login" and after a reboot my lighting is already on
  with no window ever opening.
- As a minimalist, I hide the Dock icon so Apex Control lives only in the menu bar.
- As a user, from the menu bar I flip effects on/off, pick a profile, nudge
  brightness, and toggle the OLED without opening the main window.
- As a laptop user, I wake my Mac and the keyboard re-lights correctly instead of
  going dark.

## 6. Functional requirements
- FR-1: Provide an `NSStatusItem` whose menu offers: effects on/off + effect picker,
  profile picker (PRD-06), a brightness control, OLED on/off, "Open Main Window",
  "Settings…", and "Quit".
- FR-2: **Start at login** toggle backed by `SMAppService.mainApp` (register /
  unregister); reflect the true current `.status`, including when changed from
  System Settings.
- FR-3: **Run in background** — with it on, closing the last window does not quit;
  the `LightingEngine` and OLED loop continue. "Quit" from the menu fully terminates.
- FR-4: **Show/Hide Dock icon** toggles activation policy `.regular` ↔ `.accessory`
  live; in `.accessory` the menu bar remains the way back to the window.
- FR-5: On launch and on `didWake`, **re-apply the last active profile**: re-enable
  direct mode (`4B`), resend a full lighting frame, and re-push the OLED image.
- FR-6: Optionally pause rendering on `willSleep` and resume on `didWake` (power
  setting), without losing the active profile selection.
- FR-7: Persist all of the above preferences and the "last active profile" so state
  is restored across relaunch.
- FR-8: Single-instance behaviour — a second launch surfaces the existing instance
  rather than starting a duplicate engine.

## 7. UX / UI design
- **Menu-bar menu:** a status icon (keyboard glyph) → menu with the FR-1 controls;
  brightness as an inline slider (custom-view `NSMenuItem`) or ± items; profiles and
  effects as submenus with a checkmark on the active one.
- **Settings pane** (new "General" tab): Start at login · Run in background (keep
  effects running when window closed) · Show Dock icon · Apply last profile on
  login/wake · Pause effects while display asleep. Each with a one-line explanation.
- **First-run nudge:** on first close, a one-time hint — "Apex Control is still
  running in the menu bar. Use Quit to stop it." — so backgrounding isn't mistaken
  for a crash.
- Error/empty states: if `SMAppService.register()` fails (unsigned / not in
  `/Applications`), show an inline explanation and a link to Login Items settings.

## 8. Technical design
- **ApexKit:** no new commands; expose a small `reapply()` that re-runs the connect
  sequence (enable direct `4B`, push current frame, push OLED) for use on wake/relaunch.
- **App:**
  - A `MenuBarController` owning the `NSStatusItem`/`MenuBarExtra` and building the
    menu from the same view models the main window uses (single source of truth).
  - `LoginItemManager` wrapping `SMAppService` (register/unregister/status).
  - `LifecycleController` (in the `NSApplicationDelegate`) handling activation policy,
    `applicationShouldTerminateAfterLastWindowClosed`, and `NSWorkspace`
    sleep/wake observers; single-instance guard.
  - The existing `@main` app switches its default policy based on the "Show Dock
    icon" setting at startup.
- **Data model:** `AppPrefs { startAtLogin, runInBackground, showDockIcon,
  applyLastProfileOnWake, pauseWhileAsleep, lastActiveProfileID }` persisted
  (UserDefaults / app-support); menu state derived from live view models, not stored.

## 9. Edge cases & risks
- **`SMAppService` prerequisites:** login registration is unreliable for unsigned or
  non-`/Applications` builds; detect and message this rather than silently failing.
  macOS may also surface an approval in System Settings the user must confirm.
- **Dock-less trap:** in `.accessory` there is no Dock icon and no app menu — the
  menu bar must always offer "Open Main Window" and "Quit," or the app becomes
  unreachable.
- **Background power cost:** a 30 fps timer running headless drains battery; the
  "pause while display asleep" option and stopping the engine on `willSleep` mitigate
  this; consider throttling when no window is visible.
- **Wake/relight ordering:** on wake the USB device may re-enumerate slightly after
  the `didWake` fires — retry `reapply()` on reconnect, not just on the notification,
  so the frame lands after the device is ready.
- **Quit vs. close ambiguity:** with "run in background" on, users may not realize
  the app is still resident — the first-run nudge and an explicit menu "Quit" address
  this.
- **Duplicate instances:** login launch + manual launch could start two engines both
  driving the keyboard; enforce single-instance.

## 10. Acceptance criteria
- AC-1: Closing the main window with "run in background" on keeps lighting and OLED
  running; the menu-bar item remains and can reopen the window.
- AC-2: With "Start at login" on, a reboot brings the keyboard up with the last
  profile's lighting/OLED applied and **no window shown**.
- AC-3: Toggling "Show Dock icon" removes/restores the Dock icon live without
  restart, and the app stays reachable via the menu bar in both states.
- AC-4: After system sleep/wake, the keyboard re-lights correctly (direct mode
  re-enabled, frame + OLED resent).
- AC-5: The menu-bar quick controls (effect toggle, profile pick, brightness, OLED
  on/off, quit) all act on the running engine.
- AC-6: `SMAppService` status shown in Settings matches System Settings › Login
  Items, including external changes.

## 11. Effort & milestones
**M.** M1: `NSStatusItem` menu wired to existing view models. M2: background
operation (terminate-after-last-window off) + activation-policy toggle. M3:
`SMAppService` launch-at-login + Settings pane. M4: login/wake re-apply +
sleep/wake observers + reconnect retry. M5: single-instance + first-run nudge +
error states.

## 12. Open questions
- `MenuBarExtra` (SwiftUI, macOS 13+) vs. a hand-built `NSStatusItem` — which gives
  better control over the inline brightness slider and submenus?
- Distribution: to make `SMAppService.mainApp` reliable, do we require the app to be
  in `/Applications`, and how do we guide users who run it from elsewhere?
- Default activation policy on first launch — start `.regular` (discoverable) and let
  users opt into `.accessory`, or ship Dock-less by default like a typical utility?
- Should "run in background" default on or off out of the box (parity with GG vs.
  least-surprise for a new user)?
