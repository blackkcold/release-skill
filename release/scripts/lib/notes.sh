#!/usr/bin/env bash
# notes.sh - release note adapter.

notes_style_resolve() {
    local style legacy
    style="$(cfg notes_style auto)"
    if [ "$style" = "auto" ]; then
        legacy="$(cfg release_note_style "")"
        [ -n "$legacy" ] && style="$legacy"
    fi
    printf '%s' "$style"
}

notes_title() { # notes_title <tag> <bare>
    local tag="$1" bare="$2" template name
    template="$(cfg release_title '{tag}')"
    name="$(config_project_name)"
    template="${template//\{tag\}/$tag}"
    template="${template//\{version\}/$bare}"
    template="${template//\{name\}/$name}"
    printf '%s' "$template"
}

notes_generate() { # notes_generate <tag> <bare> <previous-tag> -> path
    local tag="$1" bare="$2" prev="$3" style out notes_dir notes_file slug
    style="$(notes_style_resolve)"
    notes_dir="$(config_cache_dir)"
    mkdir -p "$notes_dir"
    notes_file="$notes_dir/notes-$bare.md"
    slug="$(config_repo_slug)"
    out="$(printf '%s' "$slug" | cut -d/ -f1)"
    local owner="${out}" repo="${slug#*/}"

    if [ -f "CHANGELOG.md" ] && grep -q "^## \[$tag\]" CHANGELOG.md 2>/dev/null; then
        local -a args
        args=(CHANGELOG.md "$tag" --owner "$owner" --repo "$repo")
        if [ "$style" != "auto" ]; then
            args+=(--style "$style")
        fi
        if bash "$RS_ROOT/scripts/generate-notes.sh" "${args[@]}" > "$notes_file" 2>/dev/null; then
            printf '%s' "$notes_file"
            return 0
        fi
    fi

    notes_fallback "$tag" "$prev" > "$notes_file"
    printf '%s' "$notes_file"
}

notes_fallback() { # notes_fallback <tag> <previous-tag>
    local tag="$1" prev="$2" range
    printf '# %s Release Notes\n\n## Changes\n\n' "$tag"
    if [ -n "$prev" ] && git rev-parse --verify --quiet "$prev^{commit}" >/dev/null 2>&1; then
        range="$prev..HEAD"
    else
        range="HEAD"
    fi
    git log "$range" --no-merges --format='- %s' 2>/dev/null | head -40
    printf '\n'
}
