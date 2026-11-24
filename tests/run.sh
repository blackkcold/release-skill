#!/usr/bin/env bash
# tests/run.sh - integration tests for release-skill.
set -uo pipefail

. "$(dirname "$0")/lib.sh"

test_shell_syntax() {
    local f rc=0
    while IFS= read -r f; do
        if ! bash -n "$f" >/dev/null 2>&1; then
            fail "bash -n $f"
            rc=1
        fi
    done < <(find "$ROOT/release/scripts" "$ROOT/tests" "$ROOT/scripts" -type f -name '*.sh' 2>/dev/null)
    [ "$rc" -eq 0 ] && pass "bash -n all shell files"
}

test_help() {
    local script
    for script in analyze-changes validate-version detect-project generate-notes seed-update-artifacts check-update-delta; do
        if bash "$SKILL/scripts/$script.sh" --help >/dev/null 2>&1; then
            pass "$script.sh --help"
        else
            fail "$script.sh --help"
        fi
    done
    if bash "$RELEASE" --help >/dev/null 2>&1; then
        pass "release.sh --help"
    else
        fail "release.sh --help"
    fi
}

test_version_sync() {
    if [ ! -f "$ROOT/scripts/check-version-sync.sh" ]; then
        fail "scripts/check-version-sync.sh is missing"
        return
    fi
    if bash "$ROOT/scripts/check-version-sync.sh" >/dev/null 2>&1; then
        pass "version sync"
    else
        fail "version sync"
    fi
}

test_validate_version() {
    local script="$SKILL/scripts/validate-version.sh"
    if bash "$script" v1.2.3 v1.2.2 >/dev/null 2>&1; then pass "patch increases"; else fail "patch increases"; fi
    if bash "$script" v1.2.2 v1.2.2 >/dev/null 2>&1; then fail "equal version rejected"; else pass "equal version rejected"; fi
    if bash "$script" v1.3.0-dev.2 v1.3.0-dev.1 --target develop >/dev/null 2>&1; then pass "dev N increases"; else fail "dev N increases"; fi
    if bash "$script" v1.3.0-dev.1 v1.3.0-dev.1 --target develop >/dev/null 2>&1; then fail "dev duplicate rejected"; else pass "dev duplicate rejected"; fi
}

test_detect_project() {
    local dir out
    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-detect.XXXXXX")"
    cp -R "$FIXTURES/swift/." "$dir/"
    out="$(bash "$SKILL/scripts/detect-project.sh" "$dir")"
    assert_contains "$out" "PROJECT_TYPE=swift" "detect swift"
    assert_contains "$out" "BUILD_COMMAND=swift build -c release" "swift build command"

    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-detect.XXXXXX")"
    cp -R "$FIXTURES/node/." "$dir/"
    out="$(bash "$SKILL/scripts/detect-project.sh" "$dir")"
    assert_contains "$out" "PROJECT_TYPE=node" "detect node"
    assert_contains "$out" "BUILD_COMMAND=npm run build" "node build command"

    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-detect.XXXXXX")"
    cp -R "$FIXTURES/plain/." "$dir/"
    out="$(bash "$SKILL/scripts/detect-project.sh" "$dir")"
    assert_contains "$out" "PROJECT_TYPE=unknown" "detect plain"

    touch "$dir/pubspec.yaml"
    out="$(bash "$SKILL/scripts/detect-project.sh" "$dir")"
    assert_contains "$out" "PROJECT_TYPE=flutter" "detect flutter"

    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-detect.XXXXXX")"
    touch "$dir/mix.exs"
    out="$(bash "$SKILL/scripts/detect-project.sh" "$dir")"
    assert_contains "$out" "PROJECT_TYPE=elixir" "detect elixir"
}

test_plan_single() {
    local dir out rc dirty
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    printf 'more\n' >> "$dir/README.md"
    commit_all "$dir" "fix: correct readme"
    write_config "$dir" '{"schemaVersion":1,"provider":"none","branch_model":"single","build_command":"true","pr_flow":"never","release_branch":false,"update_feed":"none","docs":["CHANGELOG.md"],"ignore_dirty":[".release.json"]}'

    out="$(release "$dir" plan --json 2>/dev/null)"
    rc=$?
    assert_eq "$rc" "0" "plan exits 0"
    assert_contains "$out" '"tag": "v1.0.1"' "plan patch tag"
    assert_contains "$out" '"target": "stable"' "plan single target"
    assert_contains "$out" '"provider": "none"' "plan provider none"

    dirty="$(git -C "$dir" status --porcelain | grep -v '.release.json' || true)"
    assert_eq "$dirty" "" "plan does not write"
}

