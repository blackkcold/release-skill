#!/usr/bin/env bash
# release.sh - universal release entry point.
#
# Commands: doctor | plan | run | resume | verify | rollback | version
# Exit codes: 0 ok, 10 config, 11 preflight, 12 plan/version, 13 build,
#             14 publish, 15 verify, 20 aborted.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/output.sh"
. "$SCRIPT_DIR/lib/config.sh"
. "$SCRIPT_DIR/lib/state.sh"
. "$SCRIPT_DIR/lib/provider.sh"
. "$SCRIPT_DIR/lib/build.sh"
. "$SCRIPT_DIR/lib/feed.sh"
. "$SCRIPT_DIR/lib/notes.sh"
. "$SCRIPT_DIR/lib/docs.sh"
. "$SCRIPT_DIR/lib/host.sh"

CMD=""
VERSION_ARG=""
TARGET_ARG="auto"
REPO_DIR_ARG=""
YES=0
JSON=0
DRY_RUN=0
RESUME=0
RESTART=0
FORCE=0
UPDATE=0
SKIP_BUILD=0
SKIP_RELEASE=0
THROUGH=""
QUIET=0

usage() {
    cat <<'EOF'
Usage: release.sh <command> [options]

Commands:
  doctor      check git, provider auth, config, dependencies, disk, branch
  plan        analyze changes and print the release plan (no writes)
  run         execute the release; requires --yes after Gate 1 + Gate 2
  resume      continue the last incomplete release
  verify      verify tag, release assets, feed and delta
  rollback    delete the Release and tag (guarded by age + downloads)
  version     print the skill version

Options:
  --version <v>     explicit version (e.g. 4.3.0 or v4.3.0)
  --target <line>   auto | develop | stable
  --repo-dir <dir>  project directory (default: current directory)
  --yes, -y         confirm Gate 1 + Gate 2 (agents call after confirmation)
  --json            machine-readable output
  --dry-run         plan only; never writes
  --resume          continue from the last unfinished stage
  --restart         discard an unfinished state and start over
  --force           bypass rollback guards
  --update          update notes/title of an existing Release
  --skip-build      skip the local build
  --skip-release    stop before creating a Release
  --through <stage> stop after a stage (tests/debug)
  --quiet           fewer messages
  --help, -h        show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        doctor|plan|run|resume|verify|rollback|version)
            if [ -n "$CMD" ]; then
                die 10 "未知参数: $1"
            fi
            CMD="$1"
            shift
            ;;
        --version) VERSION_ARG="${2:-}"; shift 2 ;;
        --version=*) VERSION_ARG="${1#*=}"; shift ;;
        --target) TARGET_ARG="${2:-auto}"; shift 2 ;;
        --target=*) TARGET_ARG="${1#*=}"; shift ;;
        --repo-dir) REPO_DIR_ARG="${2:-}"; shift 2 ;;
        --repo-dir=*) REPO_DIR_ARG="${1#*=}"; shift ;;
        --yes|-y) YES=1; shift ;;
        --json) JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --resume) RESUME=1; shift ;;
        --restart) RESTART=1; shift ;;
        --force) FORCE=1; shift ;;
        --update) UPDATE=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --skip-release) SKIP_RELEASE=1; shift ;;
        --through) THROUGH="${2:-}"; shift 2 ;;
        --through=*) THROUGH="${1#*=}"; shift ;;
        --quiet|-q) QUIET=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die 10 "未知参数: $1" ;;
    esac
done

[ -n "$CMD" ] || { usage; exit 10; }

REPO_DIR="$(pwd -P)"
if [ -n "$REPO_DIR_ARG" ]; then
    REPO_DIR="$(cd "$REPO_DIR_ARG" && pwd -P)"
fi
cd "$REPO_DIR"

config_load "$REPO_DIR" || exit 10
if [ "$CMD" != "doctor" ]; then
    config_validate || exit 10
fi
state_paths

# ---------------------------------------------------------------------------
# Shared plan helpers
# ---------------------------------------------------------------------------

resolve_target() {
    local requested="$1" model explicit dev stable
    [ -n "${TAG_PREFIX:-}" ] || TAG_PREFIX="$(cfg tag_prefix v)"
    stable="$(cfg stable_branch main)"
    dev="$(cfg dev_branch develop)"
    case "$requested" in
        develop|dev) printf 'develop'; return 0 ;;
        stable|main) printf 'stable'; return 0 ;;
    esac
    model="$(cfg branch_model auto)"
    case "$model" in
        single) printf 'stable'; return 0 ;;
        dual) printf 'develop'; return 0 ;;
    esac
    explicit="$(cfg target_branch auto)"
    if [ -n "$explicit" ] && [ "$explicit" != "auto" ] && [ "$explicit" != "$stable" ]; then
        printf 'develop'; return 0
    fi
    if git show-ref --verify --quiet "refs/heads/$dev" \
        || git show-ref --verify --quiet "refs/remotes/origin/$dev"; then
        if git describe --tags --abbrev=0 --match "${TAG_PREFIX}*$(cfg dev_tag_suffix -dev).*" >/dev/null 2>&1; then
            printf 'develop'; return 0
        fi
    fi
    printf 'stable'
}

line_branch() {
    case "$1" in
        develop) cfg dev_branch develop ;;
        *) cfg stable_branch main ;;
    esac
}

normalize_tag() {
    local input="$1" prefix bare
    prefix="$(cfg tag_prefix v)"
    bare="$(printf '%s' "$input" | sed -E 's/^[^0-9]*//')"
    printf '%s%s' "$prefix" "$bare"
}

