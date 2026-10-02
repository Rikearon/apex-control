# Documentation

Start with the page for what you are trying to do.

## Using Apex Control

| I want to… | Read |
|---|---|
| Learn what the app can do, pane by pane | [Using the app](USING-THE-APP.md) |
| Script the keyboard, or check what it really holds | [Using the command line](USING-THE-CLI.md) |
| Fix something that is not working | [Troubleshooting](TROUBLESHOOTING.md) |
| Know whether my keyboard and Mac are supported | [Compatibility](COMPATIBILITY.md) |
| Know what the app does with my key presses and data | [Privacy and security](PRIVACY.md) |
| See the rough edges we already know about | [Known issues](KNOWN-ISSUES.md) |

## How the keyboard works

| I want to… | Read |
|---|---|
| Look up a command, byte by byte | [Protocol reference](PROTOCOL.md) |
| See what the keyboard can do that the app cannot yet | [Feature gap analysis](FEATURE-GAP-ANALYSIS.md) |
| Read how a planned feature was reasoned about | [Product requirement documents](FEATURE-GAP-ANALYSIS.md#f-prd-index) (the index; the files are in `prd/`) |

The protocol reference is licensed separately from the code, under
[CC BY 4.0](../LICENSES/CC-BY-4.0.txt), so that the knowledge in it can be reused.

## Contributing

| I want to… | Read |
|---|---|
| Know how to contribute, and what is expected | [Contributing](../CONTRIBUTING.md) |
| Build, run and test, and verify against a keyboard | [Development](DEVELOPMENT.md) |
| Understand how the code is organised, and its safety rules | [Architecture](ARCHITECTURE.md) |
| Propose a larger feature | [The PRD template](prd/_TEMPLATE.md) |

## Maintaining the project

| I want to… | Read |
|---|---|
| Set up the repository, or cut a release | [Maintaining](MAINTAINING.md) |
| Know who decides what | [Governance](../GOVERNANCE.md) |

## Project policies

[Licence](../LICENSE) · [Third-party notices](../THIRD-PARTY-NOTICES.md) ·
[Code of conduct](../CODE_OF_CONDUCT.md) ·
[Security policy](../SECURITY.md) · [Getting help](../SUPPORT.md) ·
[Changelog](../CHANGELOG.md)

## Glossary

The terms these docs use, in plain words.

**Keyboard and protocol**

- **Actuation point**: how far a key must travel, in millimetres, before it
  registers. This keyboard measures travel with a Hall sensor, so the point can be
  set per key. **Rapid Trigger** releases a key as soon as you lift a little and
  presses it again as you push down, instead of using fixed points.
- **Analog key**: a key whose actuation point can be adjusted. The firmware lists 68
  of them; the other keys are not adjustable.
- **Bindings** (remapping): what a key does. There are three layers: **normal**, the
  **Fn layer** (what a key does while the Fn key is held; the keyboard ships with its
  own shortcuts on it) and the **second actuation** layer (what a key does past a
  second, deeper press).
- **Direct mode**: the app streams colours to the keys itself instead of the keyboard
  running its own lighting. The colours stay until the keyboard loses power or
  lighting is handed back.
- **Firmware**: the program that runs inside the keyboard.
- **Flash and RAM**: RAM, in these docs "live memory", is where a change takes effect
  at once; it survives quitting the app but is lost when the keyboard loses power.
  Flash is the keyboard's permanent memory; the keyboard loads its boot profile from
  it at power-up.
- **HID** (Human Interface Device): the USB standard for keyboards, mice and similar
  devices. Besides its keyboard interfaces, this keyboard has a vendor-defined HID
  interface that carries its settings.
- **HID usage code**: the number the HID standard gives a key or a function (`0x04`
  is A). The docs and the code address every key by it.
- **Onboard profile** (slot): a complete configuration stored in the keyboard's flash.
  The keyboard has five slots, numbered 0 to 4 in the protocol docs and in
  `apexctl`, and 1 to 5 in the app's window.
- **OLED**: the keyboard's small 128 x 40 display.
- **Rapid Tap / SOCD**: SOCD stands for simultaneous opposing cardinal directions,
  such as A and D held together. This feature sets what the keyboard reports for up
  to 10 such pairs.
- **Reactive lighting**: an effect that lights keys as you press them.
- **Report** (feature, output, input): the messages exchanged with the keyboard over
  HID. Feature reports carry bulk data, output reports carry short commands, and
  input reports carry the keyboard's replies.
- **Vendor interface**: a HID interface whose meaning the manufacturer defines. macOS
  does not claim it for the system, so an ordinary app can use it without special
  permissions.

**macOS**

- **Ad-hoc signed**: signed without a developer certificate. macOS runs it after you
  approve it, but to its privacy system every rebuild looks like a different app.
- **Gatekeeper, quarantine and notarization**: the checks macOS makes on downloaded
  apps. A *notarized* app has been scanned by Apple and opens without a warning. Apex
  Control's releases are not notarized, so macOS asks you to approve the first launch.
- **Input Monitoring and Accessibility**: two macOS privacy permissions, either of
  which lets an app see which keys you press elsewhere on the Mac. Only Reactive
  lighting uses them.
- **TCC** (Transparency, Consent and Control): macOS's privacy permission database.
  Grants are tied to the app's code signature.

**Project**

- **PRD**: a product requirements document, the write-up of one planned feature, in
  [`prd/`](prd/).
- **Software profile**: a named set of Apex Control settings saved on your Mac, as
  opposed to the keyboard's onboard slots.
- **Verified**: in these docs, checked on the author's keyboard. See
  [Compatibility](COMPATIBILITY.md) for what that covers.
