# PRD-24: Effect Scripting & Plugin API

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** PRD-08 (effect pipeline); **PRD-34** (security model) is a hard prerequisite, not a nicety
- **Firmware basis:** **host-side only.**

## 1. Summary
Our effects are compiled into the app, so every new one needs a release. This PRD
opens the renderer: a small, sandboxed scripting surface where an effect is a
function from `(time, key positions, inputs) → colours`, plus a way to share
those scripts. It is how the effect library grows without the maintainer being a
bottleneck — and it is the single most dangerous feature in the backlog, because
"import this profile" becomes "run this code".

## 2. Background & GG parity
As far as we know, GG does not expose scripting: its effects come from a fixed set
and its PrismSync editor. The comparison class is OpenRGB's effect plugins,
SignalRGB's JavaScript effects, and Hammerspoon scripts. For an open-source project
this matters more than for a vendor: contributors who would never send a Swift PR
will happily write a 20-line effect. Without it, the project's effect library is
limited to whatever the maintainers find time to build.

## 3. Technical basis (grounded)
- **Runtime** (confidence: documented system framework). `JavaScriptCore` ships
  with macOS; a `JSContext` with **no** host objects injected is a genuine
  sandbox for pure computation — no file, network, or process access exists
  unless we add it. We add nothing.
- **Determinism and safety**: `JSContext` has no built-in execution timeout, so
  runaway scripts must be bounded by running them on a dedicated thread with a
  watchdog that invalidates the context. This is the load-bearing detail; without
  it one bad script freezes the lighting engine.
- **Performance budget**: 30 fps × 86 keys. A JS call per frame returning an
  array of 86 RGB triples is well within budget; a JS call *per key per frame*
  (2 580/s) is not the design — the contract is one call per frame.
- **Alternative considered**: a declarative, non-Turing-complete DSL (gradient +
  waveform + mask). Safer, far less expressive, and cannot express the effects
  people actually want. The right answer is probably **both**: the DSL as the
  default authoring surface, scripting as the escape hatch.
- **Distribution risk** (confidence: certain): a `SoftwareProfile` is already
  importable JSON (PRD-06 FR-9). If a script can ride inside one, importing a
  teammate's profile becomes arbitrary code execution. That is unacceptable
  without the mitigations in §9.

## 4. Goals / Non-goals
- **Goals:** a documented effect contract; a built-in editor with live preview on
  the on-screen keyboard; a watchdog that kills runaway scripts; parameters that
  a script declares and the UI renders as controls; import/export of single
  effects as files, separate from profiles; a small bundled library of example
  effects.
- **Non-goals:** giving scripts any I/O of any kind; a plugin marketplace or
  auto-update of community scripts; native (dylib) plugins — ever; scripts that
  can change device settings (actuation, bindings) rather than colours.

## 5. User stories
- As a tinkerer, I write a 20-line effect and see it on my keyboard as I type it.
- As a contributor, I share an effect as a small file that someone else can drop
  in.
- As a user, a broken effect from the internet cannot read my files or reach the
  network.
- As a user, an effect that hangs does not freeze my keyboard or my app.
- As an author, my effect exposes a speed and a colour, and the app draws the
  controls for them.

## 6. Functional requirements
- FR-1: The effect contract is a single function
  `render(t, keys, params, inputs) -> [[r,g,b], …]` returning one entry per key
  in the supplied order; anything else is a load error with a line number.
- FR-2: `keys` provides `{hid, x, y, w, h, analog}` — the same layout the native
  renderer uses — so scripts are position-aware.