compute_plan() {
    build_detect
    TAG_PREFIX="$(cfg tag_prefix v)"
    PROVIDER="$(config_provider)"
    REPO_SLUG="$(config_repo_slug)"
    if [ "$PROVIDER" = "gitlab" ]; then
        die 10 "provider=gitlab 尚未实现（v4.3 支持 github / none）"
    fi
    if [ "$PROVIDER" = "github" ] && [ -z "$REPO_SLUG" ]; then
        die 10 "provider=github，但无法解析 owner/repo"
    fi

    P_TARGET="$(resolve_target "$TARGET_ARG")"
    P_BRANCH="$(line_branch "$P_TARGET")"

    local analysis rc
    if analysis="$(bash "$RS_ROOT/scripts/analyze-changes.sh" --json --target "$P_TARGET" 2>/dev/null)"; then
        rc=0
    else
        rc=$?
    fi
    [ "$rc" -eq 0 ] || die 12 "变更分析失败（analyze-changes.sh exit ${rc}）"

    P_BASE="$(json_field "$analysis" current "v0.0.0")"
    [ -n "$P_BASE" ] || P_BASE="v0.0.0"
    P_PREV_BASE="$P_BASE"
    P_PROJECT_TYPE="$DETECTED_PROJECT_TYPE"
    P_BUMP="$(json_field "$analysis" suggested_bump "patch")"
    P_COMMITS="$(json_field "$analysis" commits 0)"
    P_DIRTY_TRACKED="$(json_field "$analysis" dirty_tracked 0)"
    P_DIRTY_UNTRACKED="$(json_field "$analysis" dirty_untracked 0)"
    P_HAS_CONTENT="$(json_field "$analysis" has_content false)"
    local stable_base dev_base
    stable_base="$(json_field "$analysis" stable_base "v0.0.0")"
    dev_base="$(json_field "$analysis" dev_base "")"
    if [ "$P_TARGET" = "develop" ] && [ -n "$dev_base" ]; then
        P_PREV="$dev_base"
    else
        P_PREV="$stable_base"
    fi
    case "$P_PREV" in
        ""|"v0.0.0") P_PREV="" ;;
    esac

    if [ -n "$VERSION_ARG" ]; then
        P_VERSION="$(normalize_tag "$VERSION_ARG")"
    elif [ "$P_TARGET" = "develop" ]; then
        P_VERSION="$(json_field "$analysis" next "")"
    else
        P_VERSION="$(json_field "$analysis" suggested_stable_version "")"
    fi
    [ -n "$P_VERSION" ] || die 12 "无法确定版本号"

    if [ "$RESUME" = "1" ] && [ -f "$STATE_FILE" ]; then
        P_VERSION="$(state_read version)"
        P_TARGET="$(state_read target)"
        P_BRANCH="$(state_read branch)"
        P_PREV="$(state_read previousTag)"
        P_VERSION_BARE="$(state_read bareVersion)"
    fi
    [ -n "${P_VERSION_BARE:-}" ] || P_VERSION_BARE="$(printf '%s' "$P_VERSION" | sed -E 's/^[^0-9]*//')"

    P_PRERELEASE="false"
    case "$P_VERSION" in
        *-dev.*|*-rc.*|*-beta.*|*-alpha.*) P_PRERELEASE="true" ;;
    esac
    [ "$P_TARGET" = "develop" ] && P_PRERELEASE="true"
    if [ "$P_PRERELEASE" = "true" ]; then
        P_PRERELEASE_LABEL="Pre-release"
    else
        P_PRERELEASE_LABEL="正式 Release"
    fi

    P_IGNORES="$(cfg_list ignore_dirty)"
    P_DIRTY_LINES="$(filter_status "$(git status --porcelain)" "$P_IGNORES")"
    P_DIRTY_PATHS="$(status_paths "$P_DIRTY_LINES")"

    P_DOCS=""
    local doc
    while IFS= read -r doc; do
        [ -n "$doc" ] || continue
        [ -f "$doc" ] || continue
        if [ -z "$P_DOCS" ]; then
            P_DOCS="$doc"
        else
            P_DOCS="$P_DOCS
$doc"
        fi
    done <<EOF
$(cfg_list docs)
EOF

    P_BUILD_CMD="$(build_command_resolve "$P_TARGET")"
    feed_resolve
    P_FEED_KIND="$FEED_KIND"
    P_FEED_CMD="$FEED_COMMAND"
    P_FULL_REASON=""
    P_DELTA_EXPECTATION="无更新包"
    if [ "$P_FEED_KIND" != "none" ]; then
        feed_seed_previous "$P_PREV" "true" >/dev/null 2>&1 || true
        if [ "$FEED_SEED_READY" = "true" ]; then
            P_DELTA_EXPECTATION="上一版产物可获取，预期差分"
        else
            P_DELTA_EXPECTATION="完整包（${FULL_REASON}）"
            P_FULL_REASON="$FULL_REASON"
        fi
    fi

    P_SUMMARY="$(cfg summary "$P_VERSION")"
    [ -n "$P_SUMMARY" ] || P_SUMMARY="$P_VERSION"
    P_CONFIG_SOURCES="$(config_print_sources)"
}

