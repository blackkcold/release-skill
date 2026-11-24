#!/usr/bin/env bash
# Verify that an update feed really carries a delta for this release.
#
# A feed generator degrades silently: no previous artifact means no delta, but
# the feed still looks valid and the release still publishes. This check makes
# that outcome visible and, with --require, fatal.
#
# Usage:
#   check-update-delta.sh --version v1.4.0 [options]
#
# Options:
#   --version <tag>    Released version to look for (v prefix optional). Required.
#   --feed <file>      Generated feed (appcast.xml, latest*.yml, …).
#   --archive <dir>    Directory holding staged delta assets.
#                      Default: the feed's own directory.
#   --require          Exit 1 when no delta was produced.
#   --json             Machine-readable output.
#
# Detection: Sparkle `deltaFrom` in the feed or `*.delta` in the archive;
# Electron `*.blockmap` in the archive; anything else is reported as none.
#
# Exit: 0 ok · 1 --require with no delta · 2 usage error
set -euo pipefail

VERSION=""
FEED=""
ARCHIVE=""
REQUIRE=0
JSON=0

usage() {
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --feed)    FEED="${2:-}"; shift 2 ;;
        --archive) ARCHIVE="${2:-}"; shift 2 ;;
        --require) REQUIRE=1; shift ;;
        --json)    JSON=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "--version is required" >&2
    exit 2
fi

BARE="$(printf '%s' "$VERSION" | sed -E 's/^[^0-9]*//')"

# Sparkle and electron-builder both stage delta assets next to the feed, so the
# feed's own directory is the safe default.
if [ -z "$ARCHIVE" ] && [ -n "$FEED" ]; then
    ARCHIVE="$(dirname "$FEED")"
fi

count_files() {
    local dir="$1" pattern="$2"
    [ -d "$dir" ] || { printf '0'; return; }
    find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

DELTA_COUNT=0
BLOCKMAP_COUNT=0
if [ -n "$ARCHIVE" ]; then
    DELTA_COUNT="$(count_files "$ARCHIVE" '*.delta')"
    BLOCKMAP_COUNT="$(count_files "$ARCHIVE" '*.blockmap')"
fi

FEED_DELTA_FROM=0
FEED_HAS_VERSION=false
if [ -n "$FEED" ] && [ -f "$FEED" ]; then
    FEED_DELTA_FROM="$(grep -c 'deltaFrom' "$FEED" 2>/dev/null || true)"
    if grep -q -- "$BARE" "$FEED" 2>/dev/null; then FEED_HAS_VERSION=true; fi
elif [ -n "$FEED" ]; then
    echo "⚠️  Feed not found: $FEED" >&2
fi

DELTA_KIND="none"
if [ "$FEED_DELTA_FROM" -gt 0 ] || [ "$DELTA_COUNT" -gt 0 ]; then
    DELTA_KIND="sparkle"
elif [ "$BLOCKMAP_COUNT" -gt 0 ]; then
    DELTA_KIND="electron"
fi

if [ "$DELTA_KIND" = "none" ]; then DELTA_READY=false; else DELTA_READY=true; fi

if [ "$JSON" -eq 1 ]; then
    printf '{"version":"%s","kind":"%s","delta_count":%s,"feed_delta_from":%s,"blockmap_count":%s,"feed_has_version":%s,"delta_ready":%s}\n' \
        "$BARE" "$DELTA_KIND" "$DELTA_COUNT" "$FEED_DELTA_FROM" "$BLOCKMAP_COUNT" "$FEED_HAS_VERSION" "$DELTA_READY"
else
    echo "VERSION=$BARE"
    echo "DELTA_KIND=$DELTA_KIND"
    echo "DELTA_COUNT=$DELTA_COUNT"
    echo "FEED_DELTA_FROM=$FEED_DELTA_FROM"
    echo "BLOCKMAP_COUNT=$BLOCKMAP_COUNT"
    echo "FEED_HAS_VERSION=$FEED_HAS_VERSION"
    echo "DELTA_READY=$DELTA_READY"
fi

if [ "$DELTA_READY" = "false" ] && [ "$REQUIRE" -eq 1 ]; then
    echo "❌ No delta for $BARE. Seed the previous artifact (scripts/seed-update-artifacts.sh) and regenerate the feed." >&2
    exit 1
fi

exit 0
