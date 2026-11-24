#!/usr/bin/env bash
# tests/lib.sh - shared helpers for the test suite.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/release"
RELEASE="$SKILL/scripts/release.sh"
FIXTURES="$ROOT/tests/fixtures"

PASS=0
FAIL=0

pass() { printf '  ✅ %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  ❌ %s\n' "$*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected '$2', got '$1')"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass "$3" ;;
        *) fail "$3 (missing '$2')" ;;
    esac
}

assert_file() {
    if [ -f "$1" ]; then pass "$2"; else fail "$2 (missing $1)"; fi
}

assert_no_file() {
    if [ ! -f "$1" ]; then pass "$2"; else fail "$2 (unexpected $1)"; fi
}

new_repo() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-test.XXXXXX")"
    git -C "$dir" init -q
    git -C "$dir" config user.name tester
    git -C "$dir" config user.email tester@example.com
    git -C "$dir" checkout -q -b main 2>/dev/null || true
    printf '%s' "$dir"
}

seed_fixture() { # seed_fixture <dir> <fixture>
    cp -R "$FIXTURES/$2/." "$1/"
}

commit_all() { # commit_all <dir> <message>
    git -C "$1" add -A
    git -C "$1" commit -qm "$2"
}

write_config() { # write_config <dir> <json>
    printf '%s\n' "$2" > "$1/.release.json"
}

release() { # release <dir> [args...]
    local dir="$1"
    shift
    (
        cd "$dir" || exit 1
        PATH="$ROOT/tests/stub:$PATH" \
        GH_STUB_DIR="$dir.gh" \
        XDG_STATE_HOME="$dir.state" \
        XDG_CONFIG_HOME="$dir.config" \
        bash "$RELEASE" "$@"
    )
}

latest_tag() {
    git -C "$1" describe --tags --abbrev=0 2>/dev/null || true
}
