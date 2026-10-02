# Apex Pro TKL Gen 3 — HID Protocol Reference

The command reference that the code in `Sources/ApexKit/Protocol/` is written
against, for the **SteelSeries Apex Pro TKL Gen 3, wired, `USB 1038:1642`**.
Anything marked as verified was checked on one keyboard, running firmware 1.19.7
([COMPATIBILITY](COMPATIBILITY.md) has the details).

> The full-size Apex Pro Gen 3 (`0x1640`) and the wireless variants
> (`0x1644` / `0x1646`) are believed to use **different** command sets despite the
> shared “Gen 3” name (from the vendor's description of the devices; none of them has
> been tested). This document is only for the wired TKL, `0x1642`.

> **Licence.** Unlike most of the repository (MIT), this document is licensed
> under [Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/)
> (CC BY 4.0; the [licence text](../LICENSES/CC-BY-4.0.txt) is in the repository), so
> that the knowledge in it can be reused. You may copy, adapt and redistribute it,
> including commercially, provided you credit "Apex Control
> (github.com/Rikearon/apex-control)", link to the licence and say if you changed it.
> The licence covers this file only, and only what its authors own: it grants no
> rights in anything that belongs to SteelSeries or to other projects.
> Copyright (c) 2026 Henrique Aron.
>
> **Provenance.** The command set was worked out from the vendor's device description
> files as installed on the author's own computer and from USB captures of the author's
> own keyboard, was cross-checked against public community projects, and was then
> checked against the keyboard itself. This repository contains no vendor files and no
> vendor code. Where
> a claim has been checked on hardware the text says so; where it rests on less, the
> text says that instead.
>
> **How sure.** *Confirmed on hardware* means checked on the author's keyboard.
> *From descriptor* means taken from the vendor's description of the device, which is
> not part of this repository, and not (yet) checked on hardware. Not every statement
> carries a tag: treat one that matters to you, and that is not marked *confirmed on
> hardware*, as unconfirmed. *Community* means
> reported by another project's documentation or code. *Needs RE* means unknown or
> only guessed. `apexctl raw` sends exactly the bytes you give it, so you can try a
> claim on your own keyboard, at your own risk (see [Raw access](USING-THE-CLI.md#raw-access)).

## Transport

| Property | Value |
|---|---|
| Vendor / Product | `0x1038` / `0x1642` |
| Control interface | HID usage page `0xFFC0`, usage `0x0001` |
| (Notification interface) | usage page `0xFFC1`, usage `0x0001`, input-only |
| Report ID | `0` |
| Feature report | 644 payload bytes (macOS excludes the report-ID byte) |
| Output / Input report | 64 payload bytes |

- **Feature reports** (`IOHIDDeviceSetReport`, `kIOHIDReportTypeFeature`) carry
  bulk payloads: per-key color, actuation tables, OLED frames.
- **Output reports** (`kIOHIDReportTypeOutput`) carry short commands.
- **Queries** write an Output report, then the keyboard answers with an **Input
  report** (delivered to the input-report callback).
- All payloads below are the bytes **after** the report-ID byte; report ID `0` is
  passed as the separate `reportID` parameter. Buffers are zero-padded to the
  report size.

Because `0xFFC0` is a *vendor* usage (not keyboard/mouse), macOS does not open it
exclusively — a user-space app can read and write it with no kext, entitlement,
or root, and it coexists with other clients.

### The device's full USB/HID interface map

Enumerated from `IOHIDDevice` and its report descriptors on a real unit:

| Interface | Top-level collections | In | Out | Feature | Purpose |
|---|---|---|---|---|---|
| 1 | `01/06` keyboard | 8 | 1 | — | boot keyboard |
| 2 | `01/06` keyboard | 32 | 1 | — | NKRO keyboard |
| 3 | `FFC0/01` vendor | 64 | 64 | **644** | configuration — everything in this document |
| 4 | `0C/01` consumer **+ `01/02` mouse** | 6 | 1 | 1 | media keys **and mouse events** |
| 5 | `FFC1/01` vendor | 64 | — | — | notification / sync, input-only |

Two consequences worth stating, because both are easy to get wrong:

- **Mouse bindings should work.** Interface 4's *primary* usage is Consumer, so a
  naïve enumeration shows no mouse and suggests `function 0x01–0x08` is inert.
  Its report descriptor carries a second top-level Generic Desktop/Mouse
  collection, which is the transport those bindings would use. (No click from a
  mouse binding has been recorded on hardware.)
- **No analog / gamepad collection is declared anywhere.** No report descriptor
  declares an axis for key *travel*, so we know of no way to read a key as a joystick
  through a documented interface. The `0xFFC1` input stream has not been examined
  beyond the five known config-change events, whose payloads the descriptor does not
  describe.

## Lighting (per-key RGB)

Direct lighting puts the keyboard in a host-controlled mode; it overrides the
onboard profile until cleared. LEDs are addressed by **USB HID usage code**.

| Command | Type | Bytes |
|---|---|---|
| Direct write | Feature | `40 <count> [hid,R,G,B]×count` (pad to 644) |
| Clear (restore onboard) | Output | `41` |
| Enable direct/driver mode | Output | `4B` (community-derived; harmless to repeat) |

`count` ≤ 91. Missing keys keep their previous color, so send a full frame when
you want a clean result.

`4B` is an init that other RGB tools are reported to send before they drive the
LEDs. Whether this keyboard strictly needs it is not established here. The app
sends it on connect, on wake, when it applies a profile and when it takes lighting
back from the keyboard; `apexctl` sends it before its lighting commands.

## Actuation & rapid trigger

All per-key actuation commands share the `0x38` device-command namespace and
address **68 analog keys**. Each key block is
`hid, h, l` where `h`/`l` are raw Hall-sensor thresholds (`l` ≤ `h`, giving
hysteresis).

| Command | Type | Bytes |
|---|---|---|
| Primary actuation | Feature | `38 61 44 00 [hid,h,l]×68` |
| Second actuation (dual bind) | Feature | `38 61 44 02 [hid,h,l]×68` |
| Rapid-trigger release mode | Feature | `38 62 44 [hid,mode]×68` — mode `0`=off, `2`=on (both confirmed on hardware); `3`/`4` are declared by the firmware but what they do is unknown |
| Rapid-trigger sensitivity | Feature | `38 65 44 [hid,sens]×68` — `sens` in 0.1 mm units (default 2) |

`44` = `0x44` = 68 (the analog-key count).

### Actuation level ↔ raw threshold

Actuation is exposed as a **level 1…40** = **0.1 … 4.0 mm** of travel. Each level
maps to a raw `(l, h)` pair (the curve is non-linear — a real Hall response).
Table for `0x1642` (*from descriptor*: the app sends these pairs to the author's
keyboard, which accepts and stores them; the physical travel at each level has not
been measured):

| lvl | mm | l | h | | lvl | mm | l | h | | lvl | mm | l | h | | lvl | mm | l | h |
|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|--|
|1|0.1|4|4||11|1.1|17|19||21|2.1|49|54||31|3.1|124|136|
|2|0.2|3|4||12|1.2|19|22||22|2.2|54|59||32|3.2|136|148|
|3|0.3|4|5||13|1.3|22|24||23|2.3|59|65||33|3.3|148|164|
|4|0.4|5|7||14|1.4|24|27||24|2.4|65|72||34|3.4|164|180|
|5|0.5|7|8||15|1.5|27|30||25|2.5|72|79||35|3.5|180|189|
|6|0.6|8|10||16|1.6|30|34||26|2.6|79|86||36|3.6|189|199|
|7|0.7|10|11||17|1.7|34|37||27|2.7|86|94||37|3.7|199|209|
|8|0.8|11|13||18|1.8|37|40||28|2.8|94|103||38|3.8|209|219|
|9|0.9|13|15||19|1.9|40|44||29|2.9|103|113||39|3.9|211|219|
|10|1.0|15|17||20|2.0|44|49||30|3.0|113|124||40|4.0|213|219|

In the packet, each block is `hid, h, l` — **`h` first**.

### 68 analog HID codes

`4–40, 42–57, 100, 135–139, 224–231, 240` (i.e. most alphanumerics, punctuation,
space, modifiers, and the SteelSeries key). Non-analog keys (function row, nav
cluster, arrows, media) have fixed mechanical-style switches and are not in the
actuation set.

## Rapid tap / SOCD

| Command | Type | Bytes |
|---|---|---|
| Enable | Output | `38 66 <enabled>` |
| Pairs | Output | `38 67 <count>` then per pair `index, hid1, hid2, mode\|flag, 00, 00` |

`flag` = `0x80` sets “report both keys”; up to 10 pairs.

## Key bindings (remapping)

Every key is addressed by HID usage code across **three independent layers**:

| Layer | Byte | Covers | Meaning |
|---|---|---|---|
| Normal | `0x00` | 91 keys | what the key does on its own |
| Meta (Fn) | `0x01` | 91 keys | what it does while the Fn key is held |
| Second actuation | `0x02` | 68 analog keys | what it does past a second, deeper press |

One mapping block is **6 bytes**: `hid, function, key_codes[4]` (the key's HID code, the function byte, then four code bytes).

| Command | Type | Bytes |
|---|---|---|
| Write bindings | Feature | `36 <layer> <count> [hid, fn, kc0..kc3]×count` |
| Read bindings | Feature (write, then read) | request `B6 <layer> <count> [hid,0,0,0,0,0]×count`; reply `B6 <err> <layer> <count> [hid, fn, kc0..kc3]×count` |
| Fn-bound-key bitmask | Output | `3C <32-byte mask>` — bit `hid & 7` of byte `hid / 8` |
| Choose the Fn trigger key | Output | `35 <hid>` |

Chunk capacity is `(645 − 5) / 6 = 106` keys, so all 91 fit in one report.

**`0x36` writes RAM only** — they survive the app and the host, but not a
keyboard power cycle. To make bindings survive unplugging, they must also be
written into the boot profile's flash image (§Onboard profiles below).

### `function` values

`00` UNBOUND · `01`–`08` mouse buttons 1–8 · `30` CPI · `31`/`32` wheel up/down ·
`33`/`34` AC pan left/right · `51` KEYBOARD · `61` CONSUMER · `62` firmware
function · `71` macro · `72` EXTERNAL (host-assisted).

- **KEYBOARD (`0x51`)** — `key_codes` is a set of up to four HID usages sent
  together; modifiers are ordinary usages (`E0`–`E7`), not a bitmask. Verified
  by round-trip: writing Caps Lock = `51 E0 04 00 00` reads back identically and
  types Ctrl+A.
- **CONSUMER (`0x61`)** — a consumer-page usage as a little-endian `uint16` in
  `key_codes[0..1]`. The firmware's own media buttons use `205` play/pause,
  `181` next, `182` prev, `226` mute, `233` vol-up, `234` vol-down.
- **Firmware function (`0x62`)** — the vendor's description names this META, which
  reads like "the Fn trigger", but that is *not* what it does. See below.

### The resting state is a self-mapping, not `UNBOUND`

Reading an unmodified keyboard back returns, for every one of the 91 keys:

```
04 51 04 00 00 00     A      → KEYBOARD, usage A
05 51 05 00 00 00     B      → KEYBOARD, usage B
…
```

So the factory state on the **normal** layer is each key explicitly mapped to
its own usage. Because every write is a complete frame for its layer, "restore
this key to normal" must write `51 <hid> 00 00 00`, **not** `function 0`. On the
meta and second-actuation layers the blank *is* `function 0` — a self-mapping
there would make every key fire itself.

### `0x62` is a built-in firmware action, and the Fn layer ships populated

A stock keyboard has nine `0x62` entries on the meta layer, each with a distinct
payload — these are the SteelSeries-key shortcuts:

| Key | `key_codes` | Key | `key_codes` |
|---|---|---|---|
| F9 | `01 00` | O | `06 00` |
| F10 | `02 01` | I | `07 00` |
| F11 | `03 01` | T | `08 00` |
| F12 | `04 01` | Q | `0A 00` |
| Left Cmd | `05 00` | | |

The individual ids are not documented anywhere checkable, so treat them as
opaque: read them, keep them, write them back unchanged. **Writing a blank meta
layer erases the keyboard's brightness / media / OLED shortcuts**; we know of no
command that regenerates them, so the way back we know of is a copy made earlier (a
profile dump). The key that *activates* the layer is chosen separately with `35 <hid>`.

### Reading bindings back

`0xB6` is a write-then-read on the Feature pipe: `SET_REPORT` the request, then
`GET_REPORT`. The reply's error byte sits **immediately after the command**
(as for the layout and region reads), so the header is
`command, err, layer, count` and the blocks start at offset 4.

The device answers `err = 1` with no payload when the request carries no block
list — the HID codes you want are part of the request, not implied. The feature
read slot holds the response to the **last** command, so a bare `GET_REPORT`
returns something like `40 00` (the acknowledgement of the previous
per-key colour write) rather than mapping data.

## OLED (128 × 40, 1 bpp)

The framebuffer is **640 bytes, SSD1306 page-major**: 5 pages (40 rows ÷ 8) × 128
columns; the byte at `page*128 + x` holds 8 vertically-stacked pixels for column
`x`, rows `page*8 … page*8+7`, **bit 0 = topmost**.

| Command | Type | Bytes |
|---|---|---|
| Live write (volatile) | Feature | `1F 81 [640 bytes]` |
| Persist (onboard image) | Feature | `38 83 00 [640 bytes]` |
| Reset (hand back to firmware) | Output | `1F 82` |

Use **live** (`1F 81`) for frequently-updated content (clock, stats) — it does
not touch flash. Use **persist** (`38 83`) to store an image that stays after the
app quits. Both are verified working on `0x1642`.

## Onboard profiles & the flash filesystem

**Every configuration command above writes keyboard RAM only.** Verified on
hardware (fw 1.19.7): after a `0x36` binding write, the flash image is
byte-for-byte unchanged — with the profile-volatility command (`0x34`) at either value. At
power-up the firmware loads the active slot's flash image, so anything not
written through this section is silently lost when the keyboard loses power. A
program that only sends live commands therefore loses its settings at power-off;
persisting means deploying a whole profile image, below.

Profiles live in a flash filesystem addressed by id `0x80 + slot`, slots 0–4.
All multi-byte integers are little-endian. Only those five ids have been used: the
erase and write commands below take any `<fs>`, and what other ids hold is not known,
so never send them with another id.

| Step | Type | Bytes |
|---|---|---|
| Erase slot entry | Output → Input | `02 01 <fs>` — the reply arrives when the erase finishes (allow several seconds; the app waits up to 6 s) |
| Write chunk | Feature | `03 01 <fs> <size u16> <offset u32> <data…>` — 500-byte chunks, ~13 ms apart |
| Validate slot | Output → Input | `B1 <slot>` — firmware CRC-checks what was written |
| Read chunk | Feature (write, then read) | request `83 01 <fs> <size u16> <offset u32>`; reply `83 <err> <data…>` |

All four are **confirmed on hardware**: a full slot-0 read parses exactly as
laid out below and its CRC matches; an erase + 25-chunk write + `B1` + full
read-back round-trips byte-for-byte (first proven on spare slot 4, then used
on slot 0).

### Image layout (profile schema 3, device schema 8, fw ≥ 1.19.0)

12 324 bytes: a 12 320-byte body followed by its CRC. Offsets:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | schema number, `3` |
| 4 | 24 | profile name, ASCII, zero-padded (factory: "Config 1"…"Config 5") |
| 28 | 48 | onboard lighting block — lock-key and Fn-key colours and brightness; at **40**, the 32-byte Fn-highlight mask (same layout as command `0x3C`) |
| 76 | 4 | Fn trigger key, as a HID code (factory `0xF0`, the SteelSeries key). The only place this setting can be read back. |
| 80 | 500 | normal-layer bindings — **100 slots × 5 bytes** (`function, key_codes[4]`), indexed by the firmware key table (`deviceKeyIndexToHID`), *not* HID-prefixed like `0x36` |
| 580 | 500 | Fn-layer bindings — same shape |
| 1080 | 4 | device schema number, `8` |
| 1084 | 70+70 | primary actuation thresholds: 70 `h` bytes, then 70 `l` bytes (raw Hall values, indexed by the first 70 firmware slots) |
| 1224 | 12+70 | three zone levels (factory 4,4,4), then a 70-byte per-key zone list — onboard-only, preserve |
| 1306 | 70×4 | second-actuation thresholds (`h` then `l`; disabled = `FF FF`), then release modes, then rapid-trigger sensitivity — 70 bytes each |
| 1586 | 4+70 | protection duration in ms (factory 500), then per-key protection distance (factory 20) — preserve |
| 1660 | 350 | second-actuation bindings, 70 slots × 5 bytes |
| 2010 | 640 | OLED bitmap (same SSD1306 layout as `1F 81`) |
| 2650 | 51 | rapid tap: 10 × `hid1, hid2, mode\|0x80·reportBoth, 0, 0`, then the enable byte |
| 2701 | 3 | padding |
| 2704 | 9600 | macro events — opaque, preserve |
| 12304 | 16 | GUID |
| 12320 | 4 | CRC |

The six media/OLED-button slots (hid `F1 F5 F6 F7 FE FF`) hold factory
CONSUMER bindings (`61 CD/B5/B6 E2 E9 EA`) and are not user-rebindable —
preserve them, as with the empty (`hid 0`) slots.

### CRC

STM32 hardware CRC-32: polynomial `0x04C11DB7`, init `0xFFFFFFFF`, no
reflection, no final XOR, fed as 32-bit little-endian words, over the 12 320
body bytes. Confirmed by reproducing the stored CRC of factory images.

### Writing safely

The image is erase-then-rewrite; there is no partial update. So: **always
read-modify-write** — the image carries fields the app cannot rebuild from its own state (macros,
GUID, the Fn layer's `0x62` shortcuts, settings written by other software) — and
never write an image that did not validate (size, schemas, CRC). Pad the last
chunk with `0xFF`. Verify with a full read-back
compare. Pause any lighting
stream around the write — flash operations stall the control pipe. A full
write (erase + 25 chunks + validate + verified read-back) takes ~2 s.

`ApexKit`'s `OnboardProfile` implements all of this; `apexctl profile
read|save|restore` is the CLI surface.

## Queries & misc

| Purpose | Request (Output) | Reply (Input) |
|---|---|---|
| Firmware version | `90 00` | `90 00 <ascii…>` (e.g. `1.19.7`) |
| Read region | `F5` | `F5 <err> <region_id>` |
| Read layout | `F2` | `F2 <err> <layout_id>` (0=US, 1=EU, 2=JP) |
| Load onboard profile | `B2 <id>` | — |
| Meta/Fn toggle key | `35 <hid>` | — |
| Profile volatility | `34 <0/1>` | — (**verified inert for persistence**: with either argument, a subsequent `0x36` write still does not reach flash.) |
| Write region (**flash!**) | `75 <region_id>` | — (avoid; writes flash every call) |

Region IDs: `1 US, 3 UK, 4 Germany, 6 France, 10 Nordic, 13 Japan, 20 Turkish`.

## Implementation notes verified on hardware

- Streaming full-frame direct-write faster than ~30 fps outpaces the LED
  controller and causes visible tearing; 33 ms/frame (30 fps) is clean.
- The Gen 3 TKL does **not** auto-reset its LEDs when you switch onboard configs,
  so a `41` clear is required to visibly hand lighting back.
- We know of no LED-brightness command in this family; in direct mode, brightness =
  scaling the RGB values you send.
- **86 LEDs, 91 rebindable keys, 68 adjustable switches** — three different sets.
  The LED list is `0x04–0x45`, `0x49–0x52`, `0xE0–0xE7`, `0xF0`, `0xFB`
  (`0xFB` is the play/pause button beside the OLED, which this model has an LED for).
  The six media/OLED buttons `0xF1`, `0xF5`–`0xF7`, `0xFE`, `0xFF` are hard-wired
  to consumer controls and are neither lit nor rebindable. `0x46`–`0x48`
  (Print Screen / Scroll Lock / Pause) do not exist on this board.
- Feature reads and writes coexist with another process driving lighting; the
  `0xB6` read stays correct while a 30 fps per-key colour stream is running.
