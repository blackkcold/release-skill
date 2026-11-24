#!/usr/bin/env bash
# Seed the previous release's artifacts so the updater feed can build a delta.
#
# Differential updates need the previous build locally. Build outputs are
# normally gitignored, so a fresh worktree, a new CI job or another machine
# starts without them and silently falls back to a full-package update.
#
# Order of resolution:
#   1. the target directory already has a matching artifact  → local
#   2. --source-dir (e.g. the main checkout)                 → copy
#   3. GitHub Release assets of the previous tag             → gh release download
#
# Usage:
#   seed-update-artifacts.sh --previous v1.3.2 [options]
#
# Options:
#   --previous <tag>     Previous released tag (e.g. v1.3.2). Required.
#   --target-dir <dir>   Where the artifact must end up.
#                        Default: release/<prev without tag prefix>
#   --source-dir <dir>   Extra local directory to copy from.
#   --repo <owner/repo>  GitHub repo. Default: parsed from origin remote.
#   --patterns <list>    Comma-separated artifact globs.
#                        Default: *.dmg,*.zip,*.exe,*.AppImage,*.tar.gz,*.pkg
#   --json               Machine-readable output.
#   --strict             Exit 2 when no artifact could be staged.
#   --dry-run            Print what would happen; download/copy nothing.
#
# Exit: 0 staged or not needed · 2 --strict and nothing staged · 1 usage error
set -euo pipefail

PREV=""
TARGET_DIR=""
SOURCE_DIR=""
REPO=""
PATTERNS="*.dmg,*.zip,*.exe,*.AppImage,*.tar.gz,*.pkg"
JSON=0
STRICT=0
DRY_RUN=0

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --previous)   PREV="${2:-}"; shift 2 ;;
        --target-dir) TARGET_DIR="${2:-}"; shift 2 ;;
        --source-dir) SOURCE_DIR="${2:-}"; shift 2 ;;
        --repo)       REPO="${2:-}"; shift 2 ;;
        --patterns)   PATTERNS="${2:-}"; shift 2 ;;
        --json)       JSON=1; shift ;;
        --strict)     STRICT=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$PREV" ]; then
    echo "--previous is required" >&2
    exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Not a git repository" >&2
    exit 1
fi

# release/<version> is the convention used by the build/feed scripts here.
PREV_BARE="${PREV#v}"
[ -n "$TARGET_DIR" ] || TARGET_DIR="release/${PREV_BARE}"

if [ -z "$REPO" ]; then
    ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
    REPO="$(printf '%s' "$ORIGIN_URL" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)\.git$#\1#p')"
    [ -n "$REPO" ] || REPO="$(printf '%s' "$ORIGIN_URL" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p')"
fi

# Count artifacts matching the configured globs inside a directory.
count_artifacts() {
    local dir="$1" count=0 pattern file
    [ -d "$dir" ] || { printf '0'; return; }
    local IFS=','
    for pattern in $PATTERNS; do
        for file in "$dir"/$pattern; do
            [ -f "$file" ] && count=$((count + 1))
        done
    done
    printf '%s' "$count"
}

copy_artifacts() {
    local from="$1" to="$2" pattern file copied=0
    [ -d "$from" ] || { printf '0'; return; }
    mkdir -p "$to"
    local IFS=','
    for pattern in $PATTERNS; do
        for file in "$from"/$pattern; do
            [ -f "$file" ] || continue
            cp -p "$file" "$to"/ && copied=$((copied + 1))
        done
    done
    printf '%s' "$copied"
}

file_sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf ''
    fi
}