plan_json() {
    export P_VERSION P_VERSION_BARE P_TARGET P_BRANCH P_PREV P_PREV_BASE P_BUMP
    export P_COMMITS P_DIRTY_TRACKED P_DIRTY_UNTRACKED P_DIRTY_PATHS P_HAS_CONTENT
    export P_DOCS P_BUILD_CMD P_FEED_KIND P_FEED_CMD P_DELTA_EXPECTATION P_FULL_REASON
    export P_PRERELEASE P_CONFIG_SOURCES P_SUMMARY PROVIDER REPO_SLUG P_PROJECT_TYPE
    python3 - <<'PY'
import json, os

def lines(name):
    return [x for x in os.environ.get(name, "").splitlines() if x]

plan = {
    "tag": os.environ.get("P_VERSION", ""),
    "version": os.environ.get("P_VERSION_BARE", ""),
    "target": os.environ.get("P_TARGET", ""),
    "branch": os.environ.get("P_BRANCH", ""),
    "previousTag": os.environ.get("P_PREV", ""),
    "bump": os.environ.get("P_BUMP", ""),
    "commits": int(os.environ.get("P_COMMITS", "0") or 0),
    "dirty": {
        "tracked": int(os.environ.get("P_DIRTY_TRACKED", "0") or 0),
        "untracked": int(os.environ.get("P_DIRTY_UNTRACKED", "0") or 0),
        "files": lines("P_DIRTY_PATHS"),
    },
    "docs": lines("P_DOCS"),
    "build": {
        "type": os.environ.get("P_PROJECT_TYPE", "unknown"),
        "command": os.environ.get("P_BUILD_CMD", ""),
    },
    "feed": {
        "kind": os.environ.get("P_FEED_KIND", "none"),
        "command": os.environ.get("P_FEED_CMD", ""),
        "expected": os.environ.get("P_DELTA_EXPECTATION", ""),
        "fullPackageReason": os.environ.get("P_FULL_REASON", ""),
    },
    "prerelease": os.environ.get("P_PRERELEASE", "false") == "true",
    "provider": os.environ.get("PROVIDER", ""),
    "repo": os.environ.get("REPO_SLUG", ""),
    "configSources": lines("P_CONFIG_SOURCES"),
    "summary": os.environ.get("P_SUMMARY", ""),
    "hasContent": os.environ.get("P_HAS_CONTENT", "false") == "true",
}
print(json.dumps(plan, ensure_ascii=False, indent=2))
PY
}

validate_plan_version() {
    local out rc
    [ -n "${P_PREV_BASE:-}" ] || P_PREV_BASE="$P_BASE"
    if out="$(bash "$RS_ROOT/scripts/validate-version.sh" "$P_VERSION" "$P_PREV_BASE" --target "$P_TARGET" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        err "版本校验失败:"
        printf '%s\n' "$out" >&2
        exit 12
    fi
    info "$out"
}

check_branch() {
    local current
    current="$(current_branch)"
    if [ "$current" != "$P_BRANCH" ]; then
        die 11 "当前分支是 ${current}，发版目标是 ${P_BRANCH}。先执行: git checkout $P_BRANCH"
    fi
}

resolve_pr_flow() {
    local flow
    flow="$(cfg pr_flow auto)"
    if [ "$flow" = "auto" ]; then
        if [ -d ".github/workflows" ]; then
            printf 'always'
        else
            printf 'never'
        fi
        return 0
    fi
    printf '%s' "$flow"
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------

cmd_doctor() {
    local tmp total fail cfg_rc cfg_err
    tmp="$(mktemp "${TMPDIR:-/tmp}/release-doctor.XXXXXX")"
    fail=0

    check() {
        local status="$1" name="$2" detail="$3" fix="${4:-}"
        print_check "$status" "$name" "$detail" "$fix"
        printf '%s\t%s\t%s\t%s\n' "$status" "$name" "$detail" "$fix" >> "$tmp"
        if [ "$status" = "fail" ]; then
            fail=$((fail + 1))
        fi
        return 0
    }

    if git rev-parse --git-dir >/dev/null 2>&1; then
        check pass "git" "$(pwd -P)"
    else
        check fail "git" "不是 Git 仓库" "cd 到仓库根目录"
    fi

    if git remote get-url origin >/dev/null 2>&1; then
        check pass "remote" "$(git remote get-url origin)"
    else
        check warn "remote" "没有 origin" "git remote add origin <url>"
    fi

    local provider
    provider="$(config_provider)"
    case "$provider" in
        github)
            if have gh; then
                if gh auth status >/dev/null 2>&1; then
                    check pass "provider" "github，gh 已登录"
                else
                    check fail "provider" "gh 未登录" "gh auth login"
                fi
            else
                check fail "provider" "缺少 gh CLI" "brew install gh"
            fi
            ;;
        none)
            check warn "provider" "none（只创建本地 tag，不创建 Release）" "设置 provider=github 以发布 Release"
            ;;
        gitlab)
            check fail "provider" "gitlab 尚未实现" "设置 provider=none 或等待 v4.4"
            ;;
    esac

    if cfg_err="$(config_validate 2>&1)"; then
        cfg_rc=0
    else
        cfg_rc=$?
    fi
    if [ "$cfg_rc" -eq 0 ]; then
        check pass "config" "$(config_summary)"
    else
        check fail "config" "$(printf '%s' "$cfg_err" | tr '\n' ' ')" "修正 JSON 后重试"
    fi
    if [ "${RS_CONFIG_LEGACY:-0}" = "1" ]; then
        check warn "config path" "正在读取旧路径 ~/.config/opencode/release.json" "迁移到 \${XDG_CONFIG_HOME:-~/.config}/release-skill/config.json"
    fi

    for dep in git python3 bash; do
        if have "$dep"; then
            check pass "dep:$dep" "$(command -v "$dep")"
        else
            check fail "dep:$dep" "缺失"
        fi
    done

    local branch target
    branch="$(current_branch)"
    target="$(line_branch "$(resolve_target "$TARGET_ARG")")"
    if git show-ref --verify --quiet "refs/heads/$target" \
        || git show-ref --verify --quiet "refs/remotes/origin/$target"; then
        check pass "branch" "当前 $branch / 目标 $target"
    else
        check fail "branch" "目标分支 $target 不存在" "git checkout -b $target"
    fi

    local dirty
    dirty="$(filter_status "$(git status --porcelain)" "$(cfg_list ignore_dirty)")"
    if [ -z "$dirty" ]; then
        check pass "worktree" "干净"
    else
        check warn "worktree" "$(printf '%s\n' "$dirty" | wc -l | tr -d ' ') 个待提交文件（发版时会并入 release commit）" ""
    fi

    local kb
    kb="$(df -Pk . 2>/dev/null | awk 'NR==2 {print $4}' || printf '0')"
    if [ "${kb:-0}" -gt 102400 ]; then
        check pass "disk" "$((kb / 1024))MB 可用"
    else
        check warn "disk" "${kb:-0}KB 可用" "清理磁盘后再发版"
    fi

    if mkdir -p "$(config_state_dir)" "$(config_cache_dir)" 2>/dev/null; then
        check pass "state dir" "$(config_state_dir)"
    else
        check fail "state dir" "不可写: $(config_state_dir)"
    fi

    local vf="" sk="" pj="" v sv pv
    [ -f "release/VERSION" ] && vf="release/VERSION"
    [ -f "release/SKILL.md" ] && sk="release/SKILL.md"
    [ -f ".claude-plugin/plugin.json" ] && pj=".claude-plugin/plugin.json"
    if [ -n "$vf" ] && [ -n "$sk" ] && [ -n "$pj" ]; then
        v="$(cat "$vf")"
        sv="$(python3 - "$sk" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.match(r"^---\n(.*?)\n---", text, re.S)
