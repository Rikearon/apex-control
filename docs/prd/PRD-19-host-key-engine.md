# PRD-19: Host Key Engine (tap-hold, chords, one-shot modifiers)

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** — (complements PRD-01; shares the Bindings UI and per-app detection from PRD-07)
- **Firmware basis:** **host-side only** — `CGEvent.tapCreate` with
  `options: .defaultTap` (Accessibility permission), which can *replace or
  suppress* events rather than only observe them.

## 1. Summary
PRD-01 writes bindings into the keyboard, which is the right default: they work
with no software, on any computer. But the firmware's mapping block is a pure
1:1 substitution — one key, one action, no timing, no state. Everything people
actually want from a modern keymap (Caps as Esc-on-tap/Ctrl-on-hold, home-row
modifiers, chords, one-shot modifiers, a leader key) needs a *timing state
machine* that no firmware command can express. This PRD adds a host-side key
engine that layers those behaviours on top of the firmware bindings, with a
clear, visible boundary between "lives in the keyboard" and "needs the app".

## 2. Background & GG parity
As far as we know, GG maps one key to one action and has no timing-based
behaviours, so this goes beyond parity. The comparison class here is
Karabiner-Elements, QMK/ZMK, and Hyperkey, which is where users actually go for
this. Karabiner-Elements and Hyperkey work at the level of the whole Mac; QMK and
ZMK are keyboard firmware, and this keyboard runs the vendor's. An engine scoped
to this keyboard, and aware of which keys are analog, is what Apex Control can
add. Doing nothing means the project is a configurator for a keyboard whose
owners will still install a second remapping tool — and the two will fight over
the same keys.

## 3. Technical basis (grounded)
- **Event tap with modification** (confidence: documented Apple API, and the
  project already runs a *listen-only* tap in `KeyMonitor`). `CGEvent.tapCreate`
  with `place: .headInsertEventTap`, `options: .defaultTap` returns an
  `Unmanaged<CGEvent>?`; returning `nil` swallows the event, and returning a
  different event substitutes it. Requires **Accessibility**, not Input
  Monitoring.
- **Source attribution** (confidence: documented, needs care). A tap sees events
  from all keyboards. `CGEvent`'s `kCGEventSourceUnixProcessID` does not identify
  the *device*; the practical filter is
  `event.getIntegerValueField(.eventSourceUserData)` for our own synthetic events
  plus an `IOHIDManager` listener on the keyboard's own input interfaces to
  correlate. Scoping to our device is **needs-RE at the CGEvent layer** — the
  fallback is to apply the engine to all keyboards and say so.
- **Tap timeout** (confidence: documented, load-bearing). If the callback is slow
  the system disables the tap with `kCGEventTapDisabledByTimeout`; the engine
  must re-enable on that event and must never block on I/O inside the callback.
- **Synthetic events**: `CGEvent(keyboardEventSource:virtualKey:keyDown:)` posted
  to `.cghidEventTap`, tagged via `setIntegerValueField(.eventSourceUserData:)`
  so the tap ignores its own output and cannot loop.
- **Ordering vs. firmware**: the keyboard rewrites the usage *before* macOS sees
  it, so the tap observes the post-remap key. The UI must present the engine as
  operating on the firmware's output, or rules will look mysteriously wrong.

## 4. Goals / Non-goals
- **Goals:** tap-vs-hold per key; home-row modifiers with a typing-aware
  guard; one-shot ("sticky") modifiers; chords (two or more keys pressed
  together → one action); a leader key with a short sequence table; per-app
  enable/disable; a live rule tester; a hard kill-switch.
- **Non-goals:** replacing Karabiner for other keyboards; mouse gestures;
  text expansion (that is PRD-04's macro territory); anything that needs a
  kernel driver; remapping the Fn layer (firmware already owns that, PRD-02).

## 5. User stories
- As a developer, Caps Lock sends Escape when tapped and Control when held.
- As a touch typist, my home row doubles as modifiers, without firing modifiers
  mid-word when I type fast.
- As someone with RSI, I tap Shift once and it applies to the next key only.
- As a designer, pressing J+K together opens my screenshot tool.
- As a power user, I press my leader key then `g s` and git status runs.
- As a gamer, the whole engine turns itself off while my game is focused.

## 6. Functional requirements
- FR-1: A rule set is an ordered list; the first matching rule wins, and the UI
  shows the match order.
- FR-2: **Tap-hold** per key with configurable hold threshold (default 180 ms),
  tap action and hold action, plus "hold wins if another key is pressed first".
- FR-3: **Home-row mods** as a preset over FR-2, with a *streak guard*: if the
  previous keystroke was within N ms (default 120 ms), resolve as tap. This is
  the single setting that makes or breaks the feature.
- FR-4: **One-shot modifiers**: applies to exactly the next non-modifier key,
  with a timeout (default 2 s) and a double-tap-to-lock option.
- FR-5: **Chords**: 2–4 keys within a window (default 50 ms) → one action;
  chords must not fire when the keys are typed in sequence.
- FR-6: **Leader key**: one trigger key then a sequence of up to 3 keys, matched
  against a user table, with an on-screen HUD showing available continuations.
- FR-7: Actions reuse PRD-01's vocabulary (key + modifiers, consumer, launch
  app, insert text, run shortcut) so one editor covers both tiers.
