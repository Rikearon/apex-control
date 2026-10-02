# Known issues

Rough edges found in review (2026-09-28), checked against the source. Most are places where the interface says
something slightly different from what the code does. They are listed here so that
nobody is surprised by them, and because each is a good first contribution. A few can
leave the keyboard in a state you did not choose; the ones about saving into flash,
the Fn layer, `apexctl verify` and `apexctl reset-bindings` say how. Replacing one of
the keyboard's own Fn shortcuts erases it, and we know of no command that brings it back;
`apexctl raw` can do worse: it sends exactly the bytes you give it.

When you fix one, delete it from this list and mention it in
[CHANGELOG.md](../CHANGELOG.md). Items marked *suspected* were read from the code but
not reproduced on a keyboard.

Paths are relative to `Sources/`.

## Behaviour that can surprise you

- **"Turn Lighting Off" does not hand lighting back.** It paints the board black
  while the app stays in charge. Only *Hand Lighting Back to Keyboard* (menu bar or
  Keyboard menu) and `apexctl clear` return the LEDs to the keyboard.
  `setLightingOff` vs `handBackToKeyboard` in
  `ApexControlApp/Model/DeviceController.swift`.
- **Hand-back does not stick.** After handing lighting back, the app takes the LEDs
  again on wake and on replug, while the pane still says it is handed back. Applying a
  profile takes them again too, but that clears the message. `applyAll` never checks
  `isHandedBack` (`ApexControlApp/Model/DeviceController.swift`). *Fix:* skip the
  lighting part of `applyAll` while handed back.
- **`apexctl` cannot always tell you a write failed.** `solid`, `key`, `rainbow`,
  `wave`, `clear`, `actuation`, `rapidtrigger` and `oled` discard errors with
  `try?` and print a success message. *Fix:* report the error and exit non-zero
  (`apexctl/main.swift`). A good first issue.
- **`apexctl reset-bindings` changes live memory only.** The old bindings come back
  when the keyboard next loses power, unless you follow it with `apexctl profile save`
  (with Apex Control quit). The Reset all keys button in the app saves for you.
- **`apexctl verify` can leave Caps Lock rebound.** It probes with Caps Lock: it
  rebinds it to Ctrl+A, reads the layer back, and writes the layer back as it found it.
  If the read after the write fails (read-back is intermittent on firmware 1.19.7), it
  stops without restoring, and Caps Lock stays on Ctrl+A in the keyboard's RAM until
  `apexctl unbind Caps` or a power cycle. (`apexctl/main.swift`.) *Fix:* restore the
  layer whatever happens.
- **`apexctl profile save` persists only bindings.** The app also persists actuation,
  Rapid Trigger, rapid tap and the Fn key (`patchedImage` in
  `ApexControlApp/Model/DeviceController.swift`), so `apexctl` has no way to save those
  to [flash](README.md#glossary). *Fix:* have `profile save` share the app's patching
  logic.
- **The menu-bar and Keyboard-menu "Reset All Key Bindings" ask no confirmation.** The
  pane's button does. (`ApexControlApp/Views/MenuBarView.swift`,
  `ApexControlApp/App.swift`.)
- **"Clear the Fn layer too" also sets "no Fn key".** Its dialog mentions only the
  erased shortcuts. *Suspected:* undoing it restores the shortcuts but not the Fn key.
  (`resetFnLayer` in `ApexControlApp/Model/DeviceController.swift`.)
- **Replacing a factory Fn shortcut with Key, Media, Mouse or Raw asks no
  confirmation.** Only Default, Off and Reset this key do; dragging a key onto one shows
  "replaces a factory shortcut" but does not ask. The inspector shows a warning: Undo
  can bring the shortcut back only while the app stays open.
  (`ApexControlApp/Views/BindingsView.swift`.)
- **Undo may not bring back a replaced factory shortcut.** *Suspected:* Undo restores
  the app's own copy of the bindings, and that copy holds a factory shortcut only if the
  editor was filled from the keyboard (on connect with no bindings of its own, or with
  **Read from keyboard**). After a profile with bindings has been applied, undoing the
  replacement of a shortcut may leave the replacement on the keyboard. (`setBinding`,
  `recordUndo` and `undoBindingChange` in `ApexControlApp/Model/DeviceController.swift`.)
  *Fix:* fold the keyboard's layer into the snapshot, as `resetFnLayer` already does.
- **A first launch pushes the app's own defaults**: a Rainbow Wave and the OLED text
  "APEX PRO / Gen 3". Until the app has read the keyboard's saved profile, the default
  actuation (1.5 mm), Rapid Trigger (off) and Rapid Tap (off) go to the keyboard's RAM
  as well; when the read succeeds, the app adopts the saved values and sends those
  instead, and if it cannot read the profile the defaults stay. The app also re-sends
  its OLED content whenever it connects, so a screen saved with *Save to keyboard* can
  be replaced at the next launch.
- **Only the profile marked "In use" is restored at launch.** Applying a profile, or
  creating one with Save current setup, marks it; **Save over it** does not. The Settings text
  "the keyboard comes back looking the way you left it" is broader than that: lighting,
  the screen and the lights-off state are not remembered on their own.