block = match.group(1) if match else ""
m = re.search(r"^\s+version:\s*\"?([^\"\n]+)\"?\s*$", block, re.M)
print(m.group(1).strip() if m else "")
PY
)"
        pv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$pj")"
        if [ "$v" = "$sv" ] && [ "$v" = "$pv" ]; then
            check pass "version sync" "$v"
        else
            check fail "version sync" "VERSION=$v SKILL=$sv plugin=$pv" "统一版本源"
        fi
    fi

    total="$(wc -l < "$tmp" | tr -d ' ')"
    if [ "$JSON" = "1" ]; then
        python3 - "$tmp" <<'PY'
import json, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    status, name, detail = parts[:3]
    fix = parts[3] if len(parts) > 3 else ""
    rows.append({"status": status, "name": name, "detail": detail, "fix": fix})
print(json.dumps({"ok": all(r["status"] != "fail" for r in rows), "checks": rows}, ensure_ascii=False, indent=2))
PY
    else
        printf '\n%s 项检查，%s 项失败\n' "$total" "$fail"
    fi
    rm -f "$tmp"
    [ "$fail" -eq 0 ] || exit 11
}

# ---------------------------------------------------------------------------
# plan / run
# ---------------------------------------------------------------------------

cmd_plan() {
    compute_plan
    if [ "$P_HAS_CONTENT" != "true" ]; then
        if [ "$JSON" = "1" ]; then plan_json; else
            warn "基准 $P_BASE 以来没有变更，无需发版"
        fi
        exit 12
    fi
    validate_plan_version
    if [ "$JSON" = "1" ]; then
        plan_json
    else
        print_plan_human
    fi
}

stage_docs() {
    local out rc
    if out="$(docs_update "$P_VERSION" "$P_VERSION_BARE" "$P_PREV" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$out" >&2
    [ "$rc" -eq 0 ] || return 10
    DOCS_CHANGED="$(printf '%s\n' "$out" | sed -n 's/^CHANGED=//p' | sed '/^$/d')"
    if [ -n "$DOCS_CHANGED" ]; then
        info "文档已更新: $(printf '%s' "$DOCS_CHANGED" | tr '\n' ' ')"
    else
        info "文档无需更新"
    fi
    return 0
}

