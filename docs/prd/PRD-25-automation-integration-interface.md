# PRD-25: Automation & Integration Interface

- **Priority:** P1
- **Status:** Proposed
- **Depends on:** PRD-06 (profiles are the main thing to automate); complements PRD-13 (GameSense is a *different*, game-facing protocol)
- **Firmware basis:** **host-side only.**

## 1. Summary
Right now the only ways to drive Apex Control are its window and `apexctl`, and
the CLI cannot talk to the running app — it opens its own connection to the
keyboard. This PRD gives the app a proper automation surface: Shortcuts actions,
AppleScript, a URL scheme, and a local IPC socket that lets `apexctl` and any
other program on the machine ask the *running* app to switch a profile, set a
colour, flash an alert, or draw on the OLED.

## 2. Background & GG parity
GG's automation is GameSense, which is aimed at *games* publishing events, plus
per-application profile switching (PRD-07). As far as we know it has no interface
for other programs or scripts to drive the keyboard. Meanwhile macOS users automate
everything with Shortcuts, Keyboard Maestro, Hammerspoon, Stream Deck, and shell
scripts, and a peripheral app that cannot be scripted ends up outside all of it.
There is also a concrete architectural problem to fix: two processes (app + CLI)
both opening the device and both streaming frames is a race we currently tolerate
only because the CLI is short-lived.

## 3. Technical basis (grounded)
- **Shortcuts / App Intents** (confidence: documented, macOS 13+). `AppIntent`
  conformances are discovered automatically from the app bundle; each becomes a
  Shortcuts action and a Spotlight/Siri target. No entitlement needed.
- **AppleScript** (confidence: documented, long-standing). An `.sdef` in the
  bundle plus `NSApplication` scripting support; verbose to build but it is what
  Keyboard Maestro and older automation tools speak.
- **URL scheme** (confidence: documented). `CFBundleURLTypes` +
  `application(_:open:)`; `apexcontrol://profile/Work` is the cheapest possible
  integration point and works from anything that can open a URL.
- **Local IPC** (confidence: standard, choice open). A Unix domain socket under
  the app's Application Support directory, line-delimited JSON, permissions
  0600. Simpler and more portable than a Mach service, and trivially reachable
  from shell, Python, Node, Hammerspoon. **Not** a TCP port — a listening TCP
  socket on a desktop app is an unnecessary attack surface.
- **CLI convergence**: `apexctl` should prefer the socket when the app is
  running and fall back to direct HID when it is not. This removes the
  two-writers problem and makes the CLI able to affect what you see.
- **Third-party output**: the same socket lets other apps push a lighting layer
  (PRD-23) or an OLED frame (PRD-11) without implementing GameSense.

## 4. Goals / Non-goals
- **Goals:** a documented, versioned local API covering profiles, effects,
  brightness, OLED, indicators/alerts, and device info; Shortcuts actions for the
  common verbs; a URL scheme; AppleScript for the same verbs; `apexctl` routed
  through the app when it is running; a published schema so integrations can be
  written without reading our source.
- **Non-goals:** a network-reachable API; remote control from another machine;
  the GameSense HTTP protocol (PRD-13 owns that); a plugin runtime (PRD-24);
  exposing raw HID writes over IPC (that is a foot-gun with no legitimate caller).

## 5. User stories
- As a Shortcuts user, "When I start Focus > Work, set the Work profile."
- As a Stream Deck owner, a button switches my keyboard to my game profile.
- As a developer, my build script flashes the keyboard red when tests fail.
- As a Hammerspoon user, I bind a hotkey to cycle profiles.
- As a CLI user, `apexctl profile Work` changes what the running app is showing
  instead of fighting it.
- As an integrator, I read one schema document and write my integration without
  reverse engineering anything.

## 6. Functional requirements
- FR-1: **Socket** at `~/Library/Application Support/ApexControl/control.sock`,
  mode 0600, created on launch, removed on quit; stale sockets are reclaimed.
- FR-2: **Protocol**: newline-delimited JSON request/response, each request
  `{"v":1,"op":"…","args":{…},"id":"…"}`, each response
  `{"id":"…","ok":true,"result":{…}}` or `{"id":"…","ok":false,"error":{"code":…,"message":"…"}}`.
- FR-3: **Operations (v1)**: `status`, `listProfiles`, `applyProfile`,
  `saveProfile`, `setEffect`, `setBrightness`, `setColor` (all or per key),
  `oled.text`, `oled.image`, `oled.clear`, `alert`, `setActuation`,
  `setRapidTrigger`, `resetBindings`, `deviceInfo`.
- FR-4: Every mutating op is **idempotent** and returns the resulting state, so
  callers can converge without polling.
