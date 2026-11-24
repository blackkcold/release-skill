#!/usr/bin/env bash
# install.sh - install the release skill into an agent's skills directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="opencode"
DEST=""
DRY_RUN=0
FORCE=0

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --host opencode|claude|codex|gemini|path   target host (default: opencode)
  --dir <path>                              explicit skills/release directory
  --dry-run                                 print actions, copy nothing
  --force                                   continue even if the destination exists
  -h, --help                                show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host) HOST="${2:-opencode}"; shift 2 ;;
        --host=*) HOST="${1#*=}"; shift ;;
        --dir) DEST="${2:-}"; shift 2 ;;
        --dir=*) DEST="${1#*=}"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ -z "$DEST" ]; then
    case "$HOST" in
        opencode) DEST="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/skills/release" ;;
        claude)   DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/release" ;;
        codex)    DEST="${CODEX_HOME:-$HOME/.codex}/skills/release" ;;
        gemini)   DEST="${GEMINI_HOME:-$HOME/.gemini}/skills/release" ;;
        path)     echo "--host path requires --dir" >&2; exit 2 ;;
        *) echo "Unknown host: $HOST" >&2; exit 2 ;;
    esac
fi

echo "install: $ROOT/release"
echo "     -> $DEST"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: no files copied"
    exit 0
fi

if [ ! -d "$ROOT/release" ]; then
    echo "missing $ROOT/release" >&2
    exit 1
fi

if [ -d "$DEST" ]; then
    BACKUP="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/backups/release/$(date +%Y%m%d-%H%M%S)"
    echo "backup: $DEST -> $BACKUP"
    mkdir -p "$BACKUP"
    cp -R "$DEST/." "$BACKUP/"
    for f in "$DEST"/*.bak-*; do
        [ -e "$f" ] || continue
        mv "$f" "$BACKUP/"
    done
    if [ "$FORCE" -ne 1 ]; then
        echo "note: existing install backed up; use --force to skip this notice in scripts"
    fi
fi

mkdir -p "$DEST"
cp -R "$ROOT/release/." "$DEST/"
chmod +x "$DEST/scripts/"*.sh 2>/dev/null || true

echo "installed $(bash "$DEST/scripts/release.sh" version)"
echo "next: bash \"$DEST/scripts/release.sh\" doctor"