stage_commit() {
    local dirty flow release_branch paths p pr_url pr_body
    dirty="$(filter_status "$(git status --porcelain)" "$P_IGNORES")"
    if [ -z "$dirty" ]; then
        local rb pr_url pr_body
        rb="$(state_read releaseBranch)"
        if [ -n "$rb" ] && git show-ref --verify --quiet "refs/heads/$rb" \
            && [ "$(git rev-list --count "$P_BRANCH..$rb" 2>/dev/null || printf '0')" -gt 0 ]; then
            [ "$(current_branch)" = "$rb" ] || git checkout "$rb"
            if [ -z "$(state_read pr)" ] && git remote get-url origin >/dev/null 2>&1; then
                git push -u origin "$rb" || return 14
                pr_body="$(config_cache_dir)/pr-body.md"
                mkdir -p "$(dirname "$pr_body")"
                {
                    printf 'Release %s\n\n' "$P_VERSION"
                    printf -- '- commits: %s\n' "$P_COMMITS"
                    printf -- '- build: %s\n' "${P_BUILD_CMD:-none}"
                    printf -- '- update package: %s\n' "$P_DELTA_EXPECTATION"
                } > "$pr_body"
                pr_url="$(provider_pr_create "$P_BRANCH" "$rb" "release: $P_VERSION" "$pr_body")"
                PR_NUMBER="$(printf '%s' "$pr_url" | sed -n 's#.*/pull/\([0-9][0-9]*\)$#\1#p')"
                [ -n "$PR_NUMBER" ] || return 14
                state_set pr "$PR_NUMBER"
                info "PR #$PR_NUMBER: $pr_url"
            fi
        fi
        info "工作区没有待提交变更"
        return 0
    fi

    flow="$(resolve_pr_flow)"
    if [ "$flow" = "always" ] && [ "$(cfg_bool release_branch true)" = "true" ]; then
        release_branch="release/$P_VERSION_BARE"
        if [ "$(current_branch)" = "$release_branch" ]; then
            :
        elif git show-ref --verify --quiet "refs/heads/$release_branch"; then
            git checkout "$release_branch"
        else
            git checkout -b "$release_branch"
        fi
        state_set releaseBranch "$release_branch"
        PR_FLOW_ACTIVE="always"
        RELEASE_BRANCH_ACTIVE="$release_branch"
    else
        PR_FLOW_ACTIVE="never"
        RELEASE_BRANCH_ACTIVE=""
    fi

    paths="$(status_paths "$dirty")"
    if [ -n "${DOCS_CHANGED:-}" ]; then
        paths="$paths
$DOCS_CHANGED"
    fi
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        git add -A -- "$p"
    done <<EOF
$paths
EOF

    if git diff --cached --quiet; then
        info "没有暂存变更"
        return 0
    fi
    git commit -m "release: $P_VERSION — $P_SUMMARY"

    if [ "${PR_FLOW_ACTIVE:-never}" = "always" ]; then
        git push -u origin "$RELEASE_BRANCH_ACTIVE"
        pr_body="$(config_cache_dir)/pr-body.md"
        mkdir -p "$(dirname "$pr_body")"
        {
            printf 'Release %s\n\n' "$P_VERSION"
            printf -- '- commits: %s\n' "$P_COMMITS"
            printf -- '- build: %s\n' "${P_BUILD_CMD:-none}"
            printf -- '- update package: %s\n' "$P_DELTA_EXPECTATION"
        } > "$pr_body"
        pr_url="$(provider_pr_create "$P_BRANCH" "$RELEASE_BRANCH_ACTIVE" "release: $P_VERSION" "$pr_body")"
        PR_NUMBER="$(printf '%s' "$pr_url" | sed -n 's#.*/pull/\([0-9][0-9]*\)$#\1#p')"
        [ -n "$PR_NUMBER" ] || return 14
        state_set pr "$PR_NUMBER"
        info "PR #$PR_NUMBER: $pr_url"
    fi
    return 0
}

stage_clean() {
    local dirty
    dirty="$(filter_status "$(git status --porcelain)" "$P_IGNORES")"
    if [ -n "$dirty" ]; then
        err "干净闸门失败，以下文件未被 ignore_dirty 覆盖:"
        printf '%s\n' "$dirty" >&2
        return 11
    fi
    ok "工作区干净"
    return 0
}

stage_seed() {
    if [ "$P_FEED_KIND" = "none" ]; then
        info "update_feed=none，跳过上一版产物"
        return 0
    fi
    feed_seed_previous "$P_PREV" "false"
    if [ "$FEED_SEED_READY" != "true" ] && [ "$(cfg delta_strategy auto)" = "always" ]; then
        err "delta_strategy=always，但上一版产物不可用: $FULL_REASON"
        return 13
    fi
    return 0
}

stage_build() {
    if [ "$SKIP_BUILD" = "1" ]; then
        info "--skip-build"
        return 0
    fi
    build_run "$P_BUILD_CMD" "$P_VERSION" "$P_PREV"
}

stage_feed() {
    feed_generate "$P_VERSION" "$P_PREV"
}

stage_delta() {
    feed_check_delta "$P_VERSION"
}

stage_merge() {
    local pr release_branch
    pr="$(state_read pr)"
    [ -n "$pr" ] || return 0
    provider_pr_checks "$pr" || return 14
    provider_pr_merge "$pr" "squash" || return 14
    git checkout "$P_BRANCH"
    git pull --ff-only origin "$P_BRANCH"
    release_branch="$(state_read releaseBranch)"
    if [ -n "$release_branch" ] && [ "$(current_branch)" != "$release_branch" ]; then
        git branch -D "$release_branch" >/dev/null 2>&1 || true
    fi
    return 0
}

stage_push_branch() {
    if [ "$(state_read pr)" != "" ]; then
        info "已通过 PR 合并，跳过分支推送"
        return 0
    fi
    if ! git remote get-url origin >/dev/null 2>&1; then
        warn "没有 origin，跳过分支推送"
        return 0
    fi
    git push origin "$P_BRANCH"
}

stage_tag() {
    local existing head
    if git rev-parse --verify --quiet "refs/tags/$P_VERSION" >/dev/null 2>&1; then
        existing="$(git rev-parse "$P_VERSION^{commit}" 2>/dev/null || true)"
        head="$(git rev-parse HEAD)"
        if [ "$existing" = "$head" ]; then
            info "tag $P_VERSION 已存在且指向 HEAD"
            return 0
        fi
        err "tag $P_VERSION 已存在，指向 ${existing}（HEAD ${head}）"
        return 12
    fi
    git tag -a "$P_VERSION" -m "$P_VERSION — $P_SUMMARY"
}

