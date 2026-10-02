#!/bin/bash
# Print the CHANGELOG.md section for one version, as GitHub release notes, ending
# with how to install and verify the release.
#
#   ./Scripts/release-notes.sh 0.1.0
#
# Fails if the changelog has no non-empty section for that version, so a release
# cannot be published without its notes.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -ne 1 ]; then
    echo "usage: ./Scripts/release-notes.sh <version>   (for example 0.1.0)" >&2
    exit 2
fi
version="$1"
repo="${GITHUB_REPOSITORY:-Rikearon/apex-control}"

# `index` compares literally, so the dots in a version cannot act as wildcards.
notes="$(awk -v v="$version" '
    index($0, "## [" v "]") == 1 { found = 1; next }
    found && /^## \[/ { ended = 1; exit }
    found { buf[++n] = $0 }
    END {
        # The last section runs to the end of the file, where Keep a Changelog
        # keeps the link definitions shared by every section. They are not notes.
        if (!ended) while (n > 0 && (buf[n] ~ /^[ \t]*$/ || buf[n] ~ /^\[[^]]+\]:[ \t]/)) n--
        for (i = 1; i <= n; i++) print buf[i]
    }
' CHANGELOG.md)"

# Trim leading and trailing blank lines.
notes="$(printf '%s\n' "$notes" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$notes" ]; then
    echo "error: CHANGELOG.md has no entry for ${version}" >&2
    echo "       Rename the [Unreleased] heading to [${version}] - <date> before tagging." >&2
    exit 1
fi

cat <<NOTES
${notes}

---

### Installing

1. Open \`ApexControl-${version}.dmg\` and drag **Apex Control** to **Applications**.
2. macOS will not open it at first, because this build is not notarized. Try to open it once, then go to
   **System Settings, Privacy & Security**, scroll to the message about Apex Control and choose **Open Anyway**.
   Or clear the quarantine flag from a terminal: \`xattr -dr com.apple.quarantine "/Applications/Apex Control.app"\`.

The command-line tool is \`apexctl-${version}-macos.zip\`. Unzip it and put \`apexctl\` somewhere on your \`PATH\`.

### Before you first run the app

Apex Control saves settings into the keyboard's onboard profile (slot 0) by itself, and there is no setting
to turn that off. Back the profile up first with \`apexctl profile read 0 --out backup.bin\`;
\`apexctl profile restore 0 backup.bin\` writes it back. The README has the details.

### Verifying

\`\`\`bash
shasum -a 256 --ignore-missing -c SHA256SUMS
gh attestation verify ApexControl-${version}.dmg --repo ${repo} \\
  --signer-workflow ${repo}/.github/workflows/release.yml
\`\`\`

\`gh attestation\` needs GitHub CLI 2.97 or later (older versions can be fooled by look-alike names in
\`--signer-workflow\`), signed in (\`gh auth login\`). Without a login,
download \`ApexControl-${version}.sigstore.json\` too and add
\`--bundle ApexControl-${version}.sigstore.json\`.

Apex Control is an independent, unofficial project. It is not affiliated with, endorsed by or
sponsored by SteelSeries.
NOTES
