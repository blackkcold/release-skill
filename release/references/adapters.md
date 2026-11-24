# Adapters

Core owns versioning, docs, commit, tag, state, verification and reporting. Every environment-specific action goes through one of five adapters.

## Provider

Implemented in `scripts/lib/provider.sh`.

| Function | Contract |
|---|---|
| `provider_resolve` | set `PROVIDER` and `REPO_SLUG`; fail loudly for unsupported providers |
| `provider_check` | auth/dependency preflight |
| `provider_release_exists <tag>` | 0 when the Release exists |
| `provider_release_create <tag> <title> <notes> <prerelease> [assets...]` | create Release and upload assets |
| `provider_upload_assets <tag> [assets...]` | idempotent upload (`--clobber`) |
| `provider_release_assets_json <tag>` | JSON with asset names, sizes and digests |
| `provider_release_downloads <tag>` | total download count |
| `provider_release_created_at <tag>` | ISO timestamp |
| `provider_release_delete <tag>` | delete Release (tag handled by caller) |
| `provider_pr_create/merge/checks` | PR flow |

v4.3 supports `github` and `none`. `gitlab` is a declared contract that exits `10` with a clear message; implement the same functions in a new lib and dispatch in `provider_resolve` before claiming support.

## Build

Implemented in `scripts/lib/build.sh`; detection lives in `scripts/detect-project.sh`.

| Signal | Command |
|---|---|
| `Package.swift` | `swift build -c release` |
| `package.json` + build | `npm run build` |
| `Cargo.toml` | `cargo build --release` |
| `go.mod` | `go build -o ./release/` |
| `pyproject.toml` | `python -m build` |
| `Makefile` + build target | `make build` |
| `build.gradle` / `.kts` | `./gradlew build` |
| `pubspec.yaml` | `flutter build` |
| `mix.exs` | `mix release` |

Explicit `build_command` always wins. `build_command_dev` / `build_command_stable` override per line. `ci_mode=ci` skips the local build.

## Feed

Implemented in `scripts/lib/feed.sh`.

| Kind | Detection | Delta evidence |
|---|---|---|
| `none` | no updater | none |
| `sparkle` | Sparkle dependency or `appcast.xml` / `scripts/appcast.sh` | `deltaFrom` in feed or `*.delta` |
| `electron` | `electron-builder` / `electron-updater` | `*.blockmap` |
| `tauri` | `tauri.conf.json` | none (signed feed only) |
| `custom` | `update_feed_command` set | whatever the command produces; `check-update-delta.sh` reports |

Contract: `update_feed_command` runs in the project root with `RELEASE_VERSION`, `VERSION`, `TAG`, `PREVIOUS_TAG`, `UPDATE_ARCHIVE_DIR`, `DELTA_MAX`. It must write the feed to `update_feed_file` or a conventional location.

## Notes

Implemented in `scripts/lib/notes.sh` and `scripts/generate-notes.sh`.

`notes_style=auto` infers from the last three GitHub Releases: bilingual, structured-cn, changelog, otherwise simple. `release_note_style` is a legacy alias. `generate-notes.sh --json` returns `{"style": "...", "body": "..."}`.

## Host

Implemented in `scripts/lib/host.sh`.

| Host | Rendering | Questions |
|---|---|---|
| `opencode` | Agent renders the plan/report page; CLI outputs JSON | Agent asks through its UI |
| `claude` / `codex` / `gemini` | Agent renders Markdown | Agent asks in chat |
| `cli` | Text plan/report | Terminal prompt when `-t 0` |
| `ci` | Text + exit codes | `--yes` required |

The CLI never assumes a render tool. Agents call `plan --json`, render it themselves, then call `run --yes` after Gate 1 and Gate 2.

## Adding an adapter

1. Add the enum value to `release/config/schema.json` and `default.json`.
2. Implement the contract in the matching `lib/*.sh`.
3. Extend `resolve_*` dispatch.
4. Add a fixture under `tests/fixtures/` and a case in `tests/run.sh`.
5. Update this file and `SKILL.md` only if the user-facing behavior changes.