stage_push_tag() {
    if ! git remote get-url origin >/dev/null 2>&1; then
        warn "没有 origin，跳过 tag 推送"
        return 0
    fi
    if git ls-remote --tags origin "refs/tags/$P_VERSION" 2>/dev/null | grep -q .; then
        info "远端 tag $P_VERSION 已存在，跳过"
        return 0
    fi
    git push origin "$P_VERSION"
}

stage_release() {
    local notes title f assets_json
    if [ "$SKIP_RELEASE" = "1" ]; then
        info "--skip-release"
        return 0
    fi
    notes="$(notes_generate "$P_VERSION" "$P_VERSION_BARE" "$P_PREV")"
    title="$(notes_title "$P_VERSION" "$P_VERSION_BARE")"
    P_NOTES_FILE="$notes"
    P_RELEASE_TITLE="$title"

    if [ "$PROVIDER" = "none" ]; then
        info "provider=none：跳过 Release 创建"
        state_set releaseUrl ""
        return 0
    fi

    if provider_release_exists "$P_VERSION"; then
        info "Release $P_VERSION 已存在"
        if [ "$UPDATE" = "1" ]; then
            gh release edit "$P_VERSION" --repo "$REPO_SLUG" --title "$title" --notes-file "$notes"
        fi
    else
        local -a assets
        assets=()
        while IFS= read -r f; do
            [ -n "$f" ] && assets+=("$f")
        done <<EOF
$(feed_collect_assets)
EOF
        if [ "${#assets[@]}" -gt 0 ]; then
            provider_release_create "$P_VERSION" "$title" "$notes" "$P_PRERELEASE" "${assets[@]}" || return 14
        else
            provider_release_create "$P_VERSION" "$title" "$notes" "$P_PRERELEASE" || return 14
        fi
    fi

    local -a upload
    upload=()
    while IFS= read -r f; do
        [ -n "$f" ] && upload+=("$f")
    done <<EOF
$(feed_collect_assets)
EOF
    if [ "${#upload[@]}" -gt 0 ]; then
        provider_upload_assets "$P_VERSION" "${upload[@]}" || return 14
    fi

    P_RELEASE_URL="$(provider_release_url "$P_VERSION")"
    state_set releaseUrl "$P_RELEASE_URL"
    assets_json="[]"
    if [ "${#upload[@]}" -gt 0 ]; then
        assets_json="$(
            for f in "${upload[@]}"; do
                [ -n "$f" ] || continue
                printf '%s\t%s\n' "$(basename "$f")" "$(sha256_file "$f")"
            done | python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 2 and parts[0]:
        rows.append({"name": parts[0], "sha256": parts[1]})
print(json.dumps(rows, ensure_ascii=False))
'
        )"
    fi
    state_set_json assets "$assets_json"
    return 0
}

vcheck() {
    local status="$1" name="$2" detail="$3"
    print_check "$status" "$name" "$detail"
    printf '%s\t%s\t%s\n' "$status" "$name" "$detail" >> "$VCHECK_TMP"
    if [ "$status" = "fail" ]; then
        VCHECK_FAIL=$((VCHECK_FAIL + 1))
    fi
    return 0
}

