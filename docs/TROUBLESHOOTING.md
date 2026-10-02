# Troubleshooting

The common problems, and what to do about each. If yours is not here, see
[Getting help](../SUPPORT.md).

- [The keyboard is not found](#the-keyboard-is-not-found)
- [macOS will not open the app](#macos-will-not-open-the-app)
- [The lighting fights with something, or comes back after I turned it off](#the-lighting-fights-with-something-or-comes-back-after-i-turned-it-off)
- [I want the keyboard's own lighting back](#i-want-the-keyboards-own-lighting-back)
- [Reactive lighting does nothing](#reactive-lighting-does-nothing)
- [Reactive lighting only reacts to Shift, Control, Option and Command](#reactive-lighting-only-reacts-to-shift-control-option-and-command)
- [My settings come back after I unplug the keyboard](#my-settings-come-back-after-i-unplug-the-keyboard)
- [Reading the bindings fails](#reading-the-bindings-fails)
- [A key I changed is still changed with the app closed](#a-key-i-changed-is-still-changed-with-the-app-closed)
- [I erased the keyboard's own Fn shortcuts](#i-erased-the-keyboards-own-fn-shortcuts)
- [The OLED shows "APEX PRO / Gen 3" instead of my screen](#the-oled-shows-apex-pro--gen-3-instead-of-my-screen)
- [My lighting is not there after a restart](#my-lighting-is-not-there-after-a-restart)
- [Open at login does not work](#open-at-login-does-not-work)
- [The window closes and the app keeps running](#the-window-closes-and-the-app-keeps-running)
- [The build fails](#the-build-fails)
- [Starting fresh, and uninstalling](#starting-fresh-and-uninstalling)

## The keyboard is not found

The sidebar says **No keyboard** and **Searching for keyboard…** (after an unplug it
says *Keyboard disconnected — reconnect and it will resume*), the Settings pane says
**Not found**, or `apexctl` says
`No Apex Pro TKL Gen 3 (0x1038:0x1642) found. Is it plugged in?`

- **Use the USB cable.** Only the wired Apex Pro TKL Gen 3 is supported. The
  wireless variants and the full-size Apex Pro Gen 3 are believed to use different
  protocols ([Compatibility](COMPATIBILITY.md)).
- **Check that macOS sees it.** In Terminal:

  ```bash
  system_profiler SPUSBHostDataType SPUSBDataType | grep -i -A12 apex | grep -E 'Apex|Vendor ID|Product ID|Product Version'
  ```

  You should see `USB Vendor ID: 0x1038` and `USB Product ID: 0x1642`. If nothing
  prints, macOS cannot see the keyboard: try another cable and port, connect it
  directly rather than through a hub or dock, and restart the Mac.
- If you see a different Product ID, you have a different model.
- There is nothing to press in the app. It picks the keyboard up on its own as soon
  as it appears, and again after a replug.

## macOS will not open the app

Release builds are not [notarized](README.md#glossary) (there is no Apple Developer
ID yet), so Gatekeeper blocks the first launch with a message that Apple cannot check
the app.

1. Try to open Apex Control once, then dismiss the message.
2. Open **System Settings, then Privacy & Security**, scroll to the message about
   Apex Control, and choose **Open Anyway**. Confirm with your password.

Or clear the quarantine flag once from Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Apex Control.app"
```

If you would rather not run a binary someone else built, build it yourself
(`make app`); see [Privacy and security](PRIVACY.md#releases).

## The lighting fights with something, or comes back after I turned it off

- **SteelSeries GG.** Its background helpers may fight Apex Control for the lighting.
  Apex Control does not need GG and should be able to coexist with it (not tested with
  GG running), but quitting GG (and its helper processes) gives the cleanest result.
- **Two copies of Apex Control.** Opening a second copy of the app focuses the first
  and quits; it does not start a second engine. That check goes by the app's bundle
  identifier, so it cannot recognise a copy with a different identifier, or with none
  (one started with `swift run` is not an app bundle). If you run two like that, quit
  one of them.
- **"Turn Lighting Off" is not "hand back".** It paints the board black while the app
  stays in charge. Picking an effect, or applying a profile, lights it again. Waking
  the Mac does not: the app sends the black frame again. The lights-off state is also
  forgotten when the app restarts (see
  [My lighting is not there after a restart](#my-lighting-is-not-there-after-a-restart)).
  To give lighting back, see the next section.

## I want the keyboard's own lighting back

Use **Hand Lighting Back to Keyboard**, from the *Keyboard* menu or the menu bar,
or run `apexctl clear` in a terminal. That stops the app streaming and returns the
LEDs to the keyboard's onboard lighting.

- **Turn Lighting Off**, and any effect with a black colour (Static in black, for
  example), do *not* do this. They paint black, and the app keeps control.
- **Quitting does not do this either.** The keyboard keeps the last frame it was
  sent, so your colours stay, just frozen.
- After handing back, the app takes control again when the Mac wakes and when the
  keyboard is replugged, and the pane keeps saying the keyboard is lighting itself
  ([Known issues](KNOWN-ISSUES.md)). Changing any lighting setting, pressing **Take
  over**, or applying a profile also takes control, and those clear the message. If
  you want the keyboard's own lighting to stay, hand it back and then quit Apex
  Control, and leave **Open at login** off, or the app takes over again when it
  starts.

## Reactive lighting does nothing

Reactive lighting needs macOS to let the app see which key you pressed. Open the
**Lighting** pane with Reactive selected, and read what it says:

- *"Reactive needs permission to see which keys you press"*: press **Grant
  permission…**, or open **Input Monitoring…** or **Accessibility…** and tick Apex
  Control. Either one is enough ([what they are](README.md#glossary)). Nothing else in
  the app needs either.
- *"Permission is granted, but macOS only hands it to apps that start after it is
  given"*: press **Quit and reopen**.
- *"A password field is open, so macOS is hiding key presses from every app on the
  Mac"*: macOS "secure input" is on. A password field turns it on, and so can an app,
  for example Terminal's *Secure Keyboard Entry* option. Reactive picks up again as
  soon as you leave the field or switch the option off.
- The pane says *Watching key presses*, and names the last key it saw, but nothing
  lights: the permission is fine, so check the effect's Brightness and colour.

## Reactive lighting only reacts to Shift, Control, Option and Command

The pane says macOS is "letting Apex Control hear only the modifier keys". Shift,
control, option and command ripple from anywhere, but letters light only while
Apex Control is the app you are typing into.

This is what a permission that is *ticked but not honoured* looks like. macOS
creates the key listener and then quietly withholds other apps' key presses. The
usual causes:

- The permission was granted **after** the app started. Use **Quit and reopen**.
- **The app was rebuilt from source.** macOS ties the grant to the app's code
  signature, and an ad-hoc signature changes on every rebuild, so the new copy is a
  different app that merely looks ticked. Remove Apex Control from the list with
  "−", add the current copy again, then quit and reopen.
- To stop this happening on every rebuild, sign your builds with a stable local
  certificate: [Keeping permissions across rebuilds](DEVELOPMENT.md#keeping-permissions-across-rebuilds).

## My settings come back after I unplug the keyboard

Bindings, the Fn key, actuation, Rapid Trigger and Rapid Tap are saved into the
keyboard's [flash](README.md#glossary) a few seconds after you stop changing them, so
they should survive unplugging ([Compatibility](COMPATIBILITY.md) says what has been
checked). On the four panes tagged **Stored in the keyboard** (Key
Bindings, Actuation, Rapid Trigger and Rapid Tap), the tag at the top right says where
that stands. The other panes do not show a save state.

- *Saving to the keyboard…*: wait a few seconds. Do not unplug yet.
- *Saved in the keyboard*: it is safe to unplug.
- *Not saved to the keyboard*: the write failed; a banner says why. Try again.
- *Can't save to this keyboard*: the keyboard's stored profile is in a format the
  app does not recognise, so it does not write to it. Your changes still take effect while
  the keyboard is powered, but will not survive a power cycle. If the profile was fine
  until a save failed part-way, a dump you made earlier can put it back; the steps are
  under [I erased the keyboard's own Fn shortcuts](#i-erased-the-keyboards-own-fn-shortcuts).

Things that are **not** saved automatically:

- Changes made with `apexctl` are written to RAM only. Quit Apex Control, then run
  `apexctl profile save` to keep bindings; `apexctl` cannot save actuation or Rapid
  Trigger.
- Lighting, and the OLED screen unless you chose **Save to keyboard**. Lighting
  effects are drawn by the Mac; see [What stays where](USING-THE-APP.md#what-stays-where).
  A saved screen stays after you quit the app; whether it also survives unplugging has
  not been recorded.
- A force-quit or crash loses edits from the last few seconds. A normal quit saves
  them first, without the read-back check that the automatic save does, so that
  quitting stays quick.

## Reading the bindings fails

When the app connects it reads the bindings off the keyboard quietly. If the keyboard
does not answer, the only sign is a note in the **What the keyboard says** card of the
Key Bindings pane: *"This keyboard did not answer when asked for its bindings.
Writing still works; Apex Control just cannot confirm the result."* If you press
**Read from keyboard** (the toolbar button, or ⇧⌘R), a failure shows a red banner
instead: *"Could not read bindings from the keyboard: …"*.

Reading bindings back is intermittent on firmware 1.19.7: the keyboard acknowledges
the request but only sometimes returns the data. The app retries. Try **Read from
keyboard** again. Writing bindings from the app still works; it just cannot confirm the
result. `apexctl bind` and `unbind` need the read to succeed, so they stop instead of
writing; run them again ([Using the CLI](USING-THE-CLI.md#key-bindings)).

## A key I changed is still changed with the app closed

That is by design. Bindings live in the keyboard, so a key you disabled stays
disabled with Apex Control closed, and should stay so on any other computer.

- **Reset all keys** (in the Key Bindings pane) puts the keys on the main and deeper
  layers back, after asking. The menu-bar and Keyboard-menu versions do not ask. The
  app saves the reset into the keyboard for you.
- `apexctl reset-bindings` does the same on the keyboard's live settings only, so the
  old bindings return when the keyboard next loses power. Quit Apex Control, run
  `apexctl reset-bindings`, then `apexctl profile save`
  ([Using the CLI](USING-THE-CLI.md#key-bindings)).
- Neither touches the Fn layer, which holds the keyboard's own shortcuts.

## I erased the keyboard's own Fn shortcuts

The keyboard ships with nine Fn shortcuts of its own (brightness, media and the
screen). We know of no keyboard command that recreates one once it is erased, so the
two ways back are Undo and a profile dump you made earlier.

- **If the app is still open, press ⌘Z** (Undo). It usually can put them back (see
  [Known issues](KNOWN-ISSUES.md)).
- If you saved a dump before they were erased (`apexctl profile read 0 --out
  backup.bin`), quit Apex Control, run `apexctl profile restore 0 backup.bin`, then
  unplug and replug the keyboard so that it starts from the restored image. A restore
  rewrites the whole slot, so anything you changed since the dump is lost, and
  unplugging the keyboard during it can leave the slot empty.
- Otherwise we know of no way to bring them back. The nine entries are
  recorded in [PROTOCOL.md](PROTOCOL.md#0x62-is-a-built-in-firmware-action-and-the-fn-layer-ships-populated),
  so writing them back with `apexctl bind --layer meta ... raw` might work, but that has
  not been tried and they may differ between keyboards, so ask in an issue first. This
  is why the pane asks before erasing one, and why [contributors are told](../CONTRIBUTING.md#ground-rules)
  never to write the Fn layer without reading it first.

## The OLED shows "APEX PRO / Gen 3" instead of my screen

While it is running, the app sends its own screen content whenever the keyboard
connects or the Mac wakes. With a fresh setup that is the default text "APEX PRO"
and "Gen 3". Set the **OLED Screen** pane the way you want it, and save a profile so
that it is restored at launch (**Restore the last profile on launch** is on by
default). **Save to keyboard** stores the screen in the keyboard, but the app does
not know about it, so it may still replace it.

## My lighting is not there after a restart

Lighting effects are drawn by the Mac, and the app remembers only the last **profile**
you applied or saved. Lighting, the screen and the lights-off state are not remembered
on their own. Set things up the way you like, then **Save current setup** in
**Profiles**, and make sure **Restore the last profile on launch** is on in Settings.

## Open at login does not work

The Settings pane says what is missing. Launch at login needs Apex Control to be a
signed app in `/Applications`: move it there and reopen it. If macOS says it is
waiting for approval, use **Open Login Items** and allow it under **System Settings,
then General, then Login Items** (newer versions of macOS call that page **Login Items
& Extensions**; the button opens the right one). A build you made yourself is signed
only ad hoc unless you followed
[Keeping permissions across rebuilds](DEVELOPMENT.md#keeping-permissions-across-rebuilds).

## The window closes and the app keeps running

That is the default: effects are drawn by the app, so closing the window would
otherwise turn them off. The keyboard icon in the menu bar is always there to reopen
the window or quit. To make closing the window quit the app, turn off **Keep running
when the window is closed** in Settings. To hide the Dock icon as well, turn off
**Show in the Dock**; **Open Apex Control** in the menu-bar icon shows the Dock icon
again, and the setting is applied once more the next time a preference changes.

## The build fails

- You need macOS 14 or later and **Xcode 16 or later** (Swift 6.0). Check with
  `swift --version`. Xcode 16 itself needs macOS 14.5 or later.
- If `xcode-select -p` points at the command-line tools only, or at an older Xcode,
  switch to a current one with `sudo xcode-select -s /Applications/Xcode.app`.
- Start clean: `rm -rf .build`, then `swift build`.
- Still stuck? Open a [bug report](https://github.com/Rikearon/apex-control/issues/new?template=bug_report.yml)
  with the full error and the output of `swift --version`.

## Starting fresh, and uninstalling

Apex Control keeps very little on your Mac ([Privacy and security](PRIVACY.md#what-is-stored-on-your-mac)).

**Reset the app's saved state** (it will start with its defaults):

```bash
defaults delete io.github.rikearon.apex-control
rm -r ~/Library/Application\ Support/ApexControl
```

Quit the app first. This does not change anything stored in the keyboard, but it does
delete your saved profiles, so use **Export…** in the Profiles pane on any you want to
keep.

**Uninstall completely:** quit the app; delete `Apex Control.app`; run the two
commands above; remove Apex Control from **Login Items** and from the **Input
Monitoring** and **Accessibility** lists in System Settings; and, if you created it,
remove the "Apex Control Local Signing" certificate and its key from your login
keychain and from the System keychain, where the trust setting for it was added
([how](DEVELOPMENT.md#keeping-permissions-across-rebuilds)).

**The keyboard keeps its settings.** Bindings, actuation and any saved screen live in
the keyboard, not in the app. To put the keys back, use **Reset all keys** before you
uninstall (the app saves the reset into the keyboard), or quit the app and run
`apexctl reset-bindings` followed by `apexctl profile save`.
