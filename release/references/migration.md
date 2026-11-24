# Migration: v4.2.0 → v4.3.0

v4.3 keeps the v4.2 workflow and scripts, but separates core from adapters and moves configuration to XDG paths.

## What changed

| Area | v4.2 | v4.3 |
|---|---|---|
| Entry | instructions only | `scripts/release.sh doctor/plan/run/resume/verify/rollback/version` |
| Config | `~/.config/opencode/release.json` | XDG path, legacy path still read |
| Provider | GitHub hardcoded | `github` / `none`; `gitlab` fails loudly |
| Branch model | `develop` existence implies dual | `branch_model: auto/single/dual`; auto needs a dev tag or explicit config |
| Feed | detection in the main flow | `update_feed` adapter; default `none` |
| Notes | `release_note_style` | `notes_style`; old key still read |
| Frontmatter | top-level `version` / `author` / `tags` / `dependencies` | agentskills.io fields; version under `metadata` |
| State | none | XDG state file + lock + resume |
| Tests | none | fixtures + gh stub + two-platform CI |

## Configuration mapping

Old keys keep working:

- `release_note_style` → `notes_style` (used when `notes_style=auto`)
- `target_branch` → still read; `branch_model` is the new switch
- `auto_merge` → `pr_flow`
- `update_feed` / `update_feed_command` → unchanged
- `delta_strategy` / `delta_max` → unchanged
- `ignore_dirty` → unchanged

New keys are optional. A v4.2 `.release.json` runs without edits.

## Install path

The skill is installed as a copy, not edited in place:

```bash
# OpenCode (default)
./install.sh

# Claude Code
./install.sh --host claude

# explicit directory
./install.sh --dir ~/.config/opencode/skills/release
```

Existing files are backed up to:

```
${XDG_CONFIG_HOME:-~/.config}/opencode/backups/release/<timestamp>/
```

`.bak-*` files from the old manual workflow are moved there by the installer.

## Behavior changes

1. `branch_model: auto` no longer treats a `develop` branch alone as dual-track. Add a dev tag or set `branch_model: dual` / `target_branch: develop`.
2. `provider: auto` resolves from `origin`. Repositories without a GitHub remote become `none` and only create a local tag.
3. `run` refuses to execute without `--yes` in a non-interactive session. Agents must show Gate 1 and Gate 2 first.
4. The clean gate also excludes `release.config.json`.
5. The release commit is pushed to the target branch even without a PR; with a PR it is merged before tagging.

## Compatibility

- Script names and `release/` layout are preserved.
- Existing `.release.json` files are not rewritten.
- `.claude-plugin/plugin.json` stays compatible; only the version and description are updated.
- No history rewrite, no force push.
