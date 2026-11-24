# Delta Updates

A differential update needs the previous build on disk. Build outputs are usually gitignored, so a fresh worktree, a new CI job or another machine starts without them. Feed generators do not fail in that case; they silently publish a full package. This skill makes that outcome visible.

## Order

1. **Seed** the previous artifacts (`seed-update-artifacts.sh`).
2. **Build** the new version.
3. **Generate** the feed (`update_feed_command`).
4. **Check** that a delta exists (`check-update-delta.sh`).
5. **Upload** the feed and delta assets with the Release.

Seeding must happen **before** the build. The feed tool reads the previous artifact while generating the delta.

## Seeding

```bash
bash scripts/seed-update-artifacts.sh --previous v1.3.2
```

Resolution order:

1. `update_previous_dir` / `release/<previous>/` already has a matching artifact → `STAGED_FROM=local`
2. `--source-dir` (main checkout or another worktree) → copy
3. GitHub Release assets of the previous tag → `gh release download`

Outputs: `PREV_TAG`, `REPO`, `TARGET_DIR`, `STAGED_FROM`, `STAGED_FILES`, `DELTA_READY`.

If the publisher shipped `<artifact>.sha256`, the checksum is verified. A truncated download is deleted and treated as unavailable.

## Checking

```bash
bash scripts/check-update-delta.sh --version v1.4.0 --feed release/appcast/appcast.xml --archive release/appcast
```

| Ecosystem | Evidence |
|---|---|
| Sparkle | `deltaFrom` in the feed, or `*.delta` in the archive |
| electron-builder | `*.blockmap` in the archive |
| Other | the project command decides; the script only reports `DELTA_READY` |

`--archive` defaults to the feed's directory. Set `update_archive_dir` when deltas live elsewhere.

## Strategies

| `delta_strategy` | Behavior |
|---|---|
| `auto` | Try for a delta. A full package is allowed, but Gate 2 and the report must state the reason. |
| `always` | No delta → stop before pushing the tag. |
| `off` | Do not seed, generate or check. |

Never silently downgrade. `auto` still prints `完整包（原因）` in the plan and `verify` reports it.

## Assets

`feed_collect_assets` gathers:

- the feed file
- `*.delta` and `*.blockmap` in `update_archive_dir`
- build artifacts in `update_archive_dir`
- explicit `release_assets` globs

Assets are uploaded with `gh release upload --clobber`; `verify` compares local sha256 with the GitHub asset digest when available.

## Sparkle

- Feed: `appcast.xml` with `sparkle:deltaFrom` entries.
- Deltas: `*.delta` produced by `generate_appcast` / `BinaryDelta`.
- `delta_max` is passed to the feed tool; keep it small (default 2).

## Electron

- Feed: `latest*.yml` written by electron-builder.
- Deltas: `*.blockmap` next to the artifacts.
- `update_feed_command` is usually the publish step; set it explicitly when the build does not publish.

## Tauri

Tauri v2 has no binary delta. Use `update_feed: tauri` (or `none`) and upload the signed feed only. `verify` will not require a delta.
