#!/usr/bin/env bash
# build-dist.sh - build the installable zip for this skill repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < release/VERSION)"
mkdir -p dist
rm -f dist/release-skill-*.zip dist/release-skill-*.zip.sha256

ZIP="dist/release-skill-v$VERSION.zip"
zip -qr "$ZIP" release

if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
else
    sha256sum "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
fi

printf '%s\n' "$ZIP" "$ZIP.sha256"
