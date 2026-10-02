# PRD-13: GameSense / Game Event Integration

- **Priority:** P2
- **Status:** Proposed
- **Depends on:** 08 (lighting engine), 11 (OLED apps)
- **Firmware basis:** host-side only — a GameSense-compatible local HTTP server that
  drives the device through the existing `direct_write` (`40`) lighting path and the
  OLED live/persist writes (`1F 81` / `38 83`), i.e. it consumes PRD-08 and PRD-11
  rather than adding any new wire command.

## 1. Summary
SteelSeries' **GameSense** lets games and community tools push live game state —
health, ammo, killstreaks, low-HP, cooldowns — to the keyboard so lighting and the
OLED react in real time. Today that entire ecosystem is dark for Apex Control users
because it talks only to GG. This PRD reimplements a **byte-compatible local event
server**: we write the well-known `coreProps.json`, accept the documented GameSense
REST endpoints, and map incoming events onto our lighting effects (PRD-08) and OLED
widgets (PRD-11). The result is **drop-in compatibility** — existing GameSense games
and integrations light up Apex Control unmodified, with GG uninstalled.

## 2. Background & GG parity
GG runs a small HTTP server on `127.0.0.1`; games discover its port from a fixed
file, register a game + its events, bind handlers that say "colour the function row
as a health bar" or "print ammo on the screen", then stream event values. Games
and community tools (for example the OmniLED project and GameSense exporters for
CPU/GPU stats) speak this protocol. Without a server, none of that reaches an
Apex Control user — the single most visible piece of "the keyboard does things
while I play" parity. Because the protocol is an open, documented REST contract, we
can serve it ourselves and inherit the whole ecosystem without writing a single
per-game integration.

## 3. Technical basis (grounded)
- **Discovery handshake.** A GameSense client reads the server address from a
  well-known file and POSTs JSON to it. On macOS that file is
  `/Library/Application Support/SteelSeries Engine 3/coreProps.json`, containing
  `{"address": "127.0.0.1:<port>"}` (newer GG also writes `encrypted_address` /
  `ggEncryptedAddress`, but the plain `address` remains the compatible path). We
  bind an HTTP listener on `127.0.0.1:<ephemeral port>` and write that file at
  startup; clients then find us exactly as they find GG.
- **Endpoints** (all `POST`, JSON body, replies `200` + small JSON):
  `/game_metadata` (`{game, game_display_name, developer,
  deinitialize_timer_length_ms}`), `/register_game_event`, `/bind_game_event`
  (`{game, event, handlers:[…]}`), `/game_event` (`{game, event, data:{value,
  frame}}`), `/remove_game`, `/remove_game_event`, `/game_heartbeat`.
- **Handler model → our engine.** A lighting handler names a `device-type`
  (e.g. `rgb-per-key-zones`), a `zone` or `custom-zone-keys` (an array of **HID
  usage codes** — the *same* addressing our `direct_write` uses per PROTOCOL.md),
  a `mode` (`color` / `percent` / `count`), and a colour (static / gradient /
  range). A **screen** handler (`device-type: screened-128x40`) carries text/icon
  lines for a **128×40 1 bpp** display — an exact match for our OLED framebuffer.
  So `percent`-mode colour handlers become a PRD-08 gradient-bar effect and screen
  handlers become a PRD-11 OLED widget; nothing new is needed on the wire.
- **Confidence:** the GameSense HTTP API and its JSON schemas are **publicly
  documented** (SteelSeries `gamesense-sdk`); our device write path (`40`, `1F 81`,
  `38 83`) is **confirmed on hardware**. Unknowns: the full breadth of the handler
  grammar (colour ranges, bitmap/tactile handlers) — we ship a **pragmatic subset**
  first; and whether any client hard-requires the `encrypted_address` fields, which
  the plaintext-only server does not provide (a known limitation, see §4).

## 4. Goals / Non-goals
- **Goals:** a localhost-only GameSense server that writes `coreProps.json`, serves
  the six core endpoints, tracks registered games/events/handlers, and renders
  `percent` / `count` / `color` lighting handlers and screen handlers through our
  existing lighting + OLED engines; per-game bindings viewable and overridable in
  the app; an event log for debugging.
- **Non-goals:** shipping game-specific integrations *ourselves* (we serve the
  protocol; games/community tools provide the content); GameSense audio (Sonar) or
  non-keyboard device types; cloud/account features; the encrypted address form
  that newer GG also publishes (we accept plaintext localhost only).

## 5. User stories
- As a CS2 player, I install nothing extra: the game already speaks GameSense, so
  my health shows as a bar on the F-row and the screen flashes on low HP — through
  Apex Control instead of GG.
- As a user of a community stats exporter, I see CPU/GPU load on the OLED because
  the exporter POSTs to our server exactly as it did to GG's.
- As a tinkerer, I open the event log, watch `/game_event` payloads arrive, and
  confirm a binding is firing.
- As a power user, I override a game's default handler — "map this game's `KILL`
  event to *my* ripple effect instead of the colour it asked for."

## 6. Functional requirements
- FR-1: On enable, bind an HTTP server to `127.0.0.1` on an ephemeral port and
  write `coreProps.json` (address form above) to the documented path; remove/rewrite
  it on disable and on clean shutdown.
- FR-2: Implement `/game_metadata`, `/register_game_event`, `/bind_game_event`,
  `/game_event`, `/remove_game`, `/remove_game_event`, `/game_heartbeat` with the
  documented request/response shapes; unknown endpoints return `404`, malformed
  JSON returns `400`.
