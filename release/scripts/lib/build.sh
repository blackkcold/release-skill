#!/usr/bin/env bash
# build.sh - project detection and build adapter.
#
# Project detection is delegated to scripts/detect-project.sh so the same table
# drives both the CLI and the documentation. Explicit config always wins.

build_detect() {
    local output
    output="$(bash "$RS_ROOT/scripts/detect-project.sh" . 2>/dev/null || true)"
    DETECTED_PROJECT_TYPE="$(printf '%s\n' "$output" | sed -n 's/^PROJECT_TYPE=//p')"
    DETECTED_BUILD_COMMAND="$(printf '%s\n' "$output" | sed -n 's/^BUILD_COMMAND=//p')"
    DETECTED_RELEASE_COMMAND="$(printf '%s\n' "$output" | sed -n 's/^RELEASE_COMMAND=//p')"
    DETECTED_UPDATE_FEED="$(printf '%s\n' "$output" | sed -n 's/^UPDATE_FEED=//p')"
    DETECTED_UPDATE_FEED_COMMAND="$(printf '%s\n' "$output" | sed -n 's/^UPDATE_FEED_COMMAND=//p')"
    [ -n "$DETECTED_PROJECT_TYPE" ] || DETECTED_PROJECT_TYPE="unknown"
    [ -n "$DETECTED_UPDATE_FEED" ] || DETECTED_UPDATE_FEED="none"
}

build_command_resolve() { # build_command_resolve <target>
    local target="$1" configured="" line
    configured="$(cfg build_command "")"
    if [ "$target" = "develop" ]; then
        line="$(cfg build_command_dev "")"
        [ -n "$line" ] && configured="$line"
    else
        line="$(cfg build_command_stable "")"
        [ -n "$line" ] && configured="$line"
    fi
    if [ -n "$configured" ]; then
        printf '%s' "$configured"
    else
        printf '%s' "$DETECTED_BUILD_COMMAND"
    fi
}

build_should_run() {
    local ci_mode
    ci_mode="$(cfg ci_mode local)"
    case "$ci_mode" in
        ci) return 1 ;;
        auto)
            [ -d ".github/workflows" ] && return 1
            ;;
    esac
    return 0
}

build_run() { # build_run <command> <version> <prev>
    local cmd="$1" version="$2" prev="$3" log rc
    [ -n "$cmd" ] || { warn "未配置构建命令，跳过构建"; return 0; }

    if ! build_should_run; then
        info "ci_mode=ci：跳过本地构建（由项目 CI 构建）"
        return 0
    fi

    log="$(config_cache_dir)/build.log"
    mkdir -p "$(dirname "$log")"
    info "构建: $cmd"
    if (
        cd "$(pwd -P)" || exit 1
        RELEASE_VERSION="$version" VERSION="$version" TAG="$version" PREVIOUS_TAG="$prev" \
            bash -c "$cmd"
    ) 2>&1 | tee "$log"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        err "构建失败（exit ${rc}），日志: $log"
        return "$rc"
    fi
    ok "构建完成"
    return 0
}

build_test_run() {
    local cmd
    cmd="$(cfg test_command "")"
    [ -n "$cmd" ] || return 0
    info "测试: $cmd"
    ( cd "$(pwd -P)" && bash -c "$cmd" )
}