# An interrupted download leaves a truncated file that still "exists". The feed
# tool would then fail to unpack it, or worse, emit a delta built from garbage.
# Whenever the publisher shipped a `.sha256` next to the artifact, trust only a
# matching checksum and discard the rest.
verify_artifacts() {
    local dir="$1" file expected actual
    [ -d "$dir" ] || return 0
    for file in "$dir"/*; do
        [ -f "$file" ] || continue
        case "$file" in *.sha256) continue ;; esac
        [ -f "${file}.sha256" ] || continue
        expected="$(tr -d '[:space:]' < "${file}.sha256")"
        actual="$(file_sha256 "$file")"
        [ -n "$actual" ] || continue
        if [ "$expected" != "$actual" ]; then
            echo "⚠️  Checksum mismatch, discarding partial artifact: $(basename "$file")" >&2
            rm -f "$file" "${file}.sha256"
        fi
    done
    return 0
}

download_artifacts() {
    local dir="$1" pattern name matched=0
    command -v gh >/dev/null 2>&1 || { printf '0'; return; }
    [ -n "$REPO" ] || { printf '0'; return; }
    [ "$DRY_RUN" -eq 0 ] || { printf '0'; return; }
    mkdir -p "$dir"

    # One listing call, then match locally. Probing a pattern that does not
    # exist costs a failed request each; with several patterns that is slow.
    local list
    list="$(gh release view "$PREV" --repo "$REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)"
    [ -n "$list" ] || { printf '0'; return; }

    local -a patterns assets
    IFS=',' read -r -a patterns <<< "$PATTERNS"
    while IFS= read -r name; do
        [ -n "$name" ] && assets+=("$name")
    done <<< "$list"

    for pattern in "${patterns[@]}"; do
        for name in "${assets[@]}"; do
            # case glob matching keeps the shell's own *.ext semantics
            case "$name" in
                $pattern) ;;
                *) continue ;;
            esac
            if gh release download "$PREV" --repo "$REPO" --dir "$dir" --pattern "$name" --clobber >/dev/null 2>&1; then
                matched=$((matched + 1))
            fi
        done
    done

    # Checksum sidecars are tiny and are what makes verification possible.
    for name in "${assets[@]}"; do
        case "$name" in
            *.sha256) ;;
            *) continue ;;
        esac
        gh release download "$PREV" --repo "$REPO" --dir "$dir" --pattern "$name" --clobber >/dev/null 2>&1 || true
    done
    printf '%s' "$matched"
}

STAGED_FROM="none"
verify_artifacts "$TARGET_DIR"
COUNT="$(count_artifacts "$TARGET_DIR")"

if [ "$COUNT" -gt 0 ]; then
    STAGED_FROM="local"
else
    if [ -n "$SOURCE_DIR" ] && [ -d "$SOURCE_DIR" ]; then
        COPIED="$(copy_artifacts "$SOURCE_DIR" "$TARGET_DIR")"
        if [ "$COPIED" -gt 0 ]; then
            verify_artifacts "$TARGET_DIR"
            COUNT="$(count_artifacts "$TARGET_DIR")"
            [ "$COUNT" -gt 0 ] && STAGED_FROM="source-dir"
        fi
    fi
fi

if [ "$COUNT" -eq 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        STAGED_FROM="would-download"
        [ -z "$REPO" ] || STAGED_FROM="would-download:$REPO"
    else
        download_artifacts "$TARGET_DIR" >/dev/null
        verify_artifacts "$TARGET_DIR"
        COUNT="$(count_artifacts "$TARGET_DIR")"
        [ "$COUNT" -gt 0 ] && STAGED_FROM="github"
    fi
fi

if [ "$COUNT" -gt 0 ]; then DELTA_READY=true; else DELTA_READY=false; fi

if [ "$JSON" -eq 1 ]; then
    printf '{"previous":"%s","repo":"%s","target_dir":"%s","staged_from":"%s","staged_files":%s,"delta_ready":%s}\n' \
        "$PREV" "$REPO" "$TARGET_DIR" "$STAGED_FROM" "$COUNT" "$DELTA_READY"
else
    echo "PREV_TAG=$PREV"
    echo "REPO=$REPO"
    echo "TARGET_DIR=$TARGET_DIR"
    echo "STAGED_FROM=$STAGED_FROM"
    echo "STAGED_FILES=$COUNT"
    echo "DELTA_READY=$DELTA_READY"
fi

if [ "$DELTA_READY" = "false" ]; then
    echo "⚠️  No previous artifact for $PREV. The update will be a full package." >&2
    [ "$STRICT" -eq 1 ] && exit 2
fi

exit 0
