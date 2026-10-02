#!/bin/bash
# Create a self-signed code-signing certificate so Apex Control keeps its macOS
# permissions across rebuilds. Run once; build-app.sh picks it up automatically.
#
# Why this exists: macOS ties a TCC grant (Input Monitoring, Accessibility) to
# the app's code signature. An ad-hoc signature is identified by the hash of the
# binary, so every rebuild looks like a brand-new app and silently loses the
# permission — while still showing as granted in System Settings. A certificate
# is stable, so the grant survives.
#
# What this changes on your Mac — read it before you run it:
#   1. Creates a self-signed certificate and 2048-bit RSA key named
#      "Apex Control Local Signing" (valid ten years) in a temporary directory.
#   2. Imports both into your login keychain.
#   3. Marks the certificate as trusted *for code signing only* in the System
#      keychain's admin trust store. That needs sudo and applies to every user of
#      this Mac; it is what lets codesign build a trust chain to the certificate.
#   4. Tries to let codesign use that one key without asking every time.
# Anyone who gets hold of the private key could sign code this Mac accepts as
# validly signed, so do not export it. It is not a Developer ID and does not let
# the app be distributed.
#
# To undo it: remove the admin trust setting, delete the certificate from the System
# keychain, and delete the certificate and its key from the login keychain.
# docs/DEVELOPMENT.md (Keeping permissions across rebuilds) has the commands.
#
#   ./Scripts/make-signing-identity.sh          asks before it changes anything
#   ./Scripts/make-signing-identity.sh --yes    does not ask
#
# The typographic quotes in the messages below are deliberate.
# shellcheck disable=SC1111
set -euo pipefail

NAME="Apex Control Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

ASSUME_YES=0
case "${1:-}" in
    "") ;;
    -y | --yes) ASSUME_YES=1 ;;
    *) echo "usage: $0 [--yes]" >&2; exit 2 ;;
esac

# Captured, then searched, rather than piped into `grep -q`: an early-exiting
# reader can SIGPIPE the writer, which `pipefail` reports as a failure.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -q "$NAME" <<<"$IDENTITIES"; then
    echo "✓ “${NAME}” already exists — nothing to do."
    echo "  Rebuild with ./Scripts/build-app.sh release and it will be used."
    exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
    if [ ! -t 0 ]; then
        echo "error: this changes your keychain and trust settings, so it needs a terminal." >&2
        echo "       Run it interactively, or pass --yes if you have read the header." >&2
        exit 1
    fi
    printf '%s' "Create “${NAME}”, import it into your login keychain, and trust it for code signing on this Mac (uses sudo)? [y/N] "
    read -r reply || reply=""
    case "$reply" in
        [yY] | [yY][eE][sS]) ;;
        *) echo "Nothing changed."; exit 1 ;;
    esac
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "▸ Generating a self-signed code-signing certificate…"
cat > "$WORK/openssl.cnf" <<CONF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext
[ dn ]
CN = $NAME
[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CONF

# openssl is chatty on success and silent about *why* on failure once its output is
# discarded, and `set -e` would then stop the script with no explanation.
quietly() {
    local output
    if ! output="$("$@" 2>&1)"; then
        echo "error: $1 failed:" >&2
        echo "$output" >&2
        exit 1
    fi
}

quietly openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf"

# The p12 password is throwaway — the file lives seconds inside a mktemp dir —
# but it must not be *empty*: `security import` fails MAC verification on
# empty-password p12s from modern LibreSSL/OpenSSL ("MAC verification failed").
# The SHA1/3DES algorithms are forced for the same reason: they are the ones
# `security import` understands on every macOS version.
P12PASS="$(openssl rand -hex 16)"
quietly openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$P12PASS"

echo "▸ Importing into your login keychain…"
echo "  (macOS may ask for your login password, and again to trust the certificate.)"
# Only codesign gets passwordless access to the key. The certificate is trusted for code
# signing on this whole Mac, so the key must not be exportable by any other program
# running as you without a prompt (which is what allowing /usr/bin/security would do).
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PASS" \
    -T /usr/bin/codesign >/dev/null

# codesign refuses a certificate it cannot build a trust chain to, so the
# self-signed root has to be trusted for code signing. This is the step that
# needs an administrator. `trustRoot`, not `trustAsRoot`: macOS only accepts
# trustRoot for self-signed certificates — trustAsRoot is for certs signed by
# someone else, and using it here fails with "One or more parameters passed
# to a function were not valid".
echo "▸ Trusting it for code signing…"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
    -k /Library/Keychains/System.keychain "$WORK/cert.pem"

# Let codesign use the key without prompting on every build. Scoped to this one
# key by label: without -l the change would apply to every signing key in the
# login keychain. It needs the keychain password to take effect, which this
# script deliberately does not ask for, so it usually does nothing — in which
# case macOS asks once on the first build, and "Always Allow" settles it.
security set-key-partition-list -S apple-tool:,apple: -s -l "$NAME" -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -q "$NAME" <<<"$IDENTITIES"; then
    echo "✓ Done. ./Scripts/build-app.sh will now sign with “${NAME}”."
    echo
    echo "  One-off step: the app's identity has changed, so remove Apex Control from"
    echo "  System Settings → Privacy & Security → Input Monitoring (and Accessibility)"
    echo "  with “−”, then add the freshly built app. From then on rebuilds keep it."
    echo "  If macOS asks whether codesign may use the key, choose Always Allow."
else
    echo "✗ The identity was not created. Falling back to ad-hoc signing is fine —"
    echo "  you will just have to re-grant the permission after each rebuild."
    exit 1
fi
