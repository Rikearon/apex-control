# Security Policy

Apex Control asks for sensitive permissions (Input Monitoring for the Reactive
lighting effect) and writes to a device's memory, so security reports are taken
seriously. This is a volunteer-run project: everything below is best effort, but
a real report will get a real answer.

## Supported versions

Only the latest release receives security fixes. While the project is at 0.x,
that means the newest `0.x` release and `master`.

## Reporting a vulnerability

**Please report it privately. Do not put the details in a public issue.**

Use GitHub's private reporting form:
<https://github.com/Rikearon/apex-control/security/advisories/new>
(on the repository's **Security** tab, choose **Report a vulnerability**). You need a
GitHub account. Only the maintainers and you can see what you submit.

If the form is ever unavailable, choose **Contact a maintainer privately** on the
[new issue page](https://github.com/Rikearon/apex-control/issues/new/choose), put no
details in it, and a maintainer will invite you to a private draft security advisory.

Helpful to include:

- what the problem is and where it is (a file, a command, a workflow);
- the version (`apexctl --version`, or the app's version in Finder's *Get Info*),
  your macOS version and Mac architecture;
- how to reproduce it, and what an attacker gains by doing so.

The aim is to acknowledge a report within about a week, assess it after that, and
release a fix or mitigation as soon as it can be done responsibly. Reporters who
want credit are named in the advisory and the changelog; say so if you would rather
stay anonymous. Please allow time for a fix before disclosing publicly.

## What is in scope

- The app, `apexctl` and the ApexKit library: for example a way to make them leak
  key presses, write to the keyboard something the user did not ask for, or
  execute code from a crafted profile file or command-line argument.
- The build, signing and release scripts and workflows: for example a way to
  tamper with a release artefact, leak a secret, or run untrusted code in CI.
- The permission handling: anything that makes the app read input it should not.

## What is out of scope

- Vulnerabilities in the keyboard's firmware: report those to SteelSeries.
- Vulnerabilities in macOS, or in software the app does not ship.
- Attacks that need physical access to an unlocked Mac or to the keyboard.
- That the keyboard's control interface appears to have no authentication. macOS lets
  ordinary programs open it (which is why Apex Control needs no privileges), and as far
  as we found the keyboard obeys whatever it is sent, so a program running as you can
  reconfigure it with or without Apex Control. That is a property of the device and
  cannot be fixed here. What is in scope is Apex Control making it worse, for example by
  exposing the keyboard to other users or over a network.
- Damage caused by commands a user chose to send with `apexctl raw`, which sends
  exactly the bytes you give it.
- The fact that a locally created self-signed signing certificate is trusted on
  your own Mac. That is what `Scripts/make-signing-identity.sh` is for; read the
  [explanation](docs/DEVELOPMENT.md#keeping-permissions-across-rebuilds) first.

## The security model in brief

The [privacy and security page](docs/PRIVACY.md) has the detail and shows how to
check each claim yourself. In short:

- **No network access.** The app's own code contains no networking, telemetry,
  update check or account. `make check` fails if a networking API appears under
  `Sources/`, and the privacy page shows how to check the built app.
- **Input Monitoring is used only for Reactive lighting.** The key listener is
  listen-only and takes one thing from each press: the key's USB HID usage code, a
  single byte, to light that key. To tell whether macOS is withholding key presses
  it also compares the process a press was addressed to with its own and asks macOS
  when a key was last pressed anywhere. Nothing is written to disk, logged or sent.
- **No privileges.** No kernel extension, no root, no helper tool, no separate
  background service. The keyboard's control interface is a vendor HID interface
  that macOS lets ordinary apps open.
- **Writes are deliberate.** Anything the app writes to the keyboard's onboard profile
  in flash goes through a read-modify-write that is verified by reading it back. Two
  writes are not read back: the save that runs as the app quits, so that quitting is
  not held up (it waits at most eight seconds, and the next launch reads the flash
  again), and the OLED image stored with **Save to keyboard**, which is a single
  command.
- **Profiles are data that reconfigure your keyboard.** Import only profile files
  you trust: a profile can remap keys on any layer, including the Fn layer's factory
  shortcuts, and applying one is saved into the keyboard's flash a few seconds later.
  Importing never applies a profile by itself.
- **Releases are built by CI from a tag.** Each release carries `SHA256SUMS`, which
  only catches a damaged download, and a build provenance attestation, which ties the
  file to this repository's release workflow. Check it with
  `gh attestation verify <file> --repo Rikearon/apex-control
  --signer-workflow Rikearon/apex-control/.github/workflows/release.yml`
  (GitHub CLI 2.97 or later, signed in: older versions can be fooled by look-alike
  names), or, without a GitHub login, with the `.sigstore.json` bundle attached to the
  release and `--bundle`.
