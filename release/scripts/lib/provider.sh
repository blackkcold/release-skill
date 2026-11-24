#!/usr/bin/env bash
# provider.sh - release provider adapter (github / none).
#
# v4.3 implements github and none. gitlab is a declared but unimplemented
# contract: it fails loudly instead of silently doing the wrong thing.

provider_resolve() {
    PROVIDER="$(config_provider)"
    REPO_SLUG="$(config_repo_slug)"
    case "$PROVIDER" in
        github)
            [ -n "$REPO_SLUG" ] || die 10 "provider=github，但无法从 remote 解析 owner/repo"
            ;;
        gitlab)
            die 10 "provider=gitlab 尚未实现（v4.3 支持 github / none）。请设置 provider=none 或等待后续版本"
            ;;
        none)
            : ;;
        *)
            die 10 "未知 provider: $PROVIDER"
            ;;
    esac
}

provider_check() {
    case "$PROVIDER" in
        github)
            have gh || { err "缺少 gh CLI"; return 1; }
            gh auth status >/dev/null 2>&1 || { err "gh 未登录（gh auth login）"; return 1; }
            ;;
    esac
    return 0
}

provider_release_exists() {
    local tag="$1"
    [ "$PROVIDER" = "github" ] || return 1
    gh release view "$tag" --repo "$REPO_SLUG" --json tagName >/dev/null 2>&1
}

provider_release_url() {
    local tag="$1"
    [ "$PROVIDER" = "github" ] || { printf ''; return 0; }
    printf 'https://github.com/%s/releases/tag/%s' "$REPO_SLUG" "$tag"
}

provider_release_create() { # provider_release_create <tag> <title> <notes-file> <prerelease> [assets...]
    local tag="$1" title="$2" notes="$3" prerelease="$4"
    shift 4
    if [ "$PROVIDER" = "none" ]; then
        info "provider=none：跳过 Release 创建（tag 已创建）"
        return 0
    fi
    local -a args
    args=(release create "$tag" --repo "$REPO_SLUG" --title "$title" --notes-file "$notes")
    [ "$prerelease" = "true" ] && args+=(--prerelease)
    if [ "$#" -gt 0 ]; then
        gh "${args[@]}" "$@"
    else
        gh "${args[@]}"
    fi
}

provider_upload_assets() { # provider_upload_assets <tag> [assets...]
    local tag="$1"
    shift
    [ "$PROVIDER" = "github" ] || return 0
    [ "$#" -gt 0 ] || return 0
    gh release upload "$tag" --repo "$REPO_SLUG" --clobber "$@"
}

provider_release_assets_json() {
    local tag="$1"
    [ "$PROVIDER" = "github" ] || { printf '[]'; return 0; }
    gh release view "$tag" --repo "$REPO_SLUG" --json assets 2>/dev/null || printf '{"assets":[]}'
}

provider_release_downloads() {
    local tag="$1"
    [ "$PROVIDER" = "github" ] || { printf '0'; return 0; }
    gh release view "$tag" --repo "$REPO_SLUG" --json assets \
        --jq '[.assets[].downloadCount] | add // 0' 2>/dev/null || printf '0'
}

provider_release_created_at() {
    local tag="$1"
    [ "$PROVIDER" = "github" ] || { printf ''; return 0; }
    gh release view "$tag" --repo "$REPO_SLUG" --json createdAt \
        --jq '.createdAt' 2>/dev/null || printf ''
}

provider_release_delete() {
    local tag="$1"
    [ "$PROVIDER" = "github" ] || return 0
    gh release delete "$tag" --repo "$REPO_SLUG" --yes
}

provider_pr_create() { # provider_pr_create <base> <head> <title> <body-file>
    local base="$1" head="$2" title="$3" body="$4"
    [ "$PROVIDER" = "github" ] || return 0
    gh pr create --repo "$REPO_SLUG" --base "$base" --head "$head" --title "$title" --body-file "$body"
}

provider_pr_merge() { # provider_pr_merge <number> <squash>
    local number="$1" method="${2:-squash}"
    [ "$PROVIDER" = "github" ] || return 0
    gh pr merge "$number" --repo "$REPO_SLUG" "--$method"
}

provider_pr_checks() {
    local number="$1"
    [ "$PROVIDER" = "github" ] || return 0
    gh pr checks "$number" --repo "$REPO_SLUG" --watch
}
