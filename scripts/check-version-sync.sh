#!/usr/bin/env bash
# check-version-sync.sh - fail when VERSION, SKILL.md, plugin.json and
# CHANGELOG disagree. The release tag is the only other place a version lives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ -f release/VERSION ] || { echo "missing release/VERSION" >&2; exit 1; }
[ -f release/SKILL.md ] || { echo "missing release/SKILL.md" >&2; exit 1; }
[ -f .claude-plugin/plugin.json ] || { echo "missing .claude-plugin/plugin.json" >&2; exit 1; }
[ -f CHANGELOG.md ] || { echo "missing CHANGELOG.md" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < release/VERSION)"
SKILL_VERSION="$(python3 - <<'PY'
import re
text = open("release/SKILL.md", encoding="utf-8").read()
match = re.match(r"^---\n(.*?)\n---", text, re.S)
block = match.group(1) if match else ""
m = re.search(r"^\s+version:\s*\"?([^\"\n]+)\"?\s*$", block, re.M)
print(m.group(1).strip() if m else "")
PY
)"
PLUGIN_VERSION="$(python3 -c 'import json;print(json.load(open(".claude-plugin/plugin.json")).get("version",""))')"
CHANGELOG_VERSION="$(grep -m1 -oE '^## \[v?[0-9]+\.[0-9]+\.[0-9]+[^]]*\]' CHANGELOG.md | sed -E 's/^## \[v?//; s/\]$//' || true)"

fail=0
check() {
    local name="$1" value="$2"
    if [ "$value" != "$VERSION" ]; then
        echo "❌ $name=$value, expected $VERSION" >&2
        fail=1
    fi
}

check "release/VERSION" "$VERSION"
check "SKILL.md metadata.version" "$SKILL_VERSION"
check "plugin.json version" "$PLUGIN_VERSION"
check "CHANGELOG top version" "$CHANGELOG_VERSION"

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "version sync ok: $VERSION"
