# Getting help

Apex Control is maintained by volunteers, so there is no guaranteed response
time, but questions and bug reports are welcome and are read.

## Start here

1. **[Troubleshooting](docs/TROUBLESHOOTING.md)** covers the common problems:
   the keyboard not being found, Reactive lighting only reacting to modifier
   keys, settings that come back after unplugging, and Gatekeeper warnings.
2. **[Using the app](docs/USING-THE-APP.md)** and
   **[using the CLI](docs/USING-THE-CLI.md)** explain what everything does.
3. **[Compatibility](docs/COMPATIBILITY.md)** says which keyboards and firmware
   are supported and what has been verified.

## Ask a question

Use [Discussions](https://github.com/Rikearon/apex-control/discussions)
for questions, ideas and show-and-tell. Search first; someone may have asked
already.

## Report a bug or request a feature

Use the [issue forms](https://github.com/Rikearon/apex-control/issues/new/choose).
A good bug report includes the output of `apexctl --version` and `apexctl info`,
which is why the form asks for them. If you only use the app, give its version
(Finder, Get Info) and the firmware shown at the bottom of its sidebar instead.

## Security problems

Do not open a public issue. Follow the [security policy](SECURITY.md).

## What this project cannot help with

- **SteelSeries GG** itself, the keyboard's firmware, or warranty and hardware
  problems: contact SteelSeries support. Apex Control is an independent project;
  SteelSeries is not affiliated with it and provides no support for it.
- **Other keyboard models.** Only the wired Apex Pro TKL Gen 3 (`1038:1642`) is
  supported. A *device support* report is welcome, but it starts a
  conversation, not a fix.

## A request

Please do not post your keyboard's serial number, its GUID, a raw profile dump
(`apexctl profile read --out`; profile dumps contain the GUID) or an unedited
`ioreg` dump (it lists serial numbers) in a public issue.
