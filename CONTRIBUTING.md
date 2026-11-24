# Contributing

## Setup

```bash
git clone https://github.com/blackkcold/release-skill.git
cd release-skill
bash tests/run.sh
bash scripts/check-version-sync.sh
```

Requirements: `git`, `bash`, `python3`, `jq` (optional), `zip` (distribution build), `gh` (GitHub provider only). macOS ships bash 3.2; keep scripts compatible with it.

## Tests

```bash
bash tests/run.sh          # fixtures + gh stub, no network
bash -n release/scripts/*.sh
shellcheck -S error release/scripts/*.sh release/scripts/lib/*.sh
```

The suite covers:

- shell syntax and `--help`
- version validation and version-source sync
- project detection (Swift, Node, plain, Flutter, Elixir)
- single-track and dual-track plans
- config precedence
- provider `none` end-to-end
- build failure → `resume`
- delta detection (Sparkle / Electron)
- provider `github` end-to-end with a `gh` stub, `verify` and `rollback`

Add a fixture under `tests/fixtures/` and a case in `tests/run.sh` for every behavior change.

## Adding an adapter

1. Add the enum value to `release/config/schema.json` and `default.json`.
2. Implement the contract in `release/scripts/lib/<adapter>.sh` (see `references/adapters.md`).
3. Extend the dispatch function.
4. Add a test.
5. Update `references/adapters.md`; update `SKILL.md` only when user-facing behavior changes.

## Version source

`release/VERSION` is authoritative. The same version must appear in:

- `release/VERSION`
- `release/SKILL.md` → `metadata.version`
- `.claude-plugin/plugin.json` → `version`
- `CHANGELOG.md` top version heading

`scripts/check-version-sync.sh` fails CI when they disagree.

## Commits and PRs

- Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `ci:`, `chore:`); `!` or `BREAKING CHANGE` for breaking changes.
- One logical change per PR. All changes go through a PR; `main` is protected.
- The PR must pass `ci` (lint, tests on Ubuntu + macOS, version sync).
- Do not commit `dist/` or state files.

## Release

Releases are created by the skill itself:

```bash
bash release/scripts/release.sh plan --json
bash release/scripts/release.sh run --yes
```

The tag triggers `.github/workflows/release.yml`, which builds `release-skill-vX.Y.Z.zip` and attaches it (with `.sha256`) to the Release.
