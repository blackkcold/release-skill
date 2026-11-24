#!/usr/bin/env bash
# feed.sh - self-update feed and delta adapter.
#
# A feed generator degrades silently: without the previous build it falls back
# to a full package and still looks successful. This adapter makes the outcome
# explicit: seed -> generate -> check -> collect assets.

feed_previous_tag() { # feed_previous_tag <target>
    local target="$1" prefix suffix tag
    prefix="$(cfg tag_prefix v)"
    suffix="$(cfg dev_tag_suffix -dev)"
    if [ "$target" = "develop" ] && [ -n "$suffix" ]; then
        tag="$(git describe --tags --abbrev=0 --match "${prefix}*${suffix}.*" 2>/dev/null || true)"
        [ -n "$tag" ] && { printf '%s' "$tag"; return 0; }
    fi
    if [ -n "$suffix" ]; then
        tag="$(git describe --tags --abbrev=0 --match "${prefix}[0-9]*" --exclude "*${suffix}.*" 2>/dev/null || true)"
    else
        tag="$(git describe --tags --abbrev=0 --match "${prefix}[0-9]*" 2>/dev/null || true)"
    fi
    printf '%s' "$tag"
}

feed_resolve() {
    FEED_KIND="$(cfg update_feed auto)"
    [ "$FEED_KIND" = "auto" ] && FEED_KIND="${DETECTED_UPDATE_FEED:-none}"
    [ -n "$FEED_KIND" ] || FEED_KIND="none"

    FEED_ARCHIVE="$(cfg update_archive_dir release/updates)"
    FEED_FILE="$(cfg update_feed_file "")"
    FEED_COMMAND="$(cfg update_feed_command "")"
    if [ -z "$FEED_COMMAND" ]; then
        FEED_COMMAND="${DETECTED_UPDATE_FEED_COMMAND:-}"
    fi
}

feed_seed_previous() { # feed_seed_previous <previous-tag> <dry-run>
    local prev="$1" dry="$2" dir output rc
    SEEDED_FROM="none"
    SEEDED_FILES="0"
    FEED_SEED_READY="false"
    FULL_REASON=""

    if [ "$FEED_KIND" = "none" ]; then
        FULL_REASON="update_feed=none"
        return 0
    fi
    if [ "$(cfg delta_strategy auto)" = "off" ]; then
        FULL_REASON="delta_strategy=off"
        return 0
    fi
    if [ -z "$prev" ] || [ "$prev" = "${TAG_PREFIX}0.0.0" ]; then
        FULL_REASON="无上一版 tag"
        return 0
    fi

    dir="$(cfg update_previous_dir "")"
    if [ -z "$dir" ]; then
        dir="release/$(printf '%s' "$prev" | sed -E 's/^[^0-9]*//')"
    fi

    local -a args
    args=(--previous "$prev" --target-dir "$dir" --patterns "$(cfg update_artifact_glob '*.dmg,*.zip,*.exe,*.AppImage,*.tar.gz,*.pkg')")
    [ -n "$REPO_SLUG" ] && args+=(--repo "$REPO_SLUG")
    [ "$dry" = "true" ] && args+=(--dry-run)

    if output="$(bash "$RS_ROOT/scripts/seed-update-artifacts.sh" "${args[@]}" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$output" >&2

    if [ "$rc" -ne 0 ]; then
        FULL_REASON="上一版产物就位失败（exit $rc）"
        return 0
    fi
    SEEDED_FROM="$(printf '%s\n' "$output" | sed -n 's/^STAGED_FROM=//p' | tail -1)"
    SEEDED_FILES="$(printf '%s\n' "$output" | sed -n 's/^STAGED_FILES=//p' | tail -1)"
    FEED_SEED_READY="$(printf '%s\n' "$output" | sed -n 's/^DELTA_READY=//p' | tail -1)"
    [ -n "$SEEDED_FROM" ] || SEEDED_FROM="none"
    [ -n "$SEEDED_FILES" ] || SEEDED_FILES="0"
    [ -n "$FEED_SEED_READY" ] || FEED_SEED_READY="false"
    if [ "$FEED_SEED_READY" != "true" ]; then
        FULL_REASON="上一版产物取不到（$SEEDED_FROM）"
    fi
    return 0
}

