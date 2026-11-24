# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 4.3.x | ✅ |
| < 4.3 | ❌ |

## Reporting a vulnerability

Use GitHub's private vulnerability reporting:

<https://github.com/blackkcold/release-skill/security/advisories/new>

Do not open a public issue for a vulnerability. Include the command, the configuration (redacted), the observed behavior, and the version from `release.sh version`.

## Security model

- **No stored credentials.** The skill uses the `gh` CLI for authentication. Tokens are never written to `.release.json`, the global config, or the state file.
- **State stays outside the repository.** The state file records versions, tags, hashes and timestamps only.
- **No history rewrite.** The skill never force-pushes and never rewrites commits. Rollback deletes a Release and a tag; it does not delete commits.
- **Rollback guards.** A rollback is refused outside the 24h window or above the download threshold unless the operator passes `--force`.
- **Tag protection.** The repository's `v*` ruleset blocks tag updates and non-fast-forward moves.
- **Explicit commands only.** `build_command`, `update_feed_command` and `release_assets` are trusted project configuration. Review them like any other build script.
- **No silent downgrade.** A full package instead of a delta is always reported with a reason.

## Recommended repository settings

- Squash-only merges, auto-merge enabled, delete branch on merge.
- `main` requires a PR, the `ci` check, linear history, resolved conversations; force push and deletion disabled; rules apply to admins.
- A `v*` tag ruleset blocks updates and non-fast-forward moves.
- Actions default token is read-only; the release workflow requests `contents: write` explicitly.
- Dependabot alerts and private vulnerability reporting enabled.