verify_impl() {
    local tag="$1" tag_commit head remote_json f name expected actual
    VCHECK_TMP="$(mktemp "${TMPDIR:-/tmp}/release-verify.XXXXXX")"
    VCHECK_FAIL=0

    if git rev-parse --verify --quiet "refs/tags/$tag^{commit}" >/dev/null 2>&1; then
        vcheck pass "tag local" "$tag"
    else
        vcheck fail "tag local" "$tag 不存在"
    fi

    if ! git remote get-url origin >/dev/null 2>&1; then
        vcheck warn "tag remote" "没有 origin，跳过远端校验"
    elif git ls-remote --tags origin "refs/tags/$tag" 2>/dev/null | grep -q .; then
        vcheck pass "tag remote" "origin/$tag"
    else
        vcheck fail "tag remote" "origin 没有 $tag"
    fi

    tag_commit="$(git rev-parse "$tag^{commit}" 2>/dev/null || true)"
    head="$(git rev-parse HEAD)"
    if [ -n "$tag_commit" ] && [ "$tag_commit" = "$head" ]; then
        vcheck pass "tag target" "指向 HEAD ${head:0:8}"
    else
        vcheck fail "tag target" "tag 指向 ${tag_commit:0:8}，HEAD ${head:0:8}"
    fi

    if [ "$PROVIDER" = "github" ]; then
        if provider_release_exists "$tag"; then
            vcheck pass "release" "$(provider_release_url "$tag")"
        else
            vcheck fail "release" "GitHub Release 不存在"
        fi

        remote_json="$(provider_release_assets_json "$tag")"
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            name="$(basename "$f")"
            if printf '%s' "$remote_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print("yes" if any(a.get("name") == sys.argv[1] for a in data.get("assets", [])) else "no")
' "$name" | grep -q '^yes$'; then
                expected="$(sha256_file "$f")"
                actual="$(printf '%s' "$remote_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for asset in data.get("assets", []):
    if asset.get("name") == sys.argv[1]:
        print((asset.get("digest") or "").replace("sha256:", ""))
        break
' "$name")"
                if [ -n "$expected" ] && [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
                    vcheck fail "asset:$name" "sha256 不一致"
                else
                    vcheck pass "asset:$name" "已上传"
                fi
            else
                vcheck fail "asset:$name" "远端缺失"
            fi
        done <<EOF
$(feed_collect_assets)
EOF
    fi

    if [ -n "$FEED_FILE" ] && [ -f "$FEED_FILE" ]; then
        if grep -q "$P_VERSION_BARE" "$FEED_FILE" 2>/dev/null; then
            vcheck pass "feed" "$FEED_FILE 包含 $P_VERSION_BARE"
        else
            vcheck fail "feed" "$FEED_FILE 未包含 $P_VERSION_BARE"
        fi
    fi

    if [ "$FEED_KIND" != "none" ]; then
        feed_check_delta "$tag" || true
        if [ "$DELTA_READY" = "true" ]; then
            vcheck pass "delta" "$DELTA_KIND x$DELTA_COUNT"
        elif [ "$(cfg delta_strategy auto)" = "always" ]; then
            vcheck fail "delta" "delta_strategy=always，但未产出差分"
        else
            vcheck warn "delta" "完整包: ${FULL_REASON:-未产出差分}"
        fi
    fi

    rm -f "$VCHECK_TMP"
    if [ "$VCHECK_FAIL" -eq 0 ]; then
        ok "verify 全部通过"
        return 0
    fi
    err "verify 有 $VCHECK_FAIL 项失败"
    return 1
}

stage_verify() {
    verify_impl "$P_VERSION"
}

stage_report() {
    local report final_dirty
    report="${STATE_FILE%.json}-report.json"
    final_dirty="$(filter_status "$(git status --porcelain)" "$P_IGNORES")"
    export P_VERSION P_VERSION_BARE P_TARGET P_BRANCH P_PREV P_BUMP
    export P_FEED_KIND DELTA_KIND DELTA_READY FULL_REASON PROVIDER REPO_SLUG
    export P_RELEASE_TITLE P_NOTES_FILE P_RELEASE_URL REPORT_FILE
    REPORT_FILE="$report"
    P_RELEASE_URL="$(state_read releaseUrl)"
    python3 - <<'PY'
import json, os, datetime
report = {
    "version": os.environ.get("P_VERSION", ""),
    "bareVersion": os.environ.get("P_VERSION_BARE", ""),
    "target": os.environ.get("P_TARGET", ""),
    "branch": os.environ.get("P_BRANCH", ""),
    "previousTag": os.environ.get("P_PREV", ""),
    "bump": os.environ.get("P_BUMP", ""),
    "provider": os.environ.get("PROVIDER", ""),
    "repo": os.environ.get("REPO_SLUG", ""),
    "releaseTitle": os.environ.get("P_RELEASE_TITLE", ""),
    "notesFile": os.environ.get("P_NOTES_FILE", ""),
    "releaseUrl": os.environ.get("P_RELEASE_URL", ""),
    "feed": os.environ.get("P_FEED_KIND", "none"),
    "delta": {
        "kind": os.environ.get("DELTA_KIND", "none"),
        "ready": os.environ.get("DELTA_READY", "false") == "true",
        "fullPackageReason": os.environ.get("FULL_REASON", ""),
    },
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(os.environ["REPORT_FILE"], "w", encoding="utf-8") as fh:
    json.dump(report, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print(json.dumps(report, ensure_ascii=False, indent=2))
PY

    printf '\n📋 发版报告\n'
    printf '  ✅ 版本:   %s (%s)\n' "$P_VERSION" "$P_PRERELEASE_LABEL"
    printf '  ✅ 目标:   %s (%s)\n' "$P_TARGET" "$P_BRANCH"
    if [ "$PROVIDER" = "github" ]; then
        printf '  ✅ Release: %s\n' "$(provider_release_url "$P_VERSION")"
    else
        printf '  ✅ Tag:     %s（provider=none，无 Release）\n' "$P_VERSION"
    fi
    if [ "$P_FEED_KIND" = "none" ]; then
        printf '  ✅ 更新包:  无（update_feed=none）\n'
    elif [ "$DELTA_READY" = "true" ]; then
        printf '  ✅ 更新包:  差分 %s 个（%s）\n' "$DELTA_COUNT" "$DELTA_KIND"
    else
        printf '  ⚠️  更新包:  完整包（%s）\n' "${FULL_REASON:-未产出差分}"
    fi
    printf '  📄 报告:   %s\n' "$report"
    if [ -n "$final_dirty" ]; then
        printf '  ⚠️  收尾工作区不干净:\n'
        printf '%s\n' "$final_dirty" | sed 's/^/     /'
    else
        printf '  ✅ 收尾:   工作区干净\n'
    fi
    state_complete
    return 0
}

run_stage() {
    local name="$1" fn="$2" code="$3" rc
    if [ "$(state_stage_status "$name")" = "done" ]; then
        info "跳过 ${name}（已完成）"
        return 0
    fi
    print_banner "$name"
    state_stage "$name" "in_progress"
    if "$fn"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        state_fail "$name" "$rc"
        err "阶段 $name 失败（exit ${rc}）"
        printf '下一步: bash %s resume\n' "$RS_ROOT/scripts/release.sh" >&2
        exit "$code"
    fi
    state_stage "$name" "done"
    if [ -n "$THROUGH" ] && [ "$THROUGH" = "$name" ]; then
        info "已到 --through ${name}，停止"
        exit 0
    fi
    return 0
}

cmd_run() {
    if [ "$DRY_RUN" = "1" ]; then
        cmd_plan
        return 0
    fi
    compute_plan
    validate_plan_version
    if [ "$P_HAS_CONTENT" != "true" ] && [ "$RESUME" != "1" ]; then
        die 12 "没有变更可发版"
    fi

    provider_resolve
    provider_check || exit 11
    check_branch
    print_plan_human

    if [ "$YES" != "1" ]; then
        if ! host_confirm "执行以上发版计划？"; then
            die 20 "未确认 Gate 1。Agent 应先展示计划，确认后使用 --yes 执行"
        fi
        if ! host_confirm "确认不可逆操作（推送 tag / 创建 Release / 上传资产）？"; then
            die 20 "未确认 Gate 2"
        fi
    fi

    if [ "$RESUME" = "1" ]; then
        [ -f "$STATE_FILE" ] || die 11 "没有可续跑的状态文件"
        info "续跑: $P_VERSION"
    else
        if [ "$RESTART" = "1" ]; then
            state_clear
        fi
        if [ -f "$STATE_FILE" ]; then
            case "$(state_read status)" in
                running|failed)
                    die 11 "存在未完成的发版（$(state_read version)）。用 release.sh resume 续跑，或 --restart"
                    ;;
            esac
        fi
        state_init "$P_VERSION" "$P_VERSION_BARE" "$P_TARGET" "$P_BRANCH" "$P_PRERELEASE"
        state_set previousTag "$P_PREV"
    fi

    state_lock
    trap 'state_unlock' EXIT

    DOCS_CHANGED=""
    PR_NUMBER=""
    run_stage docs      stage_docs      10
    run_stage commit    stage_commit    10
    run_stage clean     stage_clean     11
    run_stage seed      stage_seed      13
    run_stage build     stage_build     13
    run_stage feed      stage_feed      13
    run_stage delta     stage_delta     13
    run_stage merge     stage_merge     14
    run_stage push      stage_push_branch 14
    run_stage tag       stage_tag       12
    run_stage push_tag  stage_push_tag  14
    run_stage release   stage_release   14
    run_stage verify    stage_verify    15
    run_stage report    stage_report    0

    state_unlock
    trap - EXIT
}

cmd_resume() {
    state_paths
    [ -f "$STATE_FILE" ] || die 11 "没有可续跑的状态文件"
    RESUME=1
    VERSION_ARG="$(state_read version)"
    TARGET_ARG="$(state_read target)"
    cmd_run
}

# ---------------------------------------------------------------------------
# verify / rollback / version
# ---------------------------------------------------------------------------

cmd_verify() {
    local tag
    if [ -n "$VERSION_ARG" ]; then
        tag="$(normalize_tag "$VERSION_ARG")"
    elif [ -f "$STATE_FILE" ] && [ -n "$(state_read version)" ]; then
        tag="$(state_read version)"
    else
        tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
    fi
    [ -n "$tag" ] || die 12 "无法确定要验证的版本"

    build_detect
    feed_resolve
    FEED_FILE="$(feed_locate_file)"
    P_VERSION="$tag"
    P_VERSION_BARE="$(printf '%s' "$tag" | sed -E 's/^[^0-9]*//')"
    provider_resolve
    provider_check || exit 11

    verify_impl "$tag" || exit 15
}

cmd_rollback() {
    local tag created age_hours downloads limit_tag
    state_paths
    if [ -n "$VERSION_ARG" ]; then
        tag="$(normalize_tag "$VERSION_ARG")"
    elif [ -f "$STATE_FILE" ] && [ -n "$(state_read version)" ]; then
        tag="$(state_read version)"
    else
        die 12 "请指定 --version"
    fi

    [ "$YES" = "1" ] || die 20 "rollback 需要 --yes（删除 Release 与 tag）"
    provider_resolve
    provider_check || exit 11

    created="$(provider_release_created_at "$tag")"
    if [ -n "$created" ]; then
        age_hours="$(python3 - "$created" <<'PY'
import sys
from datetime import datetime, timezone
raw = sys.argv[1].replace("Z", "+00:00")
try:
    created = datetime.fromisoformat(raw)
    delta = datetime.now(timezone.utc) - created
    print(int(delta.total_seconds() // 3600))
except Exception:
    print(0)
PY
)"
        if [ "$age_hours" -gt "$(cfg rollback_window_hours 24)" ] && [ "$FORCE" != "1" ]; then
            die 20 "Release 已存在 ${age_hours}h，超过回滚窗口。确认风险后加 --force"
        fi
    fi

    downloads="$(provider_release_downloads "$tag")"
    if [ "$downloads" -gt "$(cfg rollback_max_downloads 10)" ] && [ "$FORCE" != "1" ]; then
        die 20 "Release 已有 ${downloads} 次下载，超过阈值。确认风险后加 --force"
    fi

    info "删除 Release ${tag}（下载 $downloads 次）"
    provider_release_delete "$tag" || true
    info "删除远端 tag $tag"
    git push origin ":refs/tags/$tag" 2>/dev/null || warn "远端 tag 删除失败（可能被 ruleset 保护）"
    git tag -d "$tag" >/dev/null 2>&1 || true
    state_set status "rolled_back"
    ok "已回滚 $tag"
}

cmd_version() {
    if [ "$JSON" = "1" ]; then
        printf '{"name":"release-skill","version":"%s"}\n' "$RS_VERSION"
    else
        printf '%s\n' "$RS_VERSION"
    fi
}

case "$CMD" in
    doctor)   cmd_doctor ;;
    plan)     cmd_plan ;;
    run)      cmd_run ;;
    resume)   cmd_resume ;;
    verify)   cmd_verify ;;
    rollback) cmd_rollback ;;
    version)  cmd_version ;;
esac