- FR-5: **Events**: an optional `subscribe` op streams device connect/disconnect,
  profile change, and hardware-originated changes (PRD-14) as JSON lines.
- FR-6: **Shortcuts actions** for: Apply Profile, Set Effect, Set Brightness,
  Show OLED Text, Flash Alert, Get Device Info — with parameter summaries and
  `ProfileEntity` so the profile list is a picker, not a free-text field.
- FR-7: **URL scheme** `apexcontrol://` covering `profile/<name>`,
  `effect/<name>`, `brightness/<0-100>`, `alert?color=…&flash=…`.
- FR-8: **AppleScript** verbs mirroring FR-6 with a shipped `.sdef`.
- FR-9: `apexctl` detects the socket and routes through it; `--direct` forces
  the current behaviour; the CLI prints which path it used.
- FR-10: The API is **versioned**; unknown ops return a structured error naming
  the supported version, and v1 does not break.
- FR-11: A settings toggle disables the socket entirely for users who want no
  local API at all.

## 7. UX / UI design
- Mostly invisible by design. A small **Automation** card in Settings: socket
  path (with copy button), on/off, a link to the schema doc, and a live counter
  of connected clients.
- Shortcuts actions appear in the Shortcuts app with clear names and a
  keyboard-glyph icon.
- **Error surface:** a failed automation call should not raise UI; it returns an
  error to the caller and is visible in the diagnostics log (PRD-35).
- **Discovery:** the Settings card links to `docs/AUTOMATION.md`, which is the
  contract, with copy-pasteable `curl`-style examples using `nc`/`socat`.

## 8. Technical design
- **ApexKit:** none. The API is an app-level surface over `DeviceController`.
- **App:**
  - `ControlServer` — accepts connections on the Unix socket, decodes requests,
    dispatches to a `ControlAPI` façade on the main actor, encodes responses.
    Backpressure-aware; one slow client cannot stall the app.
  - `ControlAPI` — the single place every automation surface funnels through, so
    Shortcuts, AppleScript, URL, and socket cannot drift apart.
  - `AppIntent` types, an `.sdef`, and a URL handler, all thin wrappers over
    `ControlAPI`.
- **apexctl:** a `ControlClient` that tries the socket first; on failure it uses
  the existing direct HID path.
- **Data model:** requests/responses are `Codable` types in a shared module so
  the CLI and app cannot disagree about the schema.

## 9. Edge cases & risks
- **Any local process can drive your keyboard.** That is the point, and it is
  also the risk: a hostile local program could set every key black or spam the
  OLED. It cannot read anything sensitive, cannot write bindings without the
  same access, and cannot reach the device more directly than it already could
  by opening the HID interface itself — but the settings toggle and the
  documented threat model (PRD-34) are required.
- **Socket permissions and location** — 0600 in the user's own container; never
  in `/tmp`, where another user could pre-create it.
- **Two writers**: even with the socket, someone can still run `apexctl --direct`
  while the app runs. The CLI should warn.
- **Blocking the main actor** — `ControlAPI` runs on the main actor while device
  I/O is off-main; long ops must return immediately and report completion via
  the event stream rather than holding the connection.
- **Shortcuts sandbox**: App Intents run in the app's process, but Shortcuts may
  launch the app to run one; launching must not steal focus.
- **Version drift** between a shipped integration and a newer app is the normal
  case, not the exception; hence FR-10.

## 10. Acceptance criteria
- AC-1: `echo '{"v":1,"op":"applyProfile","args":{"name":"Work"},"id":"1"}' | nc -U <sock>`
  switches the running app's profile and returns `ok:true`.
- AC-2: A Shortcuts action switching profiles works from the Shortcuts app and
  from a Focus automation.
- AC-3: `open 'apexcontrol://effect/Breathe'` changes the effect.
- AC-4: With the app running, `apexctl profile Work` routes through the socket
  (stated in its output) and the app's UI updates.
- AC-5: With the app not running, the same command still works via direct HID.
- AC-6: Disabling the API in Settings removes the socket file and rejects new
  connections.

## 11. Effort & milestones
**M.** M1: `ControlAPI` façade + socket server + schema doc. M2: `apexctl`
routing and `--direct`. M3: App Intents. M4: URL scheme + AppleScript.
M5: event subscription.

## 12. Open questions
- Unix socket vs. XPC Mach service: XPC is more "Mac-native" and gets peer
  auditing for free, but is far harder to call from a shell script. Is
  scriptability worth losing peer identification?
- Should the API expose *bindings* editing, or is that dangerous enough (a script
  can disable your keyboard) to require the GUI?
- Do we authenticate clients at all — e.g. a token in the app's container that
  callers must read — or is filesystem permission the whole model?
- Should `apexctl` become a thin client permanently, dropping direct HID except
  under `--direct`, so there is exactly one writer by default?
