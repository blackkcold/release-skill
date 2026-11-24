# Changelog

All notable changes to this project are documented here.

## [Unreleased]

## [v4.3.0] - 2026-11-24

### Added

- `release.sh` entry point with `doctor`, `plan`, `run`, `resume`, `verify`, `rollback`, `version`.
- Provider adapter: GitHub and `none`; GitLab is a declared contract that fails loudly.
- Build adapter: Swift, Node, Rust, Go, Python, Make, Gradle, Flutter, Elixir, custom.
- Feed adapter: none, Sparkle, Electron, Tauri, custom.
- State file, directory lock, stage tracking, resume and idempotent tag/Release/asset handling.
- XDG configuration path, legacy path compatibility, `schemaVersion` and schema validation.
- Two-platform CI, fixtures, `gh` stub, delta checks and version-sync check.
- Self-release workflow: tag → zip asset → GitHub Release.

### Changed

- `branch_model: auto` only treats a repository as dual-track when a dev branch exists **and** a dev tag (or explicit `target_branch`) exists.
- `SKILL.md` core is 219 lines; details moved to `references/`.
- Frontmatter follows agentskills.io: `version`, `author`, `tags`, `dependencies` moved under `metadata`.
- The clean gate also ignores `release.config.json`.
- Release commits are pushed to the target branch even without a PR.

### Fixed

- Differential updates no longer silently fall back to a full package: `delta_strategy=always` stops, `auto` reports the reason.
- Tag prefix parsing is no longer limited to `v`.
- `generate-notes.sh` accepts `--json`; `validate-version.sh` and `detect-project.sh` accept `--help`.

### Migration

See `release/references/migration.md`. Existing `.release.json` files keep working.

## [v2.0.0] - 2026-07-30

- Earlier simplified release skill. Preserved as a legacy tag; no `v4.2.0` tag was ever published from this repository.