- FR-8: **Per-app scoping** — each rule set is global or restricted to a bundle
  ID list, reusing PRD-07's foreground detection.
- FR-9: **Kill switch** — a global hotkey and a menu-bar item that disable the
  engine instantly; the engine is also disabled automatically if the tap is
  torn down or Accessibility is revoked.
- FR-10: Latency budget: median added latency **< 2 ms** for pass-through keys;
  no allocation or lock contention in the tap callback.
- FR-11: A rule that would swallow every key (e.g. a chord on all four home
  keys with no output) is rejected at edit time.

## 7. UX / UI design
- A new **Key Engine** pane, deliberately placed *below* Key Bindings in the
  sidebar with a one-line explainer: "Bindings live in the keyboard. Rules here
  need Apex Control running."
- Rule list on the left, rule editor on the right: trigger (key / chord /
  leader), behaviour (tap-hold / one-shot / immediate), actions, timing sliders,
  app scope.
- A **Test strip**: a focused field that shows, live, what the engine decided
  for the last few keystrokes (matched rule, tap vs hold, elapsed ms). This is
  the difference between a feature people can tune and one they abandon.
- **Empty state:** three starter presets — "Caps → Esc/Ctrl", "Home-row mods",
  "Leader key" — each installable in one click.
- **Error states:** Accessibility not granted → an inline explainer and a button
  to open the settings pane; tap disabled by timeout → a banner naming the rule
  that overran.

## 8. Technical design
- **ApexKit:** none. This is host-only and must not leak into the device layer.
- **App:**
  - `KeyEngine` — owns the tap on a dedicated thread, runs a pure
    `RuleMachine` (input: key event + timestamp; output: pass / swallow /
    substitute / emit sequence). The machine is a value type so it is unit
    testable without a tap.
  - `KeyEngineRule`, `Trigger`, `Behaviour`, `EngineAction` — `Codable`, stored
    in the profile (PRD-06) so rules travel with a setup.
  - `SyntheticEmitter` — posts events with our marker in `eventSourceUserData`.
  - Reuse `KeyMonitor`'s keycode↔HID table; promote it out of the reactive
    lighting file into a shared `MacKeycodes` type.
- **Data model:** `KeyEngineConfig { enabled: Bool, rules: [KeyEngineRule] }`
  added to `SoftwareProfile` as an optional field (forward-compatible per
  PRD-06 FR-1).

## 9. Edge cases & risks
- **Swallowing the escape hatch.** A bad rule can make the keyboard unusable
  *while the app runs*. The kill switch must be a plain global hotkey registered
  outside the engine, and quitting the app must always restore normal typing.
- **Tap disabled by timeout** silently stops all rules; must be detected and
  surfaced, not just re-enabled quietly.
- **Fighting Karabiner** — if Karabiner is installed, both taps see the same
  events and rules can double-apply. Detect its presence and warn.
- **Secure input** (password fields, some terminals) blocks taps entirely; the
  engine goes inert and the UI must explain rather than look broken.
- **Key repeat**: a held key that is part of a tap-hold rule must not emit
  repeats of the tap action.
- **Modifier leakage**: if the app dies mid-hold, a synthetic modifier-down can
  be left stuck. Emit a modifier-release sweep on teardown and on tap re-enable.
- **Accessibility revocation** at runtime is silent; poll `AXIsProcessTrusted`.

## 10. Acceptance criteria
- AC-1: Caps tapped types Escape; Caps held with `a` types Ctrl+A; verified in a
  text editor.
- AC-2: Typing "asdf jkl;" at 90+ WPM with home-row mods enabled produces exactly
  that text and no stray modifiers.
- AC-3: A chord on J+K fires once, and typing "jk" quickly in prose does not.
- AC-4: The kill switch restores plain typing within one keystroke, and quitting
  the app does the same.
- AC-5: Measured median added latency under 2 ms over 10 000 events.
- AC-6: Revoking Accessibility mid-session disables the engine and shows the
  explainer instead of silently dropping keys.

## 11. Effort & milestones
**L.** M1: modifying tap + pass-through with a latency harness. M2:
`RuleMachine` with tap-hold and one-shot + unit tests. M3: home-row preset and
the streak guard. M4: chords and leader. M5: per-app scoping, kill switch, test
strip, presets.

## 12. Open questions
- Can a `CGEvent` be attributed to a specific USB device well enough to scope the
  engine to this keyboard, or must we own all keyboards and say so?
- Does the firmware's own remap arrive early enough that a rule keyed on the
  *original* keycap (rather than the remapped usage) is even expressible?
- Should rules live in the profile (travel with a setup) or in app preferences
  (stable across profile switches)? Probably profile, but per-app scoping muddies
  it.
- Is there an acceptable interaction with Secure Input, or do we simply document
  it as a dead zone?
