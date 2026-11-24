#!/usr/bin/env bash
# host.sh - host adapter.
#
# The CLI never renders UI. It reports the host it detected and asks only when
# an interactive terminal is attached. Agents (OpenCode, Claude Code, Codex,
# Gemini) render the plan page themselves and call run --yes after confirmation.

host_detect() {
    if [ -n "${OPENCODE_SESSION_ID:-}" ] || [ -n "${OPENCODE:-}" ] || [ -n "${OPENCHAMBER:-}" ]; then
        printf 'opencode'
    elif [ -n "${CLAUDE_CODE:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ]; then
        printf 'claude'
    elif [ -n "${CODEX_HOME:-}" ] || [ -n "${CODEX_SESSION_ID:-}" ]; then
        printf 'codex'
    elif [ -n "${GEMINI_CLI:-}" ] || [ -n "${GEMINI_SESSION_ID:-}" ]; then
        printf 'gemini'
    elif [ -n "${CI:-}" ]; then
        printf 'cli'
    else
        printf 'cli'
    fi
}

host_mode() {
    local configured
    configured="$(cfg host auto)"
    if [ "$configured" = "auto" ]; then
        host_detect
    else
        printf '%s' "$configured"
    fi
}

host_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

host_confirm() { # host_confirm <prompt>
    local prompt="$1" answer
    if ! host_interactive; then
        return 1
    fi
    printf '%s [y/N] ' "$prompt" >&2
    read -r answer || return 1
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}