- FR-3: `inputs` provides only what the user has already enabled: recent key
  presses (as PRD-08's reactive feed does), and, if enabled, the audio spectrum
  (PRD-22) and ambient grid (PRD-21). Nothing else crosses the boundary.
- FR-4: A script declares `params` (name, type, range, default); the app renders
  sliders, colour wells, and toggles from that declaration.
- FR-5: **Watchdog**: a frame that exceeds 12 ms is abandoned; three consecutive
  overruns disable the effect and surface a clear error naming the script.
- FR-6: Scripts have **no** access to file, network, process, timers, or the
  device; the context is created with no injected host objects, and a test
  asserts that `require`, `fetch`, and friends are undefined.
- FR-7: Effects are stored as individual files under Application Support with a
  `.apexfx` extension; import is an explicit file action.
- FR-8: **A profile may reference an effect by id but may never carry its
  source.** Importing a profile that references a missing effect prompts the user
  and falls back to a built-in effect.
- FR-9: Importing an effect file shows the source and requires an explicit
  confirmation before the first run.
- FR-10: A "Reset to built-in effects" action that removes all user scripts.

## 7. UX / UI design
- An **Effects** section in the Lighting pane listing built-in and user effects,
  with a "New effect…" action.
- The editor is a sheet: source on the left, live keyboard preview on the right,
  parameter controls beneath the preview, and an error line under the editor.
- Errors are inline and non-modal; a script that fails keeps the previous frame
  rather than going black.
- **Import flow:** file picker → a review sheet showing the full source and a
  plain warning ("This is a program. It will run on your Mac.") → Run.
- **Empty state:** three example effects (plasma, ripple, per-key gradient) that
  are readable and worth copying.

## 8. Technical design
- **ApexKit:** none — scripting stays in the app, above the device layer.
- **App:**
  - `ScriptedEffect` — owns a `JSContext` on a dedicated thread, exposes
    `render(at:) -> [UInt8: LEDColor]`, enforces the watchdog, and is disposable.
  - `EffectManifest` — parsed from a header comment or an exported `params`
    object; drives the generated controls.
  - `EffectLibrary` — enumerates built-in and user effects, handles import with
    the confirmation flow.
  - `LightingRender` gains a case that delegates to a `ScriptedEffect`; the pure
    native path stays untouched so a script failure can always fall back.
- **Data model:** effect files are self-contained text; `LightingConfig` gains
  `scriptedEffectID: String?` and `scriptParams: [String: Double/Color]`.

## 9. Edge cases & risks
- **This feature's risk is the feature.** Concretely: (a) scripts never ride
  inside profiles; (b) import always shows the source and requires consent;
  (c) the context gets no host objects; (d) a watchdog bounds execution;
  (e) the security review in PRD-34 gates the release.
- **A sandbox that leaks later**: any future "let scripts read the clock/config"
  request must be treated as a security change, not a convenience.
- **Watchdog on the wrong thread**: `JSContext` is not thread safe; the watchdog
  must invalidate via `JSContextGroupSetExecutionTimeLimit`-style bounding or by
  tearing down the whole context, not by touching it concurrently.
- **User confusion between "effect" and "profile"** — two shareable artefacts
  with different trust levels. Naming and iconography must keep them apart.
- **Energy**: a naive script running at 30 fps can cost more than the entire
  native engine; the editor should show a per-frame cost readout.
- **Determinism**: scripts using `Math.random()` will strobe unpredictably;
  document a seeded RNG in the contract.

## 10. Acceptance criteria
- AC-1: An example effect renders on hardware and matches the on-screen preview.
- AC-2: `fetch`, `XMLHttpRequest`, `require`, and file APIs are all `undefined`
  inside the context (asserted by test).
- AC-3: A script with `while(true){}` disables itself within ~40 ms and shows an
  error; the app and the lighting engine stay responsive.
- AC-4: A profile file cannot carry script source; a crafted one is rejected.
- AC-5: Importing an effect shows the full source and does not execute before
  confirmation.
- AC-6: A script that throws leaves the previous frame on the keyboard.

## 11. Effort & milestones
**L.** M1: `ScriptedEffect` with the contract, the empty context, and the
watchdog. M2: editor with live preview and errors. M3: parameter manifests and
generated controls. M4: import/export flow, review sheet, example library.
M5: security review with PRD-34 before any release.

## 12. Open questions
- Ship the declarative DSL first and scripting later? The DSL covers most
  requests with none of the risk, and would change this PRD's priority.
- Is `JSContextGroupSetExecutionTimeLimit` (SPI-adjacent) usable, or must the
  watchdog be "tear down the context from another thread"?
- Should scripted effects be allowed to drive the **OLED** as well, or does that
  double the attack surface for marginal gain?
- How do we handle an effect that is excellent but slow — a "render at 10 fps"
  declaration, or just let the watchdog police it?
