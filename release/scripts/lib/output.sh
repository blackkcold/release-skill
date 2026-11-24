#!/usr/bin/env bash
# output.sh - human and machine output helpers.

print_banner() {
    printf '\n── %s ──\n' "$*" >&2
}

print_kv() {
    printf '%s=%s\n' "$1" "$2"
}

print_check() { # print_check <status> <name> <detail> [fix]
    local status="$1" name="$2" detail="$3" fix="${4:-}"
    case "$status" in
        pass) printf '✅ %-18s %s\n' "$name" "$detail" ;;
        warn) printf '⚠️  %-18s %s\n' "$name" "$detail" ;;
        fail) printf '❌ %-18s %s\n' "$name" "$detail" ;;
    esac
    if [ -n "$fix" ] && [ "$status" != "pass" ]; then
        printf '   fix: %s\n' "$fix"
    fi
}

human_size() {
    local bytes="${1:-0}"
    if [ "$bytes" -ge 1048576 ]; then
        printf '%.1fMB' "$(echo "$bytes" | awk '{print $1/1048576}')"
    elif [ "$bytes" -ge 1024 ]; then
        printf '%dKB' "$((bytes / 1024))"
    else
        printf '%dB' "$bytes"
    fi
}

print_plan_human() {
    local dirty_count
    dirty_count="$(printf '%s\n' "$P_DIRTY_PATHS" | sed '/^$/d' | wc -l | tr -d ' ')"
    printf '\n📋 发版计划\n'
    printf '  目标:     %s (%s)\n' "$P_TARGET" "$P_BRANCH"
    if [ -n "$P_PREV" ]; then
        printf '  版本:     %s → %s (%s)\n' "$P_PREV" "$P_VERSION" "$P_BUMP"
    else
        printf '  版本:     %s (%s)\n' "$P_VERSION" "$P_BUMP"
    fi
    printf '  变更:     %s 提交 + %s 个未提交文件\n' "$P_COMMITS" "$dirty_count"
    printf '  构建:     %s\n' "${P_BUILD_CMD:-（无）}"
    if [ "$P_FEED_KIND" = "none" ]; then
        printf '  更新包:   无（update_feed=none）\n'
    else
        printf '  更新包:   %s；%s\n' "$P_FEED_KIND" "$P_DELTA_EXPECTATION"
    fi
    printf '  Release:  %s / %s / %s\n' "$(notes_title "$P_VERSION" "$P_VERSION_BARE")" "$(notes_style_resolve)" "$P_PRERELEASE_LABEL"
    printf '  Provider: %s%s\n' "$PROVIDER" "${REPO_SLUG:+ ($REPO_SLUG)}"
    printf '  Host:     %s\n' "$(host_mode)"
    printf '  配置:     %s\n' "$(printf '%s' "$P_CONFIG_SOURCES" | tr '\n' ' ')"
    printf '  文档:     %s\n' "$(printf '%s' "$P_DOCS" | tr '\n' ' ')"
    if [ "$dirty_count" -gt 0 ]; then
        printf '  待提交:\n'
        printf '%s\n' "$P_DIRTY_PATHS" | sed '/^$/d' | sed 's/^/    /'
    fi
    if [ -n "$P_FULL_REASON" ]; then
        printf '  ⚠️  完整包原因: %s\n' "$P_FULL_REASON"
    fi
    printf '\n'
}
