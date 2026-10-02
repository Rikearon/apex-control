# Using the command line

`apexctl` is a command-line front end to the same engine the app uses. Use it to
script the keyboard, to check what it really holds, and to experiment with the
protocol. Everything here is run in Terminal with the keyboard plugged in.

```bash
apexctl --version
apexctl help
apexctl info
```

`--version` prints the version (`apexctl 0.1.0` for the 0.1.0 release; a build from `master` between releases says so with a `-dev` version, such as `0.2.0-dev`). `help` lists
the commands and their arguments; one developer command, `debugoled`, is left out (see
[The OLED screen](#the-oled-screen)). `info` prints the firmware, region and layout the
keyboard reports, and the key counts `apexctl` works with.

The examples below are lists with one command to an item, not blocks to paste
whole: several of them change what the keyboard does. Copy them one at a time. There
are no `# comment` lines inside the commands, because zsh, the default shell on a
Mac, does not treat a pasted `#` as a comment unless you run
`setopt interactive_comments` first.

## Getting it

- **From a release:** unzip `apexctl-<version>-macos.zip` and copy `apexctl` to a
  folder on your `PATH`, for example with
  `sudo mkdir -p /usr/local/bin && sudo cp apexctl /usr/local/bin/`. If macOS refuses
  to run it because it was downloaded, run `xattr -d com.apple.quarantine apexctl`
  once.
- **From source:** `swift build -c release`, then use `.build/release/apexctl`. A
  plain `swift build` puts it at `.build/debug/apexctl`.

The examples below write `apexctl`; substitute the path you have.

## Things to know first

- **Quit Apex Control first.** The app and `apexctl` both write to the keyboard, and
  the keyboard keeps whichever wrote last. The app draws animated lighting itself,
  sends its settings again whenever it connects and whenever the Mac wakes, and saves
  them into the keyboard's slot 0 a few seconds after you change something. So it can
  replace what `apexctl` writes, and what `apexctl` writes can leave the app out of
  step with the keyboard. If SteelSeries GG is installed, quit it and its helper
  processes too.
- **It talks to the keyboard directly.** The keyboard must be plugged in with its
  USB cable. If it is not found, `apexctl` says
  `error: No Apex Pro TKL Gen 3 (0x1038:0x1642) found. Is it plugged in?` and exits
  with status 1.
- **Errors go to standard error** as `error: …`, with exit status 1.
- **Some commands cannot tell you a write failed.** `solid`, `key`, `rainbow`,
  `wave`, `clear`, `actuation`, `rapidtrigger` and `oled` print their usual
  message even if the keyboard rejected the write. If it matters, check afterwards
  (`apexctl bindings`, or look at the keyboard). The other commands (`bindings`,
  `bind`, `unbind`, `fn`, `reset-bindings`, `verify`, `profile`, and every `raw`
  command) do report failures. This is a [known issue](KNOWN-ISSUES.md).
- **The output is for people.** Do not parse it: its format may change. A stable
  interface for automation is planned ([PRD-25](prd/PRD-25-automation-integration-interface.md)).
- **Most settings vanish when the keyboard loses power.** Commands write the
  keyboard's [RAM](README.md#glossary) unless they say otherwise. See
  [what writes what](DEVELOPMENT.md#the-hardware-verification-loop) and
  [How a setting reaches the keyboard](ARCHITECTURE.md#how-a-setting-reaches-the-keyboard).

## Naming keys

Commands that take a key accept:

- its **label** on the keyboard, in any case: `W`, `Space`, `Esc`, `F12`, `Caps`,
  `Tab`, `Enter`, `Ins`, `Del`, `Home`, `End`, `PgUp`, `PgDn`, `SS` (the SteelSeries
  key), the arrows as `←` `↑` `↓` `→`, and the number-row digits `1` to `0`.
- a **full name** as the app's key picker writes it, with its space: `"Left Ctrl"`,
  `"Right Shift"`, `"Left Cmd"`, `"Caps Lock"`, `"Print Screen"`, `"Page Up"`,
  `"Keypad 1"`, and also `Backspace` (the keyboard labels that key ⌫), `Return` and
  `Escape`. Only the picker's own names work, not the aliases its search box also
  understands, and only for the [HID](README.md#glossary) usages the picker lists
  (letters, numbers, punctuation, editing keys, arrows, F1 to F24, keypad, modifiers,
  system and international keys). This also reaches keys the keyboard does not have,
  such as `F13` to `F24`.
- a **HID usage code**, in hex or decimal: `0x39` or `57`.

Labels are tried first, so a single digit always means the number-row key: `4` is the
key labelled 4, not usage code 4. Write `0x04` for usage code 4 (the A key).

Names with a space need quotes, and `LeftCtrl` is not a name. Where several keys
share a label (`Shift`, `Ctrl`, `Alt`, `Cmd`), the bare label means the left-hand
key; write `"Right Ctrl"` and the like to be explicit. If a name is wrong, `apexctl`
says `unknown key` and changes nothing.

## Lighting

Lighting is written to RAM in "direct mode". The last frame stays on the keyboard
until you `clear` it or it loses power.

- `apexctl solid '#FF4A00'`: every key one colour.
- `apexctl key W '#00FF00' A '#00FF00' S '#00FF00' D '#00FF00'`: only these four keys lit; every other key goes black.
- `apexctl rainbow 8`: an 8 second animated rainbow, then it holds the last frame.
- `apexctl rainbow 8 30`: the same at 30 frames per second (the default, and the most the keyboard keeps up with).
- `apexctl wave 8`: a moving wave for 8 seconds.
- `apexctl clear`: hand lighting back to the keyboard's own.

Colours are `#RRGGBB`; quote them, because an unquoted `#` can be read as the start
of a comment. `rainbow` and `wave` default to 5 seconds.

**`key` sends a complete frame, so every key you do not name goes black.** It does not
add to what is already lit. `rainbow` takes an optional frame rate and limits it to 1
to 30, because the LED controller keeps up with 30 at most and faster frames make the
lighting tear ([PROTOCOL.md](PROTOCOL.md)); `wave` always runs at 30. Durations are
limited to 0 to 3600 seconds.

## Actuation and Rapid Trigger

Actuation is a **level from 1 to 40**: 1 is 0.1 mm (very sensitive) and 40 is
4.0 mm (deep). A number outside that range is clamped. The millimetre figures are
nominal: the thresholds behind each level come from the vendor's description of the
device, and the physical travel at each level has not been measured
([Compatibility](COMPATIBILITY.md)).

- `apexctl actuation 8`: every adjustable key to 0.8 mm.
- `apexctl actuation 8 --rapid-trigger`: the same, with Rapid Trigger on (sensitivity 2).
- `apexctl actuation 8 --rapid-trigger 3`: the same, with Rapid Trigger at sensitivity 3 (in 0.1 mm steps, from 1 to 20).
- `apexctl rapidtrigger off`: turn Rapid Trigger off on every key.

These write RAM only, and **`apexctl` has no command to save actuation or Rapid
Trigger into the keyboard's flash**, so they are lost when the keyboard loses power.
The app saves them for you, automatically, as it does for rapid tap.

## Key bindings

- `apexctl bindings`: all three layers, read back off the keyboard.
- `apexctl bindings meta`: one layer: normal, meta (Fn) or second.

`bindings` lists only the keys that are not at their factory behaviour, one per
line, with the key, its HID code, the function and key-code bytes, and what it
means. A stock keyboard reports the nine factory Fn shortcuts on the `meta` layer
(they are listed in [PROTOCOL.md](PROTOCOL.md)).

- `apexctl bind Caps key "Left Ctrl"`: Caps Lock becomes Left Ctrl.
- `apexctl bind F12 key 4 +cmd +shift`: F12 sends Cmd+Shift+4.
- `apexctl bind SS media playPause`: the SteelSeries key plays and pauses.
- `apexctl bind Caps disable`: the key sends nothing.
- `apexctl bind Caps raw 51 39`: raw bytes, in hex: function 51 (keyboard), key code 39 (Caps Lock).
- `apexctl bind --layer meta J key Esc`: on the Fn layer instead: Fn+J sends Esc.
- `apexctl unbind Caps`: back to the layer's default.
- `apexctl unbind J --layer meta`: the same on the Fn layer.
- `apexctl reset-bindings`: normal and second layers back to stock (the Fn layer is kept).
- `apexctl fn SS`: choose the Fn key (or `fn none` for no Fn key). Only the rebindable
  keys are accepted.
- `apexctl verify`: a write-and-read-back self-test (read the notes below first).

For `bind`, put `--layer` right after `bind`; `unbind` takes `--layer` anywhere after
the key. The layers are `normal`, `meta` (or `fn`) and `second`.

**Modifiers** for `bind … key` are `+ctrl` `+shift` `+alt` `+cmd`, and their
right-hand forms `+rctrl` `+rshift` `+ralt` `+rcmd`.

**Media** actions: `playPause`, `nextTrack`, `previousTrack`, `mute`, `volumeUp`,
`volumeDown`, and the less certain `play`, `pause`, `stop`, `fastForward`, `rewind`,
`brightnessUp`, `brightnessDown`, `launchEmail`, `launchCalculator`,
`launchBrowser`, `launchMediaPlayer`, `browserHome`, `browserBack`,
`browserForward`, `browserRefresh`, `browserSearch`. The first six are the ones the
keyboard's own buttons use; the firmware may ignore the rest.

**Mouse** actions: `button1` to `button8`, `wheelUp`, `wheelDown`, `panLeft`,
`panRight`.

**Raw** bindings take hex bytes: the function byte, then up to four key-code bytes.

Writing a binding **reads the layer first and writes back a complete frame**, so it
never clobbers keys you did not name. Reading back is intermittent on firmware
1.19.7, so the read can fail. When it does, `bind` and `unbind` write nothing, on any
layer, and say so:

```text
error: could not read the Normal layer (…). Writing it without reading it first would reset every other key on it, so nothing was written. Try again.
```

The layer is named `Normal`, `Fn Layer` or `Second Actuation`. Run the command again.

`reset-bindings` puts the normal and second layers back to factory behaviour and
leaves the Fn layer alone. Like the other commands here it changes the keyboard's RAM
only, so the old bindings return when the keyboard next loses power. To make the
reset last, follow it with `apexctl profile save`.

`verify` uses Caps Lock as its probe key: it reads the normal layer, rebinds Caps
Lock to Ctrl+A, reads that back, and writes the layer back as it found it. It saves
nothing to flash. If a step after the first read fails, `verify` stops without
restoring, and Caps Lock stays on Ctrl+A until you run `apexctl unbind Caps` or the
keyboard loses power ([known issue](KNOWN-ISSUES.md)).

Take care on the Fn layer: F9 to F12, Q, T, I, O and Left Cmd already hold the
keyboard's own brightness, media and screen shortcuts. Binding one, disabling it or
running `unbind` on it **overwrites** it: `unbind` puts a key back to the
layer's blank, which on the Fn layer is nothing, not the factory shortcut. Three
rules are enforced for you:

- Keys the keyboard cannot rebind (its media and screen buttons) are refused.
- The second-actuation layer only takes the adjustable keys (68 in the firmware's
  table, 61 of them on an ANSI board).
- **No layer is written blind.** If `bind` or `unbind` cannot read a layer first, it
  refuses to write it (above). This matters most for the Fn layer, which ships
  holding the keyboard's own shortcuts, which we know of no command to restore.

`apexctl` can write a deeper-press binding on the second-actuation layer, but it has
no command to set how deep the second point is, so the binding does nothing until
the key has one. Set the depth in the app (Key Bindings, *Pressed deeper*).

All of these write RAM, and are lost when the keyboard loses power. Run
`apexctl profile save` to keep the **bindings**. (It does not save the Fn key you
chose with `apexctl fn`; the app saves that.)

## Onboard profiles (flash)

The keyboard keeps five setups of its own, **slots 0 to 4** here (1 to 5 in the app).
`profile save` and `profile restore` are the commands that write an onboard profile
into the keyboard's [flash](README.md#glossary). (`oled persist`, below, stores a
screen with a different command; where that goes is not recorded.)

- `apexctl profile read 0`: summarise slot 0 (name, CRC, Fn key, bindings).
- `apexctl profile read 0 --out slot0.bin`: the same, and save the whole image to a file.
- `apexctl profile save`: persist the current bindings into slot 0.
- `apexctl profile save 2`: the same, into slot 2.
- `apexctl profile restore 0 slot0.bin`: write a dumped image back (verified).
- `apexctl profile 1`: ask the keyboard to switch to slot 1.

- `profile save` reads the slot, replaces its bindings (all three layers) and the Fn
  highlight with what the keyboard holds now, writes it back, and verifies by reading
  it back. Everything else in the image (macros, lighting, actuation, rapid trigger,
  rapid tap, the Fn key, the name) is kept exactly as it was.
- `profile restore` checks the file's size, schema and CRC before it writes
  anything. It rewrites the whole slot (an erase, then the image), so settings changed
  since the dump are lost, and unplugging the keyboard part-way through can leave the
  slot empty. Quit Apex Control first, and unplug and replug the keyboard afterwards
  so that it starts from the restored image: the keyboard loads its boot profile from
  flash at power-up. When you next open the app it applies the last profile you used
  (if **Restore the last profile on launch** is on), which can replace the restored
  settings.
- The image contains your keyboard's GUID. Keep dumps out of public issues.
- `profile <slot>` only asks the keyboard to switch. Whether that choice survives a
  power cycle is [unconfirmed](COMPATIBILITY.md).

A dump before you experiment is a good habit: `apexctl profile read 0 --out backup.bin`.
Apex Control itself writes slot 0 whenever its settings differ from what the keyboard
has saved, a few seconds after you change something, so take the dump before you first
run the app if you want to keep the keyboard exactly as it is now.

## The OLED screen

- `apexctl oled text "Hello" "world"`: one or two lines, live.
- `apexctl oled image logo.png`: scaled to fit 128 x 40, black and white.
- `apexctl oled persist text "Hello"`: store it in the keyboard so it stays after apexctl exits.
- `apexctl oled persist image logo.png`: the same for an image.
- `apexctl oled clear`: hand the screen back to the firmware.

Without `persist`, the screen is written live, which is volatile. `persist` uses a
different command that stores the screen so it stays after `apexctl` or the app has
exited; whether it also survives unplugging has not been recorded
([Compatibility](COMPATIBILITY.md)). Text is drawn in a bold font, centred; one line is
larger than two.

`apexctl debugoled "Text"` is a developer command that `help` does not list. It prints
the 128 × 40 bitmap for that text as ASCII art and does not touch the keyboard.

## Raw access

For protocol work and debugging. These send exactly what you give them, so know what
a command does first: some commands write flash (for example `0x75`, the region write,
touches flash on every call), and the flash-filesystem commands (`02 01 <fs>` erase,
`03 01 <fs>` write) can overwrite whatever the id names. Only `<fs>` values `0x80` to
`0x84`, the five profile slots, have been used; never send them with another id, and
take a dump first (`apexctl profile read 0 --out backup.bin`). Arguments are hex bytes (one or two digits, with or
without `0x`). See
[Development](DEVELOPMENT.md#the-hardware-verification-loop) and [PROTOCOL.md](PROTOCOL.md).

- `apexctl raw query --delay 20 --gets 3 B6 00 01 04`: read one key's binding; read-only.
- `apexctl raw read 644`: GET_REPORT with no preceding write.
- `apexctl raw feature <hex bytes...>`: send a Feature report as-is.
- `apexctl raw output <hex bytes...>`: send an Output report as-is.

`raw query` also takes `--delay <ms>` (a pause between the write and the read, or
between polls), `--gets <n>` (repeat the write-and-read n times) and `--poll <n>` (write
once, then read up to n times until the reply's error byte clears). Every `raw` command
stops with an error, and sends nothing, if an argument is not a hex byte or if there
are too many bytes (64 for `output`, 644 for `feature` and `query`), and a failed
send is reported.
