#!/usr/bin/env bash
# config.sh - configuration loading, precedence, and validation.
#
# Precedence (later wins):
#   1. bundled defaults            release/config/default.json
#   2. legacy global               ~/.config/opencode/release.json   (deprecated)
#   3. XDG global                  ${XDG_CONFIG_HOME:-~/.config}/release-skill/config.json
#   4. project                     release.config.json
#   5. project                     .release.json
#
# The merged object is exported as RS_CONFIG_JSON; every lookup uses cfg/cfg_bool.

if [ -z "${RS_ROOT:-}" ]; then
    RS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if ! declare -F have >/dev/null 2>&1; then
    have() { command -v "$1" >/dev/null 2>&1; }
fi

config_load() {
    local repo_dir="${1:-.}"
    local defaults="$RS_ROOT/config/default.json"
    local global_old="$HOME/.config/opencode/release.json"
    local global_new="${XDG_CONFIG_HOME:-$HOME/.config}/release-skill/config.json"
    local proj2="$repo_dir/release.config.json"
    local proj1="$repo_dir/.release.json"

    RS_CONFIG_FILES=""
    RS_CONFIG_LEGACY="0"
    local p
    for p in "$global_old" "$global_new" "$proj2" "$proj1"; do
        [ -f "$p" ] || continue
        RS_CONFIG_FILES="${RS_CONFIG_FILES}${RS_CONFIG_FILES:+:}$p"
        [ "$p" = "$global_old" ] && RS_CONFIG_LEGACY="1"
    done
    export RS_CONFIG_FILES RS_CONFIG_LEGACY

    RS_CONFIG_JSON="$(python3 - "$defaults" "$global_old" "$global_new" "$proj2" "$proj1" <<'PY'
import json, os, sys

merged = {}
errors = []
for path in sys.argv[1:]:
    if not os.path.exists(path):
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        errors.append("%s: %s" % (path, exc))
        continue
    if not isinstance(data, dict):
        errors.append("%s: top-level value must be an object" % path)
        continue
    for key, value in data.items():
        merged[key] = value

if errors:
    for item in errors:
        print("CONFIG_ERROR=" + item, file=sys.stderr)
    sys.exit(10)

print(json.dumps(merged, ensure_ascii=False, sort_keys=True))
PY
)" || exit 10
    export RS_CONFIG_JSON
}

cfg() { # cfg <key> [default]
    python3 - "$1" "${2:-}" <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("RS_CONFIG_JSON") or "{}")
except Exception:
    data = {}
value = data.get(sys.argv[1], sys.argv[2])
if value is None:
    print(sys.argv[2])
elif value is True:
    print("true")
elif value is False:
    print("false")
elif isinstance(value, list):
    for item in value:
        print(item)
elif isinstance(value, dict):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

cfg_bool() {
    local value
    value="$(cfg "$1" "${2:-false}")"
    case "$value" in
        true|TRUE|1|yes|on) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

cfg_list() {
    python3 - "$1" <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("RS_CONFIG_JSON") or "{}")
except Exception:
    data = {}
value = data.get(sys.argv[1])
if isinstance(value, list):
    for item in value:
        if isinstance(item, dict):
            import json as _json
            print(_json.dumps(item, ensure_ascii=False))
        else:
            print(item)
PY
}

config_print_sources() {
    if [ -z "${RS_CONFIG_FILES:-}" ]; then
        printf '  (bundled defaults only)\n'
        return 0
    fi
    local old_ifs="$IFS"
    IFS=':'
    for p in $RS_CONFIG_FILES; do
        if [ "$p" = "$HOME/.config/opencode/release.json" ]; then
            printf '  %s (deprecated)\n' "$p"
        else
            printf '  %s\n' "$p"
        fi
    done
    IFS="$old_ifs"
}

