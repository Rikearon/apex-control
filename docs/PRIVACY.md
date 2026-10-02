# Privacy and security

Apex Control can ask macOS for permission to see your key presses, so it owes you
a straight account of what it does with them. This page says what the app does,
and shows you how to check each claim yourself instead of taking it on trust.

To report a vulnerability, see the [security policy](../SECURITY.md).

## The short version

- **The app makes no network connections.** It has no networking code of its own,
  no telemetry, no update check and no account, so nothing leaves your Mac through
  it. You can [check that yourself](#check-it-yourself).
- **Key presses are used only for the Reactive lighting effect**, and only when you
  choose it. From each press the app takes the key's USB HID usage code (a single
  byte) and lights that key. It keeps no history of what you type: nothing is
  written to disk, logged or sent. (The listener looks at two more things, only to
  tell whether macOS is really delivering key presses;
  [see below](#key-presses-reactive-lighting-only).)
- **No privileges.** No kernel extension, no root, no helper tool and no separate
  background service. The keyboard's control interface is a vendor HID interface
  that macOS lets ordinary apps open. The app itself can keep running in the menu
  bar after you close its window, and **Open at login** starts that same app.
- **It leaves few traces.** A preferences file, one profile library file, and
  whatever macOS itself keeps for any app. The app writes no logs and keeps no
  caches. [Details below](#what-is-stored-on-your-mac).

## What the app handles

### Your keyboard's settings

Lighting, actuation, rapid trigger, rapid tap, key bindings and the OLED screen
are sent to the keyboard over USB, and the app reads back the key bindings and the
keyboard's saved profile. That is the app's purpose, and it happens over the
keyboard's vendor HID interface. See [PROTOCOL.md](PROTOCOL.md).

### Key presses (Reactive lighting only)

Reactive lighting needs to know which key you pressed, from anywhere on the Mac.
macOS splits that across two permissions, and either one is enough: **Input
Monitoring** or **Accessibility**, both in System Settings, then Privacy &
Security. Nothing else in the app needs either.

- The listener is a *listen-only* event tap on key-down and modifier changes. It
  cannot alter, block or inject a key press.
- For each press it converts the key code to a USB HID usage code, a single
  byte, and hands that to the lighting engine. The engine holds, in memory only,
  which keys were pressed while the Fade setting lasts (up to two seconds, so the
  light can fade) and the most recent one: the Lighting pane shows its name for a few seconds while
  Reactive is running. That is the only place a key appears.
- The listener also does two things that do not involve which key it was, only to
  notice when macOS is withholding other apps' key presses (the cause of "I
  granted it and nothing happens"; see [Troubleshooting](TROUBLESHOOTING.md)). It
  compares the process each key-down was addressed to with the app's own, and it
  asks macOS how long ago a key was last pressed anywhere. Only a yes/no verdict
  and a few timestamps are held in memory for that; the process and the key are
  not kept.
- Nothing is written to disk, logged, or sent anywhere.
- While a password field is focused (or another app has turned on macOS's secure
  input), macOS hides key presses from every app, so Reactive goes quiet. The
  Lighting pane says so.
- You can revoke the permission at any time in System Settings. Choosing any other
  effect stops the listener.
- A developer harness built into the app, switched on by setting
  `APEX_INPUT_DIAGNOSTIC=1` when it is started from a terminal, prints the name of
  each key it hears to that terminal for a few seconds and exits. It does nothing
  unless that variable is set. The [development guide](DEVELOPMENT.md#the-development-harnesses)
  describes it and the other two harnesses.

### What is stored on your Mac

| What | Where |
|---|---|
| Five settings, each written when you change it: keep running when the window is closed, show in the Dock, restore the last profile on launch, re-light after wake, pause effects while asleep. There is also a sixth flag (`hasShownBackgroundHint`) that no screen sets yet. | `~/Library/Preferences/io.github.rikearon.apex-control.plist` |
| Window and dialog state that macOS's own interface framework (AppKit) adds to that same file: window and split-view sizes, the colour panel's position, and the size of file dialogs and what you type in their search box | The same file |
| Your profile library | `~/Library/Application Support/ApexControl/profiles.json` |
| Profiles you export, and the OLED image you pick | Where you save them, and the path you chose |
| The **Open at login** registration | Kept by macOS (System Settings, General, Login Items); the app has no file for it |

The profile library holds your saved setups: lighting, actuation, bindings, screen
text. A profile that uses an OLED image stores the *path* to the image, not the
image, and it is the full path, which includes your account name (for example
`/Users/you/Pictures/logo.png`); look at a profile file before you share it (it is
plain JSON). If the library cannot be read it is renamed
`profiles-corrupt-<timestamp>.json` and a fresh one is started; nothing is
deleted.

The app itself writes no logs and keeps no caches, and shows errors as banners.
macOS may keep its own records about any app, such as a crash report if it
crashes.

**Removing everything.** Quit the app, delete `Apex Control.app`, delete the
preferences file and the `ApexControl` folder listed above, and remove Apex Control
from **Login Items** and from the **Input Monitoring** and **Accessibility** lists
in System Settings.
[Troubleshooting](TROUBLESHOOTING.md#starting-fresh-and-uninstalling) has the
commands. If you are a developer and ran `Scripts/make-signing-identity.sh`, it also
added a certificate to your login keychain and marked it as trusted for code signing
for every user of the Mac (an administrator setting); delete "Apex Control Local
Signing" in Keychain Access, from the login keychain and from the System keychain,
to undo that ([details](DEVELOPMENT.md#keeping-permissions-across-rebuilds)).
Removing the app does not change what is stored in the keyboard.

### What is stored in the keyboard

Bindings, the Fn key, actuation, rapid trigger and rapid tap are written into the
keyboard's own flash memory, so they should survive unplugging and work on any computer
([Compatibility](COMPATIBILITY.md) records what has been checked).
The OLED screen is stored there only if you choose **Save to keyboard** in the OLED
pane; whether a saved screen survives unplugging has not been recorded on hardware
yet ([Compatibility](COMPATIBILITY.md)). Removing the app does not remove any of
this. Use **Reset all keys** in the Bindings pane to put the keys back. (From a
terminal, quit the app, run `apexctl reset-bindings`, then `apexctl profile save`:
`reset-bindings` alone changes only the keyboard's live memory.)

## What the app can and cannot do to your keyboard

- **Every time it connects, when the Mac wakes, and whenever you change something**,
  the app sends its lighting and its screen, and the actuation, rapid trigger and
  rapid tap settings it holds, to the keyboard. It sends key bindings only if it
  has some of its own (ones you edited, or a profile you applied); it never
  pushes bindings it does not have, and on a first launch it reads yours from the
  keyboard instead.
- **A first launch** starts from the app's own defaults: a Rainbow Wave, and the
  text "APEX PRO / Gen 3" on the screen (the app re-sends its screen whenever it
  connects; see [known issues](KNOWN-ISSUES.md)). Actuation, rapid trigger and
  rapid tap are treated differently. The app first sends its default values to the
  keyboard's memory, then reads the keyboard's saved profile and, if you have never
  changed the actuation and rapid-trigger settings in the app (or the rapid-tap
  settings), adopts the saved values instead. So a first launch does not overwrite
  settings stored in the keyboard, for example by SteelSeries GG. If that read
  fails, the defaults stay in the keyboard's memory until you unplug it. Once you
  have changed one of those settings in the app, the app's values are the ones it
  sends and saves.
- **Saving into the keyboard.** A few seconds after you change bindings, the Fn
  key, actuation, rapid trigger or rapid tap, the app writes them into the
  keyboard's flash (slot 0, the profile it boots from), but only if they differ from
  what is already there. Every such write is a read-modify-write: the app reads the
  keyboard's own image first, changes only the fields it manages (everything else,
  such as macros and the GUID, is kept byte for byte, and so are the Fn-layer
  shortcuts you have not touched), and verifies the result by reading it back. (The
  OLED image saved with **Save to keyboard** is a separate single command that is not
  read back.) The one exception is the save that runs as the app
  quits: it skips the read-back so that quitting is not held up (it waits at most
  eight seconds), and the next launch reads the flash again.
- **The screen is drawn live** and is volatile unless you choose **Save to
  keyboard**.
- **A backup is cheap.** Since the app writes slot 0 whenever your settings differ
  from it, you may want a copy of what the keyboard holds before you start: quit
  Apex Control, then run `apexctl profile read 0 --out backup.bin`
  ([Using the command line](USING-THE-CLI.md) explains restoring it, and what a
  restore overwrites). The file contains your keyboard's GUID, so keep it to yourself.

A profile file you import is data that can remap keys on any layer, including the Fn
layer's factory shortcuts, and applying one is saved into the keyboard's flash a few
seconds later, so import only profiles you trust. An imported profile is never applied
automatically; you choose to apply it.

## Check it yourself

You do not need to trust any of the above. Each claim can be checked.

**No networking code.** This searches the source for networking APIs and URL
literals, and prints nothing:

```bash
grep -rEn 'URLSession|NWConnection|NWListener|NWPathMonitor|CFNetwork|CFSocket|WKWebView|import WebKit|import Network|getaddrinfo|"https?://' Sources
```

`make check` runs the same search over the Swift files, so a change that adds a
networking call fails the checks; the failure message says to change this policy and
the check in the same pull request if the change is deliberate. It is a tripwire for
the obvious ways to add networking, not a proof, which is why the checks below look
at the built app instead.

**No networking frameworks linked directly.** Against a built app, this prints
nothing:

```bash
otool -L "/Applications/Apex Control.app/Contents/MacOS/Apex Control" | grep -i -E 'network|webkit|cfnetwork'
```

(Every Mac app links Foundation, which has networking code inside it; this shows the
app does not link a networking or web framework itself. The next check shows what
the running app does.)

**No network sockets.** While the app is running, this prints nothing:

```bash
lsof -a -p "$(pgrep -x 'Apex Control')" -i
```

**No entitlements.** The app is not sandboxed and asks for no entitlements. This
prints nothing after the `Executable=` line:

```bash
codesign -d --entitlements - "/Applications/Apex Control.app"
```

**What it stores.** Besides files you export, the app writes only the places listed
above. This lists everything under your Library that carries its name, and shows
the preferences:

```bash
find ~/Library -maxdepth 3 -iname '*apex*control*' 2>/dev/null
defaults read io.github.rikearon.apex-control
```

Expect the preferences file, the `ApexControl` folder and, possibly, a record that
macOS's own crash reporter keeps for any app; there are no logs or caches.
`defaults read` says the domain does not exist until the app has stored a setting.

**One subprocess.** The only process the app ever starts is the one that relaunches
it after you grant Input Monitoring, because macOS only applies that permission to
apps that start afterwards. It runs `/bin/sh -c 'sleep 1; /usr/bin/open "$0"'` with
the app's own path as an argument, and this prints exactly one line, for it:

```bash
grep -rEn '\bProcess\(\)|NSTask|posix_spawn|popen\(|NSAppleScript' Sources
```

**No dependencies.** `Package.swift` lists none. The app links only libraries that
ship with macOS: Apple's system frameworks and the Swift runtime.

## Releases

- Releases are built by GitHub Actions from a version tag, from the source in this
  repository, and each one comes with `SHA256SUMS` and a build provenance
  attestation. Check them with `shasum -a 256 --ignore-missing -c SHA256SUMS` (it
  catches a damaged download) and
  `gh attestation verify <file> --repo Rikearon/apex-control
  --signer-workflow Rikearon/apex-control/.github/workflows/release.yml`
  (it ties the file to this repository's release workflow; it needs GitHub CLI 2.97 or
  later, because older versions can be fooled by look-alike names, and either a signed-in
  `gh` or the release's `.sigstore.json` bundle with `--bundle`). `--bundle` needs no
  GitHub login but still fetches Sigstore's trusted root; to check with no network at all,
  save the root once (`gh attestation trusted-root > trusted_root.jsonl`) and add
  `--custom-trusted-root trusted_root.jsonl`.
- **Release builds are not notarized** (there is no Apple Developer ID yet), so
  macOS asks you to approve the app once. That is a trade-off, not a claim of
  trustworthiness: if you would rather not run a binary someone else built, build
  it from source with `make app`, which needs Xcode and takes a few minutes.
- The local signing certificate that `Scripts/make-signing-identity.sh` creates is
  for developers, and is [explained in the development guide](DEVELOPMENT.md#keeping-permissions-across-rebuilds).

## What this page does not promise

The app is written by people, and it talks to hardware. It has bugs, and the
[known issues](KNOWN-ISSUES.md) list the ones we know about. "No network access"
describes this software; it says nothing about SteelSeries GG, which you may
also have installed, or about macOS itself.