test_plan_dual() {
    local dir out rc
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    git -C "$dir" checkout -q -b develop
    printf 'dev\n' >> "$dir/README.md"
    commit_all "$dir" "feat: dev feature"
    git -C "$dir" tag -a v1.1.0-dev.1 -m v1.1.0-dev.1
    printf 'fix\n' >> "$dir/README.md"
    commit_all "$dir" "fix: dev fix"
    write_config "$dir" '{"schemaVersion":1,"provider":"none","branch_model":"dual","build_command":"true","pr_flow":"never","release_branch":false,"update_feed":"none","docs":["CHANGELOG.md"],"ignore_dirty":[".release.json"]}'

    out="$(release "$dir" plan --json --target develop 2>/dev/null)"
    rc=$?
    assert_eq "$rc" "0" "dual plan exits 0"
    assert_contains "$out" '"target": "develop"' "dual target"
    assert_contains "$out" '"tag": "v1.1.0-dev.2"' "dual dev N"
    assert_contains "$out" '"prerelease": true' "dual prerelease"
}

test_config_priority() {
    local dir out
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    printf 'more\n' >> "$dir/README.md"
    commit_all "$dir" "fix: change"
    mkdir -p "$dir.config/release-skill"
    printf '%s\n' '{"build_command":"echo global"}' > "$dir.config/release-skill/config.json"
    write_config "$dir" '{"provider":"none","branch_model":"single","build_command":"echo project","pr_flow":"never","release_branch":false,"update_feed":"none","ignore_dirty":[".release.json"]}'

    out="$(release "$dir" plan --json 2>/dev/null)"
    assert_contains "$out" '"command": "echo project"' "project config wins"
    assert_contains "$out" '.release.json' "config source listed"

    rm -f "$dir/.release.json"
    out="$(release "$dir" plan --json 2>/dev/null)"
    assert_contains "$out" '"command": "echo global"' "global config fallback"
}

test_run_none() {
    local dir rc log report
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    printf 'more\n' >> "$dir/README.md"
    commit_all "$dir" "fix: change"
    write_config "$dir" '{"schemaVersion":1,"provider":"none","branch_model":"single","build_command":"true","pr_flow":"never","release_branch":false,"update_feed":"none","docs":["CHANGELOG.md"],"ignore_dirty":[".release.json"]}'
    log="$dir.log"

    release "$dir" run --yes > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -20 "$log"
    fi
    assert_eq "$rc" "0" "run provider=none"
    assert_eq "$(git -C "$dir" tag --list v1.0.1)" "v1.0.1" "run creates tag"
    if grep -q '^## \[v1.0.1\]' "$dir/CHANGELOG.md"; then pass "changelog updated"; else fail "changelog updated"; fi
    report="$(find "$dir.state" -name '*-report.json' 2>/dev/null | head -1)"
    assert_file "$report" "report written"
}

test_run_resume() {
    local dir rc log
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    printf 'more\n' >> "$dir/README.md"
    commit_all "$dir" "fix: change"
    write_config "$dir" '{"schemaVersion":1,"provider":"none","branch_model":"single","build_command":"false","pr_flow":"never","release_branch":false,"update_feed":"none","docs":["CHANGELOG.md"],"ignore_dirty":[".release.json"]}'
    log="$dir.log"

    release "$dir" run --yes > "$log" 2>&1
    rc=$?
    assert_eq "$rc" "13" "build failure exits 13"
    assert_eq "$(git -C "$dir" tag --list v1.0.1)" "" "no tag after build failure"

    write_config "$dir" '{"schemaVersion":1,"provider":"none","branch_model":"single","build_command":"true","pr_flow":"never","release_branch":false,"update_feed":"none","docs":["CHANGELOG.md"],"ignore_dirty":[".release.json"]}'
    release "$dir" resume --yes > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -20 "$log"
    fi
    assert_eq "$rc" "0" "resume succeeds"
    assert_eq "$(git -C "$dir" tag --list v1.0.1)" "v1.0.1" "resume creates tag"
}

