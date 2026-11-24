#!/usr/bin/env bash
# state.sh - per-repository release state, lock, and stage tracking.
#
# State lives outside the working tree:
#   ${XDG_STATE_HOME:-~/.local/state}/release-skill/<repo-id>.json
# so a release never dirties the repository it is releasing.

state_paths() {
    STATE_FILE="$(config_state_file)"
    STATE_LOCK_DIR="${STATE_FILE}.lock"
    STATE_DIR="$(dirname "$STATE_FILE")"
}

state_exists() {
    [ -f "${STATE_FILE:-}" ]
}

state_read() {
    [ -f "${STATE_FILE:-}" ] || { printf ''; return 0; }
    python3 - "$STATE_FILE" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    print(""); sys.exit(0)
value = data.get(sys.argv[2], "")
if value is True:
    print("true")
elif value is False:
    print("false")
elif value is None:
    print("")
elif isinstance(value, (dict, list)):
    import json as _json
    print(_json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

state_set() {
    state_paths
    [ -f "$STATE_FILE" ] || return 0
    python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import datetime, json, sys
path, key, value = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data[key] = value
data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

state_set_json() {
    state_paths
    [ -f "$STATE_FILE" ] || return 0
    python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import datetime, json, sys
path, key, raw = sys.argv[1:4]
try:
    value = json.loads(raw)
except Exception:
    value = raw
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data[key] = value
data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

state_stage() { # state_stage <stage> <pending|in_progress|done|failed|skipped>
    state_paths
    [ -f "$STATE_FILE" ] || return 0
    python3 - "$STATE_FILE" "$1" "$2" <<'PY'
import datetime, json, sys
path, stage, status = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
stages = data.setdefault("stages", {})
stages[stage] = status
data["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

state_stage_status() {
    state_read "stages" | python3 -c '
import json, sys
try:
    stages = json.load(sys.stdin)
except Exception:
    stages = {}
print(stages.get(sys.argv[1], "pending"))
' "$1" 2>/dev/null || printf 'pending'
}

state_init() { # state_init <tag> <bare> <target> <branch> <prerelease>
    state_paths
    mkdir -p "$STATE_DIR"
    python3 - "$STATE_FILE" "$1" "$2" "$3" "$4" "$5" "$(config_repo_slug)" "$(pwd -P)" <<'PY'
import datetime, json, sys
path, tag, bare, target, branch, prerelease, repo, repo_dir = sys.argv[1:9]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
data = {
    "schemaVersion": 1,
    "repo": repo,
    "repoDir": repo_dir,
    "version": tag,
    "bareVersion": bare,
    "target": target,
    "branch": branch,
    "prerelease": prerelease == "true",
    "status": "running",
    "failedStage": "",
    "failedCode": 0,
    "stages": {},
    "startedAt": now,
    "updatedAt": now,
    "releaseUrl": "",
    "assets": [],
    "delta": {},
    "pr": "",
    "releaseBranch": "",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
}

state_fail() { # state_fail <stage> <code>
    state_set failedStage "$1"
    state_set failedCode "$2"
    state_set status "failed"
    state_stage "$1" "failed"
}

state_complete() {
    state_set status "done"
    state_set failedStage ""
    state_set failedCode "0"
}

state_clear() {
    state_paths
    [ -f "$STATE_FILE" ] && rm -f "$STATE_FILE"
    [ -d "$STATE_LOCK_DIR" ] && rm -rf "$STATE_LOCK_DIR"
    return 0
}

state_lock() {
    state_paths
    mkdir -p "$STATE_DIR"
    local max_age_hours waited=0
    max_age_hours="$(cfg lock_timeout_hours 6)"
    while ! mkdir "$STATE_LOCK_DIR" 2>/dev/null; do
        local pid age now mtime
        pid="$(cat "$STATE_LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            die 11 "另一个发版进程正在运行（pid $pid）。确认已结束后删除 $STATE_LOCK_DIR"
        fi
        now="$(date +%s)"
        if [ -f "$STATE_LOCK_DIR/created" ]; then
            mtime="$(cat "$STATE_LOCK_DIR/created" 2>/dev/null || printf '%s' "$now")"
        else
            mtime="$now"
        fi
        age=$((now - mtime))
        if [ "$age" -gt $((max_age_hours * 3600)) ]; then
            warn "清理过期锁（${age}s）: $STATE_LOCK_DIR"
            rm -rf "$STATE_LOCK_DIR"
            continue
        fi
        waited=$((waited + 1))
        if [ "$waited" -gt 5 ]; then
            die 11 "无法获取发版锁: $STATE_LOCK_DIR"
        fi
    done
    printf '%s' "$$" > "$STATE_LOCK_DIR/pid"
    printf '%s' "$(date +%s)" > "$STATE_LOCK_DIR/created"
    STATE_LOCK_OWNED=1
}

state_unlock() {
    if [ "${STATE_LOCK_OWNED:-0}" = "1" ]; then
        rm -rf "${STATE_LOCK_DIR:-}" 2>/dev/null || true
        STATE_LOCK_OWNED=0
    fi
}
