# Configuration

## Precedence

Later files override earlier ones; arrays replace, they do not merge.

1. `release/config/default.json` (bundled)
2. `~/.config/opencode/release.json` (legacy, still read; prints a deprecation notice)
3. `${XDG_CONFIG_HOME:-~/.config}/release-skill/config.json`
4. `<project>/release.config.json`
5. `<project>/.release.json`

`doctor` and `plan --json` print the files actually used. `schemaVersion` must be `1` when present.

## Fields

| Field | Default | Notes |
|---|---|---|
| `provider` | `auto` | `auto` / `github` / `none` / `gitlab` (not implemented in v4.3) |
| `repo` | `""` | `owner/repo`; empty parses `origin` |
| `tag_prefix` | `v` | any prefix; scripts parse from the first digit |
| `branch_model` | `auto` | `auto` / `single` / `dual` |
| `stable_branch` | `main` | stable release branch |
| `dev_branch` | `develop` | prerelease branch |
| `dev_tag_suffix` | `-dev` | `vX.Y.Z-dev.N` |
| `target_branch` | `auto` | legacy explicit line selector; `auto` uses `branch_model` |
| `version_strategy` | `conventional` | `conventional` / `semver` / `auto` |
| `project_name` | `""` | used in release titles; falls back to README H1 |
| `release_title` | `{tag}` | `{tag}`, `{version}`, `{name}` |
| `build_command` | `null` | explicit command; overrides detection |
| `build_command_dev` / `build_command_stable` | `null` | per-line build override |
| `release_command` | `null` | reserved; build falls back to `build_command` |
| `test_command` | `null` | optional pre-release test |
| `docs` | `["CHANGELOG.md","README.md"]` | files considered for the release commit |
| `version_files` | `[]` | `path` or `path:kind`; kinds: `version` / `json` / `frontmatter` / `text` |
| `changelog_format` | `keep-a-changelog` | documentation only |
| `notes_style` | `auto` | `auto` / `simple` / `bilingual` / `changelog` / `structured-cn` |
| `release_note_style` | `null` | legacy alias; read when `notes_style=auto` |
| `ci_mode` | `local` | `local` / `ci` / `auto` |
| `release_branch` | `true` | create `release/vX.Y.Z` when PR flow is active |
| `pr_flow` | `auto` | `auto` / `always` / `never`; `auto` requires PR when `.github/workflows` exists |
| `pr_cleanup` | `report` | `report` / `off` |
| `pr_cleanup_stale_days` | `30` | stale PR threshold |
| `main_sync` | `ask` | `ask` / `never` |
| `experimental_paths` | `[]` | globs forced to stay on develop |
| `experimental_keywords` | see default | case-insensitive fallback |
| `update_feed` | `auto` | `auto` / `none` / `sparkle` / `electron` / `tauri` / `custom` |
| `update_feed_command` | `null` | command that generates the feed |
| `update_feed_file` | `null` | explicit feed path |
| `update_archive_dir` | `release/updates` | feed and delta directory |
| `update_previous_dir` | `null` | where the previous artifact is staged |
| `update_artifact_glob` | see default | artifact globs to fetch from the previous release |
| `release_assets` | `""` | comma-separated extra assets uploaded to the Release |
| `delta_strategy` | `auto` | `auto` / `always` / `off` |
| `delta_max` | `2` | passed to the feed tool |
| `ignore_dirty` | see default | paths excluded from the clean gate |
| `host` | `auto` | `auto` / `opencode` / `claude` / `codex` / `gemini` / `cli` |
| `lock_timeout_hours` | `6` | stale lock threshold |
| `rollback_window_hours` | `24` | rollback guard |
| `rollback_max_downloads` | `10` | rollback guard |

## Examples

Single-branch Node project:

```json
{
  "schemaVersion": 1,
  "provider": "github",
  "branch_model": "single",
  "build_command": "npm run build",
  "test_command": "npm test",
  "notes_style": "changelog",
  "pr_flow": "never",
  "update_feed": "none"
}
```

Sparkle macOS app:

```json
{
  "schemaVersion": 1,
  "provider": "github",
  "branch_model": "single",
  "build_command": "scripts/build.sh",
  "update_feed": "sparkle",
  "update_feed_command": "scripts/appcast.sh",
  "update_archive_dir": "release/appcast",
  "update_artifact_glob": "*.dmg,*.sha256",
  "release_assets": "release/appcast/appcast.xml,release/appcast/*.delta",
  "delta_strategy": "always"
}
```

Skill repository (version files):

```json
{
  "version_files": [
    "release/VERSION",
    "release/SKILL.md:frontmatter",
    ".claude-plugin/plugin.json:json"
  ]
}
```