feed_generate() { # feed_generate <tag> <previous-tag>
    local tag="$1" prev="$2" bare rc
    FEED_FILE=""
    if [ "$FEED_KIND" = "none" ]; then
        return 0
    fi
    if [ -z "$FEED_COMMAND" ]; then
        warn "update_feed=$FEED_KIND，但没有 feed 命令（update_feed_command）"
        FULL_REASON="未配置 feed 命令"
        return 0
    fi

    bare="$(printf '%s' "$tag" | sed -E 's/^[^0-9]*//')"
    info "生成 feed: $FEED_COMMAND"
    if (
        cd "$(pwd -P)" || exit 1
        RELEASE_VERSION="$tag" VERSION="$bare" TAG="$tag" PREVIOUS_TAG="$prev" \
            UPDATE_ARCHIVE_DIR="$FEED_ARCHIVE" DELTA_MAX="$(cfg delta_max 2)" \
            bash -c "$FEED_COMMAND"
    ); then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        err "feed 生成失败（exit $rc）"
        return 13
    fi
    FEED_FILE="$(feed_locate_file)"
    if [ -z "$FEED_FILE" ]; then
        warn "feed 命令执行成功，但未找到 feed 文件"
        FULL_REASON="未找到 feed 文件"
    else
        info "feed 文件: $FEED_FILE"
    fi
    return 0
}

feed_locate_file() {
    local candidate
    if [ -n "${FEED_FILE:-}" ] && [ -f "$FEED_FILE" ]; then
        printf '%s' "$FEED_FILE"
        return 0
    fi
    case "$FEED_KIND" in
        sparkle)
            for candidate in "$FEED_ARCHIVE/appcast.xml" "appcast.xml" "release/appcast.xml" "dist/appcast.xml"; do
                [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
            done
            ;;
        electron)
            for candidate in "$FEED_ARCHIVE"/latest*.yml "dist"/latest*.yml "latest"*.yml; do
                [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
            done
            ;;
        custom|tauri)
            for candidate in "$FEED_ARCHIVE"/*.xml "$FEED_ARCHIVE"/*.json "$FEED_ARCHIVE"/*.yml; do
                [ -f "$candidate" ] && { printf '%s' "$candidate"; return 0; }
            done
            ;;
    esac
    printf ''
}

feed_check_delta() { # feed_check_delta <tag>
    local tag="$1" output
    DELTA_KIND="none"
    DELTA_COUNT="0"
    DELTA_READY="false"
    FEED_HAS_VERSION="false"

    if [ "$FEED_KIND" = "none" ]; then
        FULL_REASON="${FULL_REASON:-update_feed=none}"
        return 0
    fi
    if [ "$(cfg delta_strategy auto)" = "off" ]; then
        FULL_REASON="delta_strategy=off"
        return 0
    fi
    if [ -z "$FEED_FILE" ] || [ ! -f "$FEED_FILE" ]; then
        FULL_REASON="feed 文件不存在"
        if [ "$(cfg delta_strategy auto)" = "always" ]; then
            return 13
        fi
        return 0
    fi

    output="$(bash "$RS_ROOT/scripts/check-update-delta.sh" \
        --version "$tag" --feed "$FEED_FILE" --archive "$FEED_ARCHIVE" --json 2>&1)" || true
    printf '%s\n' "$output" >&2
    DELTA_KIND="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind","none"))' 2>/dev/null || printf 'none')"
    DELTA_COUNT="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("delta_count",0))' 2>/dev/null || printf '0')"
    DELTA_READY="$(printf '%s' "$output" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("delta_ready",False)).lower())' 2>/dev/null || printf 'false')"
    FEED_HAS_VERSION="$(printf '%s' "$output" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("feed_has_version",False)).lower())' 2>/dev/null || printf 'false')"

    if [ "$DELTA_READY" != "true" ]; then
        [ -n "$FULL_REASON" ] || FULL_REASON="本次未产出差分，退回完整包"
        if [ "$(cfg delta_strategy auto)" = "always" ]; then
            err "delta_strategy=always，但没有差分"
            return 13
        fi
    else
        FULL_REASON=""
    fi
    return 0
}

feed_collect_assets() { # feed_collect_assets -> newline list of files
    local f pattern old_ifs
    local -a patterns
    if [ -n "$FEED_FILE" ] && [ -f "$FEED_FILE" ]; then
        printf '%s\n' "$FEED_FILE"
    fi
    for f in "$FEED_ARCHIVE"/*.delta "$FEED_ARCHIVE"/*.blockmap; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    for f in $FEED_ARCHIVE/*; do
        [ -f "$f" ] || continue
        case "$f" in
            *.dmg|*.zip|*.exe|*.AppImage|*.tar.gz|*.pkg) printf '%s\n' "$f" ;;
        esac
    done

    old_ifs="$IFS"
    IFS=','
    for pattern in $(cfg release_assets ""); do
        [ -n "$pattern" ] || continue
        for f in $pattern; do
            [ -f "$f" ] && printf '%s\n' "$f"
        done
    done
    IFS="$old_ifs"
    return 0
}
