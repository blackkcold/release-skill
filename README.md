# Release Skill

[![CI](https://github.com/blackkcold/release-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/blackkcold/release-skill/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/blackkcold/release-skill)](https://github.com/blackkcold/release-skill/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Agent Skills 2.0](https://img.shields.io/badge/Agent%20Skills-2.0-blue)](https://agentskills.io)
[![OpenCode](https://img.shields.io/badge/OpenCode-ready-green)](https://opencode.ai)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-ready-purple)](https://code.claude.com)
[![Version](https://img.shields.io/badge/version-4.3.0-blue)](CHANGELOG.md)

Universal release automation for AI coding agents. One state machine for version analysis, CHANGELOG, commit, build, self-update feed and deltas, annotation tag, GitHub Release, verification and rollback.

Works with OpenCode, Claude Code, Codex, Gemini CLI, and any agent that can run shell commands.

## What it does

- **Plan first** — analyze commits, suggest a semver bump, list dirty files, build command, update-package expectation.
- **Two gates** — Gate 1 confirms the plan; Gate 2 confirms irreversible actions. Nothing else interrupts.
- **One commit** — all release content becomes a single `release:` commit; no `git add -A`.
- **Dual-track** — develop prereleases (`vX.Y.Z-dev.N`) and stable releases; stable only receives reviewed `cherry-pick -x` commits.
- **Delta-aware** — the previous artifact is staged before the build; a full package is allowed only when the reason is reported.
- **Resumable** — state outside the repo, stage tracking, directory lock, idempotent tag/Release/assets.
- **Verifiable** — tag target, asset sha256, feed version and delta presence are checked after publishing.

## Install

### Claude Code plugin marketplace

```bash
/plugin marketplace add blackkcold/release-skill
/plugin install release@blackkcold-release-skill
```

### Manual (any agent)

```bash
git clone https://github.com/blackkcold/release-skill.git
cd release-skill
./install.sh                 # OpenCode (default)
./install.sh --host claude   # Claude Code
./install.sh --host codex    # Codex
./install.sh --dir ~/.config/opencode/skills/release
```

The installer copies `release/` into the host skills directory and backs up an existing install under `${XDG_CONFIG_HOME:-~/.config}/opencode/backups/release/<timestamp>/`.

### Other tools

Copy the `release/` directory to the tool's skills directory. The entry point is `release/SKILL.md`.

## Commands

```bash
bash <skill>/scripts/release.sh doctor
bash <skill>/scripts/release.sh plan --json
bash <skill>/scripts/release.sh run --yes
bash <skill>/scripts/release.sh resume --yes
bash <skill>/scripts/release.sh verify
bash <skill>/scripts/release.sh rollback --version v1.4.0 --yes
bash <skill>/scripts/release.sh version
```

| Command | Purpose |
|---|---|
| `doctor` | git, remote, provider auth, config, dependencies, disk, branch, version sync |
| `plan` | read-only plan; `--json` for an agent-rendered page |
| `run` | execute; requires `--yes` after Gate 1 + Gate 2 |
| `resume` | continue from the last unfinished stage |
| `verify` | tag, assets, sha256, feed, delta |
| `rollback` | delete Release and tag; 24h / download guards |
| `version` | skill version |

Exit codes: `0` ok, `10` config, `11` preflight, `12` plan/version, `13` build/feed/delta, `14` publish, `15` verify, `20` aborted.

## Example plan

```
📋 发版计划
  目标:     stable (main)
  版本:     v1.3.2 → v1.4.0 (minor)
  变更:     12 提交 + 2 个未提交文件
  构建:     swift build -c release
  更新包:   sparkle；上一版产物可获取，预期差分
  Release:  MyApp v1.4.0 / structured-cn / 正式 Release
  Provider: github (owner/repo)
  Host:     opencode
  配置:     .release.json
  文档:     CHANGELOG.md README.md
```

## Example report

```
📋 发版报告
  ✅ 版本:   v1.4.0 (正式 Release)
  ✅ 目标:   stable (main)
  ✅ Release: https://github.com/owner/repo/releases/tag/v1.4.0
  ✅ 更新包: 差分 1 个（sparkle，0.9MB / 完整包 10.2MB）
  ✅ 收尾:   工作区干净
  📄 报告:   ~/.local/state/release-skill/<repo-id>-report.json
```

## Architecture

```
Core        version, docs, commit, tag, state, verify, report
Provider    github | none (gitlab is a declared, unimplemented contract)
Build       Swift, Node, Rust, Go, Python, Make, Gradle, Flutter, Elixir, custom
Feed        none | sparkle | electron | tauri | custom
Notes       auto | simple | bilingual | changelog | structured-cn
Host        opencode | claude | codex | gemini | cli
Config      .release.json → release.config.json → XDG global → legacy → defaults
```

`SKILL.md` is the operator guide (219 lines). Details live in `release/references/`:

- `config.md` — every field and default
- `adapters.md` — provider/build/feed/notes/host contracts
- `delta.md` — seeding, checking, Sparkle/Electron
- `troubleshooting.md` — doctor, exit codes, resume, rollback
- `migration.md` — v4.2.0 → v4.3.0

## Delta updates

Build outputs are usually gitignored, so a new worktree or CI job starts without the previous artifact. Feed generators then silently fall back to a full package.

```bash
bash release/scripts/seed-update-artifacts.sh --previous v1.3.2
RELEASE_VERSION=v1.4.0 bash scripts/appcast.sh
bash release/scripts/check-update-delta.sh --version v1.4.0 --feed release/appcast/appcast.xml
```

- `delta_strategy: auto` allows a full package but reports the reason in the plan and report.
- `delta_strategy: always` stops before pushing the tag when no delta exists.

## PR flow

`pr_flow: auto` requires a PR when `.github/workflows` exists. The release branch is `release/vX.Y.Z`; CI must pass; the PR is squash-merged; the tag is created on the merged HEAD. Conflicts stop the release with a summary.

## Configuration

Minimal `.release.json`:

```json
{
  "schemaVersion": 1,
  "provider": "auto",
  "branch_model": "auto",
  "stable_branch": "main",
  "dev_branch": "develop",
  "update_feed": "auto",
  "notes_style": "auto",
  "delta_strategy": "auto"
}
```

See [release/references/config.md](release/references/config.md).

## Development

```bash
bash tests/run.sh
bash scripts/check-version-sync.sh
```

The suite uses fixture repositories and a `gh` stub; it never touches the network.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Security

See [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