- **Saving into the keyboard's flash has no off switch and no automatic backup.** The
  app rewrites onboard slot 0, an erase and then the whole image, a few seconds after
  any settled edit, after a profile is applied, and when it connects or the Mac wakes
  and its state differs from what the keyboard holds. Take a copy yourself before the
  first run: `apexctl profile read 0 --out backup.bin`. The erase comes first, so a
  failure part-way through can leave the slot empty; only the final read-back is
  checked (the replies to the erase and validate steps are not inspected); and after a
  failed write the next connect finds a slot with a bad CRC and refuses to write to it,
  so the app cannot repair it (restore the copy with `apexctl profile restore`).
  *Fix:* a backup before the first write or an opt-in switch, one rollback attempt, and
  a retryable state that points at `restore` ([PRD-05](prd/PRD-05-onboard-profile-persistence.md)
  FR-6, [PRD-29](prd/PRD-29-device-backup-restore-rescue.md)). *Suspected:* the save at
  quit can queue a second erase behind one already in flight, and gives up after eight
  seconds, less than the erase timeout plus the write.
- **The screen saved with *Save to keyboard* may be overwritten by the next automatic
  save.** *Suspected:* saving the screen does not refresh the app's copy of the flash
  image, and the automatic save never patches the screen region, so the next save may
  write the older copy back. (`persistOLED` and `patchedImage` in
  `ApexControlApp/Model/DeviceController.swift`.)
- **Some replies may be mistaken for others.** *Suspected:* `HIDTransport.query` returns
  the next Input report of any kind, and writes are not serialised with reads, so a
  reply can be taken for the wrong request while lighting is streaming. It may be part of
  why reading bindings back is intermittent (the keyboard answers a read with the reply
  to the last command); an untested idea is to pause the lighting stream during reads.
- **Switching an onboard slot leaves the app unsure of the truth.** It cannot read the
  active slot back, and its automatic saving always targets slot 0. *Suspected:* the
  "Saved in the keyboard" tag can be wrong after a switch.
- **A saved profile that uses an OLED image stores an absolute path**, so exported
  profiles are not portable, and the path can contain your Mac user name: look at an
  exported file before you share it. Importing accepts any JSON object (an unrelated
  one becomes a profile named "Untitled").

## Interface text that is out of date or misleading

- **Lighting toolbar tooltip:** "Hand lighting back to the keyboard" while the lights
  are on. The button turns the lights off. (`ApexControlApp/Views/ContentView.swift`.)
- **"Start from the last effect"** (Per-Key) says it copies the colours on the keyboard,
  but it always seeds a Rainbow Wave snapshot, not whatever was running.
  (`ApexControlApp/Views/LightingView.swift`.)
- **Rapid Trigger, "Arrow keys" chip** selects nothing, because the arrow keys are not
  adjustable switches. It behaves like "Nothing".
  (`ApexControlApp/Views/RapidTriggerView.swift`.)
- **Rapid Tap mode names** ("Newest press wins", "Neither one counts", "always wins")
  have no documented source; only "Send both" is backed by the protocol. They need
  hardware verification, or honest labels.
- **Settings, permission note** says "Quit and reopen Apex Control", but the button for
  that exists only on the Lighting pane. (`ApexControlApp/Views/SettingsView.swift`.)
- **Storage tags** overclaim in two places: keyboard panes read "Written into the
  keyboard and saved to its onboard profile" even while disconnected, and the OLED and
  Profiles panes read "It stops when the app quits", though a screen can be saved to the
  keyboard and profiles are a file on disk.
- **Re-light after the Mac wakes** says it resends "the current frame and screen"; it
  re-applies everything (actuation, rapid tap, bindings, screen) and can trigger a
  flash write.
- **Naming drift:** "Keyboard's own" and "Firmware default" for the same screen mode;
  "No keyboard", "Not found" and "Searching for keyboard…" for the same state;
  "Reset all keys", "Reset all key bindings" and "Reset All Key Bindings".
- **Speed readout** (`0.50 ×`) is not a literal multiplier; the slider maps 0 to 1 onto
  0.1 to 2.0.
- **Grid selection:** the Actuation hint says "Drag across several to work through a
  row", but dragging only moves the single selection.

## Housekeeping

- `AppPrefs.hasShownBackgroundHint` (`ApexControlApp/Model/AppPrefs.swift`) is
  persisted but never read.
- `DeviceController.statusMessage` (`ApexControlApp/Model/DeviceController.swift`) is
  set while connected and never shown.
- The app has no logging at all (no `os.Logger`); errors surface as banners only, and
  failed read-back on connect is silent, apart from a note in the Bindings pane. This
  makes bug reports harder than they should be
  ([PRD-35](prd/PRD-35-diagnostics-support-bundle.md)).
- A few facts are unconfirmed and documented as such: what Rapid Trigger release modes
  3 and 4 do, what the profile-volatility command (`0x34`) means, and whether the OLED image
  or the active slot survive a power cycle ([Compatibility](COMPATIBILITY.md)).
