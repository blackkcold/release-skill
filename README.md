# Release Skill — Universal Release Automation for AI Coding Agents

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-2.0-blue)](https://agentskills.io)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-ready-purple)](https://code.claude.com)
[![OpenCode](https://img.shields.io/badge/OpenCode-ready-green)](https://opencode.ai)

Automate your entire release workflow — version bump, CHANGELOG update, tag, build, and GitHub Release — with a single command. Works with any agentskills.io-compatible AI coding agent.

## What It Does

- **Auto-detect project type**: Swift, Node.js, Rust, Go, Python, Make, Gradle, Flutter, Elixir
- **Smart CHANGELOG update**: Convert `[Unreleased]` → `[vX.Y.Z] - YYYY-MM-DD`, add new Unreleased section
- **Intelligent Release Notes**: Auto-detect historical format (bilingual/simple/changelog/structured-cn)
- **Consistency-first**: Release title, format, and structure inferred from history, not hardcoded
- **Annotated tags**: Create and push `vX.Y.Z` tags
- **Optional release branch**: Create `release/vX.Y.Z` branch
- **Local build**: Execute project build command before release
- **GitHub Release**: Create release with `gh release create`
- **CI/CD mode**: Local, CI, or auto-detect

## Quick Install

### Claude Code

```bash
# Via Plugin Marketplace (recommended)
/plugin marketplace add blackkcold/release-skill
/plugin install release@blackkcold-release-skill

# Or manual install
mkdir -p ~/.claude/skills/release
cp -r release/* ~/.claude/skills/release/
```

### OpenCode

```bash
mkdir -p ~/.config/opencode/skills/release
cp -r release/* ~/.config/opencode/skills/release/
```

### Other Tools

Copy the `release/` folder to the tool's skills directory. All agentskills.io-compatible tools use the same SKILL.md format.

## Usage

Invoke by mentioning any trigger phrase:

- "发版" / "release" / "发布"
- "bump version" / "publish"
- "create release vX.Y.Z"

Or use the slash command: `/release`

### Examples

```bash
# Basic release (auto-increment PATCH)
/release

# Specify version
/release v0.9.2

# With summary
/release v0.9.2 backup management bug fix

# Dry run
/release v0.9.2 --dry-run

# Force config format (skip historical consistency check)
/release v0.9.2 --force-config
```

## Repository Structure

```
release-skill/
├── release/
│   ├── SKILL.md              # The skill definition
│   ├── README.md             # Skill usage documentation
│   ├── config/
│   │   └── projects.json     # Example project configurations
│   ├── scripts/
│   │   ├── detect-project.sh  # Project type detection
│   │   ├── generate-notes.sh # Release note generation
│   │   └── validate-version.sh # Version validation
│   └── templates/
│       ├── changelog-entry.md
│       ├── release-note-bilingual.md
│       └── release-note.md
├── .claude-plugin/
│   └── plugin.json           # Claude Code Plugin Marketplace config
├── LICENSE                   # MIT
└── README.md                 # This file
```

## Supported Project Types

| Project File | Build Command |
|---|---|
| `Package.swift` | `swift build -c release` |
| `package.json` + `build` script | `npm run build` |
| `Cargo.toml` | `cargo build --release` |
| `go.mod` | `go build -o ./release/` |
| `pyproject.toml` | `python -m build` |
| `Makefile` + `build` target | `make build` |
| `build.gradle` / `build.gradle.kts` | `./gradlew build` |
| `pubspec.yaml` | `flutter build` |
| `mix.exs` | `mix release` |

## Release Note Styles

| Style | Description | Detection Signal |
|---|---|---|
| `bilingual` | Chinese/English bilingual format | CJK >50 + Latin >100 chars |
| `simple` | Single-language format | Default fallback |
| `changelog` | Raw CHANGELOG entry dump | Body starts with `## [v` |
| `structured-cn` | Chinese emoji-grouped format | Contains 🐛/✨/🔧 emoji headings |

## Configuration

Create `.release.json` in your project root:

```json
{
  "repo": "owner/repo",
  "tag_prefix": "v",
  "build_command": "npm run build",
  "docs": ["CHANGELOG.md", "README.md"],
  "release_note_style": "auto",
  "ci_mode": "local",
  "release_branch": true
}
```

## License

MIT — see [LICENSE](LICENSE).

## Contributing

PRs welcome! Submit to this repository or to [anthropics/skills](https://github.com/anthropics/skills).