config_validate() {
    python3 - <<'PY'
import json, os, sys

try:
    data = json.loads(os.environ.get("RS_CONFIG_JSON") or "{}")
except Exception as exc:
    print("CONFIG_ERROR=invalid JSON: %s" % exc, file=sys.stderr)
    sys.exit(1)

errors = []

def enum(key, allowed):
    value = data.get(key)
    if value is not None and value not in allowed:
        errors.append("%s=%r (allowed: %s)" % (key, value, ", ".join(allowed)))

if data.get("schemaVersion") not in (None, 1):
    errors.append("schemaVersion=%r (supported: 1)" % data.get("schemaVersion"))

enum("provider", ["auto", "github", "none", "gitlab"])
enum("branch_model", ["auto", "single", "dual"])
enum("version_strategy", ["conventional", "semver", "auto"])
enum("notes_style", ["auto", "simple", "bilingual", "changelog", "structured-cn"])
enum("ci_mode", ["local", "ci", "auto"])
enum("pr_flow", ["auto", "always", "never"])
enum("pr_cleanup", ["report", "off"])
enum("main_sync", ["ask", "never"])
enum("update_feed", ["auto", "none", "sparkle", "electron", "tauri", "custom"])
enum("delta_strategy", ["auto", "always", "off"])
enum("host", ["auto", "opencode", "claude", "codex", "gemini", "cli"])

for key in ("docs", "version_files", "experimental_paths", "experimental_keywords", "ignore_dirty"):
    value = data.get(key)
    if value is not None and not isinstance(value, list):
        errors.append("%s must be an array" % key)

if errors:
    for item in errors:
        print("CONFIG_ERROR=" + item, file=sys.stderr)
    sys.exit(1)
PY
}

config_repo_slug() {
    local slug
    slug="$(cfg repo "")"
    if [ -n "$slug" ]; then
        printf '%s' "$slug"
        return 0
    fi
    local url
    url="$(git remote get-url origin 2>/dev/null || true)"
    printf '%s' "$url" | sed -n \
        -e 's#.*github\.com[:/]\([^/]*/[^/]*\)\.git$#\1#p' \
        -e 's#.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p'
}

config_provider() {
    local provider
    provider="$(cfg provider auto)"
    if [ "$provider" != "auto" ]; then
        printf '%s' "$provider"
        return 0
    fi
    local url
    url="$(git remote get-url origin 2>/dev/null || true)"
    case "$url" in
        *github.com*) printf 'github' ;;
        *gitlab*)     printf 'gitlab' ;;
        *)            printf 'none' ;;
    esac
}

config_state_dir() {
    printf '%s/release-skill' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

config_cache_dir() {
    printf '%s/release-skill' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

config_repo_id() {
    local slug path hash
    slug="$(config_repo_slug)"
    [ -n "$slug" ] || slug="local"
    path="$(pwd -P)"
    if have shasum; then
        hash="$(printf '%s|%s' "$path" "$slug" | shasum -a 256 | cut -c1-10)"
    elif have sha256sum; then
        hash="$(printf '%s|%s' "$path" "$slug" | sha256sum | cut -c1-10)"
    else
        hash="$(printf '%s|%s' "$path" "$slug" | cksum | awk '{print $1}')"
    fi
    printf '%s-%s' "$(printf '%s' "$slug" | tr '/:' '__')" "$hash"
}

config_state_file() {
    printf '%s/%s.json' "$(config_state_dir)" "$(config_repo_id)"
}

config_project_name() {
    local name
    name="$(cfg project_name "")"
    if [ -z "$name" ] && [ -f "README.md" ]; then
        name="$(head -1 README.md | sed 's/^# *//')"
    fi
    if [ -z "$name" ]; then
        name="$(basename "$(pwd -P)")"
    fi
    printf '%s' "$name"
}

config_summary() {
    printf 'provider=%s branch_model=%s target=%s feed=%s notes=%s host=%s\n' \
        "$(config_provider)" \
        "$(cfg branch_model auto)" \
        "$(cfg target_branch auto)" \
        "$(cfg update_feed auto)" \
        "$(cfg notes_style auto)" \
        "$(cfg host auto)"
}