test_delta() {
    local dir out
    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-delta.XXXXXX")"
    printf '<rss><sparkle:deltaFrom sparkle:version="1.0.0"/></rss>\n' > "$dir/appcast.xml"
    touch "$dir/app.delta"
    out="$(bash "$SKILL/scripts/check-update-delta.sh" --version v1.1.0 --feed "$dir/appcast.xml" --archive "$dir" --json)"
    assert_contains "$out" '"delta_ready":true' "sparkle delta detected"
    assert_contains "$out" '"kind":"sparkle"' "sparkle kind"

    rm -f "$dir/appcast.xml" "$dir/app.delta"
    printf 'version: 1.1.0\n' > "$dir/latest.yml"
    touch "$dir/app.blockmap"
    out="$(bash "$SKILL/scripts/check-update-delta.sh" --version v1.1.0 --feed "$dir/latest.yml" --archive "$dir" --json)"
    assert_contains "$out" '"kind":"electron"' "electron blockmap detected"

    rm -f "$dir/app.blockmap"
    out="$(bash "$SKILL/scripts/check-update-delta.sh" --version v1.1.0 --feed "$dir/latest.yml" --archive "$dir" --json)"
    assert_contains "$out" '"delta_ready":false' "no delta reported"
}

test_gh_stub() {
    local dir rc log origin
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    printf 'more\n' >> "$dir/README.md"
    commit_all "$dir" "fix: change"
    origin="$dir-origin.git"
    git init -q --bare "$origin"
    git -C "$dir" remote add origin "$origin"
    write_config "$dir" '{"schemaVersion":1,"provider":"github","repo":"test/repo","branch_model":"single","build_command":"mkdir -p dist && printf hello > dist/foo.zip","release_assets":"dist/foo.zip","pr_flow":"never","release_branch":false,"update_feed":"none","docs":["CHANGELOG.md"],"ignore_dirty":[".release.json","dist/"]}'
    log="$dir.log"

    release "$dir" run --yes > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -30 "$log"
    fi
    assert_eq "$rc" "0" "run with gh stub"
    assert_file "$dir.gh/release-v1.0.1.json" "stub release created"
    assert_eq "$(git --git-dir="$origin" tag --list v1.0.1)" "v1.0.1" "tag pushed to origin"

    release "$dir" verify --version v1.0.1 > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -20 "$log"
    fi
    assert_eq "$rc" "0" "verify with gh stub"

    release "$dir" rollback --version v1.0.1 --yes > "$log" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tail -20 "$log"
    fi
    assert_eq "$rc" "0" "rollback"
    assert_no_file "$dir.gh/release-v1.0.1.json" "release deleted"
    assert_eq "$(git --git-dir="$origin" tag --list v1.0.1)" "" "tag deleted"
}

test_notes_json() {
    local dir out
    dir="$(mktemp -d "${TMPDIR:-/tmp}/rs-notes.XXXXXX")"
    printf '# Changelog\n\n## [v1.0.1]\n\n### Fixed\n- a bug\n' > "$dir/CHANGELOG.md"
    out="$(cd "$dir" && bash "$SKILL/scripts/generate-notes.sh" CHANGELOG.md v1.0.1 --style simple --json)"
    assert_contains "$out" '"style": "simple"' "notes json style"
    assert_contains "$out" 'a bug' "notes json body"
}

test_doctor_plain() {
    local dir rc
    dir="$(new_repo)"
    seed_fixture "$dir" plain
    commit_all "$dir" "feat: initial"
    git -C "$dir" tag -a v1.0.0 -m v1.0.0
    release "$dir" doctor >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "0" "doctor passes on a plain repo"
}

TESTS="test_shell_syntax test_help test_version_sync test_validate_version test_detect_project test_plan_single test_plan_dual test_config_priority test_run_none test_run_resume test_delta test_gh_stub test_notes_json test_doctor_plain"

for test_name in $TESTS; do
    printf '\n▶ %s\n' "$test_name"
    "$test_name"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