- FR-3: Maintain per-game registries (events, bound handlers, last value, heartbeat
  timestamp); expire a game after its `deinitialize_timer_length_ms` (default if
  unspecified) with no heartbeat.
- FR-4: Render lighting handlers — `percent` (value → fraction of a zone lit /
  gradient), `count` (value → N keys lit), `color` (static/range) — onto the zone's
  HID-code keys via the PRD-08 engine, composited over the base effect.
- FR-5: Render screen (`screened-128x40`) handlers as a PRD-11 OLED widget (text
  lines + icons) via the live OLED write.
- FR-6: Provide a per-game override so a user can rebind any event to one of our
  effects/widgets, superseding the game-supplied handler.
- FR-7: Expose an event log (last N requests: game, event, value, matched handler)
  and a running/stopped status with the active port.
- FR-8: Never expose the server beyond loopback; cap request body size; treat all
  event data as untrusted display input (map to effects, never execute).

## 7. UX / UI design
- A new **Game Integration** pane:
  - **Server** header: on/off toggle, status pill (Running · `127.0.0.1:<port>`),
    and a note if GG is detected (see §9).
  - **Games** list: each registered game (display name, developer, last-seen),
    expandable to its events and bound handlers; per-event "Override…" opens a
    picker of our effects/OLED widgets.
  - **Event log**: a live, scrollable, filterable stream for debugging; clearable.
- Empty state: "No games connected yet — start a GameSense-enabled game or tool."
- Error state: port bind failure, or `coreProps.json` path unwritable, shown inline
  with a remediation hint.

## 8. Technical design
- **ApexKit:** no new device commands. Add a thin `LightingHandler` /
  `ScreenHandler` bridge that turns a resolved handler + value into either a
  `direct_write` frame region (list of `hid,R,G,B`) or a 640-byte OLED buffer,
  reusing PRD-08 compositing and PRD-11 rendering.
- **App:** a `GameSenseServer` actor wrapping an embedded HTTP server (e.g.
  `Network.framework` `NWListener` on `127.0.0.1`, or a minimal Swift HTTP lib),
  with a router for the endpoints and an in-memory `GameRegistry`
  (`[gameId: GameState]`). A `CorePropsWriter` writes/removes the discovery file.
  A `GameEventRouter` resolves `game_event` → active handlers → engine calls, with
  a priority so user overrides win over game-supplied handlers.
- **Data model:** `GameState { id, displayName, developer, events:[EventDef],
  bindings:[EventId: [Handler]], lastHeartbeat }`; `Handler` is a decoded subset of
  the GameSense handler JSON (device-type, zone/keys, mode, colour, screen lines);
  user overrides persisted per game id under app support.

## 9. Edge cases & risks
- **GG installed / path ownership:** the discovery file lives in a system dir
  (`/Library/Application Support/…`) that may need admin to *create* the first
  time, and if real GG is present both apps want to own the file/port. Detect a
  running GG (or a pre-existing `coreProps.json`) and refuse to clobber it by
  default, with an explicit "take over" action.
- **The no-network promise.** This is the app's first network listener (loopback
  only). It changes the promise in `docs/PRIVACY.md` and the README, the rule in
  `CONTRIBUTING.md` and the network check in `make check`, so all of them must change
  in the same pull request that adds it.
- **Security:** bind loopback only; never `0.0.0.0`. Enforce a max body size and a
  per-game handler cap; sanitize screen text before rendering. Localhost trust is
  the GameSense model — do not widen it.
- **Compatibility gaps:** clients using handler features we don't yet render should
  degrade gracefully (accept + log, don't `500`). A client that requires the
  encrypted address fields will not work with the plaintext-only server; that is a
  known limitation, not something this PRD sets out to fix.
- **Lifecycle:** stale games left registered after a crash → heartbeat expiry cleans
  them; server must release the file/port on quit (ties to PRD-15 background mode).
- **Contention with base lighting:** GameSense effects composite *over* the user's
  base effect; define clear precedence so a health bar doesn't fight a wave.

## 10. Acceptance criteria
- AC-1: With GG uninstalled, a real GameSense-enabled game (or the SDK's sample
  client) registers, binds, and streams events that visibly drive our lighting and
  OLED.
- AC-2: `coreProps.json` is written on enable with a reachable `127.0.0.1:<port>`
  and removed on disable/quit.
- AC-3: A `percent` colour handler lights the correct fraction of its zone's HID
  keys as the value changes; a `screened-128x40` handler renders on the OLED.
- AC-4: The server binds loopback only (a non-local connection is refused) and
  rejects oversized/malformed bodies without crashing.
- AC-5: A user override redirects a game's event to a chosen effect/widget and
  persists across restarts.

## 11. Effort & milestones
**L.** M1: HTTP server + `coreProps.json` + endpoint stubs that accept and log.
M2: registry + `percent`/`color` lighting handlers on the F-row (prove with the SDK
sample). M3: screen handlers → OLED. M4: Game Integration pane + event log +
per-game overrides. M5: compatibility pass against 2–3 real games, GG-coexistence
handling.

## 12. Open questions
- Do any target clients hard-require `encrypted_address` / `ggEncryptedAddress`, or
  is plain `address` sufficient in practice? (If one does, it is unsupported.)
- First-run creation of the system `SteelSeries Engine 3` directory — prompt for
  admin once, or fall back to a user-writable location some clients also check?
- How much of the handler grammar (colour ranges, bitmap/tactile, multi-zone) is
  worth supporting in v1 vs. accept-and-ignore?
- Precedence rules when a GameSense effect and a user base effect target the same
  keys — overlay, replace, or blend?
