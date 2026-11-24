#!/usr/bin/env bash
# common.sh - shared helpers for release-skill.
# Bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.

RS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS_ROOT="$(cd "$RS_LIB_DIR/../.." && pwd)"
RS_VERSION="$(cat "$RS_ROOT/VERSION" 2>/dev/null || printf '0.0.0')"

log()  { printf '%s\n' "$*"; }
info() { printf '→ %s\n' "$*" >&2; }
ok()   { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
err()  { printf '❌ %s\n' "$*" >&2; }

die() {
    local code="$1"
    shift
    err "$*"
    exit "$code"
}

have() { command -v "$1" >/dev/null 2>&1; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
today()   { date +"%Y-%m-%d"; }

sha256_file() {
    if have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif have sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    else
        printf ''
    fi
}

trim() {
    printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# is_ignored <path> <newline-separated patterns>
is_ignored() {
    local path="$1" patterns="$2" pat base
    [ -n "$patterns" ] || return 1
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        base="${pat%/}"
        case "$path" in
            "$pat"|"$base") return 0 ;;
        esac
        case "$pat" in
            *\**|*\?*|*\[*)
                case "$path" in $pat) return 0 ;; esac
                ;;
            *)
                case "$path" in "$base"/*) return 0 ;; esac
                ;;
        esac
    done <<EOF
$patterns
EOF
    return 1
}

# filter_status <porcelain text> <ignores> -> non-ignored porcelain lines
filter_status() {
    local text="$1" ignores="$2" line status path
    [ -n "$text" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        status="${line:0:2}"
        path="${line:3}"
        path="${path%\"}"; path="${path#\"}"
        case "$path" in
            *" -> "*) path="${path##* -> }" ;;
        esac
        if is_ignored "$path" "$ignores"; then
            continue
        fi
        printf '%s\n' "$line"
    done <<EOF
$text
EOF
}

# paths from porcelain text, one per line
status_paths() {
    local text="$1" line path
    [ -n "$text" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        path="${line:3}"
        path="${path%\"}"; path="${path#\"}"
        case "$path" in
            *" -> "*) path="${path##* -> }" ;;
        esac
        printf '%s\n' "$path"
    done <<EOF
$text
EOF
}

git_dir_clean() {
    git diff --quiet && git diff --cached --quiet
}

current_branch() {
    git symbolic-ref --short HEAD 2>/dev/null || printf 'HEAD'
}

json_field() { # json_field <json> <key> [default]
    python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    print(sys.argv[3]); sys.exit(0)
value = data.get(sys.argv[2], sys.argv[3])
if value is True:
    print("true")
elif value is False:
    print("false")
elif value is None:
    print(sys.argv[3])
elif isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

# Human-readable duration between two epoch seconds.
duration_human() {
    local seconds="${1:-0}" minutes hours
    minutes=$((seconds / 60))
    hours=$((minutes / 60))
    if [ "$hours" -gt 0 ]; then
        printf '%dh%02dm' "$hours" "$((minutes % 60))"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm%02ds' "$minutes" "$((seconds % 60))"
    else
        printf '%ds' "$seconds"
    fi
}
