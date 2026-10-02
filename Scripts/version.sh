#!/bin/bash
# Print the project version.
#
# The single source of truth is `ApexVersion.current` in
# Sources/ApexKit/Version.swift; this script only reads it. It is used by
# build-app.sh (Info.plist), package-release.sh, the release workflow (which
# refuses a tag that disagrees) and `make version`.
set -euo pipefail

cd "$(dirname "$0")/.."

version="$(sed -n 's/^[[:space:]]*public static let current = "\(.*\)"[[:space:]]*$/\1/p' \
    Sources/ApexKit/Version.swift)"

# Exactly one declaration, shaped MAJOR.MINOR.PATCH[-prerelease]. (`=~` with the
# pattern in a variable keeps this working on the bash 3.2 that macOS ships; a
# multi-line or empty result cannot match the anchored pattern.)
id='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'   # a pre-release identifier; numbers have no leading zeros
pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-'"$id"'(\.'"$id"')*)?$'
if ! [[ "$version" =~ $pattern ]]; then
    echo "error: no valid version in Sources/ApexKit/Version.swift (got: '${version}')" >&2
    exit 1
fi

printf '%s\n' "$version"
