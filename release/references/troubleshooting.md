# Troubleshooting

## Doctor

```bash
bash scripts/release.sh doctor
```

Checks: git repository, `origin`, provider auth, config schema, `git` / `python3` / `bash`, target branch, worktree, disk, state directory, version sync.

Every failure prints a `fix:` line. Run `doctor --json` for machine-readable output.

## Exit codes

| Code | Meaning | Next step |
|---|---|---|
| 0 | success | — |
| 10 | configuration | fix JSON / provider / missing dependency |
| 11 | preflight | branch, clean gate, lock, auth |
| 12 | plan / version | adjust version or baseline |
| 13 | build / feed / delta | read log, then `resume` |
| 14 | publish | check PR, push, Release, network |
| 15 | verify | compare tag / assets / feed |
| 20 | aborted | re-run after confirming |

## Resume

State is stored outside the repository:

```
${XDG_STATE_HOME:-~/.local/state}/release-skill/<repo-id>.json
```

When a stage fails, the state records `failedStage` and the exit code.

```bash
bash scripts/release.sh resume --yes
```

Completed stages are skipped. Idempotent operations (tag, Release, asset upload) are safe to repeat.

To discard state and start over:

```bash
bash scripts/release.sh run --yes --restart
```

## Lock

A second release in the same repository fails with `另一个发版进程正在运行`. If the process is gone, remove:

```
${XDG_STATE_HOME:-~/.local/state}/release-skill/<repo-id>.json.lock
```

Stale locks older than `lock_timeout_hours` are cleaned automatically.

## Clean gate fails

The gate ignores paths in `ignore_dirty` (default: `.release.json`, `release.config.json`, `.DS_Store`, `tmp/`, `*.log`). Anything else must be committed or ignored.

Options:

1. include it in the release commit (add to the dirty list),
2. add it to `ignore_dirty`,
3. handle it manually, then re-run.

Build artifacts must land in a gitignored directory (`release/*/`, `dist/`, `update_archive_dir`).

## Version validation fails

```bash
bash scripts/validate-version.sh v1.4.0 v1.3.2 --target stable
```

- stable must be greater than the latest stable tag,
- dev must increase `N` on the same base, or use a higher base,
- stable may equal the dev base (prerelease → formal).

## Feed has no version

`check-update-delta.sh` reports `FEED_HAS_VERSION=false` when the feed does not mention the released version. Usually the feed command did not receive `RELEASE_VERSION` or wrote to a different file. Set `update_feed_file` explicitly.

## Full package instead of delta

Check, in order:

1. `seed-update-artifacts.sh --previous <tag>` → `DELTA_READY`
2. `update_feed_command` writes the feed after seeding
3. `update_archive_dir` contains `*.delta` / `*.blockmap`
4. `delta_strategy` is not `off`

`auto` allows a full package; `always` stops. The report always states the reason.

## Rollback

```bash
bash scripts/release.sh rollback --version v1.4.0 --yes
```

Guards: within `rollback_window_hours` (24h) and downloads ≤ `rollback_max_downloads` (10). Use `--force` only after confirming the risk.

Rollback deletes the Release and the tag. It does not rewrite history or delete commits.

If a tag ruleset blocks deletion, an administrator must adjust the ruleset or delete the tag manually.
