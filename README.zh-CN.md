# Release Skill

[![CI](https://github.com/blackkcold/release-skill/actions/workflows/ci.yml/badge.svg)](https://github.com/blackkcold/release-skill/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/blackkcold/release-skill)](https://github.com/blackkcold/release-skill/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Agent Skills 2.0](https://img.shields.io/badge/Agent%20Skills-2.0-blue)](https://agentskills.io)
[![OpenCode](https://img.shields.io/badge/OpenCode-ready-green)](https://opencode.ai)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-ready-purple)](https://code.claude.com)
[![Version](https://img.shields.io/badge/version-4.3.0-blue)](CHANGELOG.md)

面向 AI 编码 Agent 的通用发版技能。一个状态机串起：变更分析、语义化版本、CHANGELOG、提交、构建、自更新 feed 与差分、annotated tag、GitHub Release、验证与回滚。

兼容 OpenCode、Claude Code、Codex、Gemini CLI，以及任何能执行 shell 的 Agent。

## 它解决什么

- **先计划** — 分析提交、建议 bump、列出脏文件、构建命令、更新包预期。
- **两次闸门** — Gate 1 确认计划，Gate 2 确认不可逆动作；其余阶段不打断。
- **一次提交** — 本版所有内容合并为一个 `release:` 提交，不用 `git add -A`。
- **双轨** — develop 预发布（`vX.Y.Z-dev.N`）与 main 稳定版；stable 只接收已验收的 `cherry-pick -x`。
- **差分优先** — 构建前先把上一版产物就位；退回完整包必须写明原因。
- **可续跑** — 状态文件在仓库外，阶段跟踪 + 目录锁 + 幂等 tag/Release/资产。
- **可验证** — 发版后检查 tag 指向、资产 sha256、feed 版本、差分存在性。

## 安装

```bash
git clone https://github.com/blackkcold/release-skill.git
cd release-skill
./install.sh                 # OpenCode（默认）
./install.sh --host claude   # Claude Code
./install.sh --host codex    # Codex
./install.sh --dir ~/.config/opencode/skills/release
```

安装器会把 `release/` 复制到宿主技能目录，并把旧安装备份到 `${XDG_CONFIG_HOME:-~/.config}/opencode/backups/release/<timestamp>/`。

Claude Code 插件市场：

```bash
/plugin marketplace add blackkcold/release-skill
/plugin install release@blackkcold-release-skill
```

## 命令

```bash
bash <skill>/scripts/release.sh doctor
bash <skill>/scripts/release.sh plan --json
bash <skill>/scripts/release.sh run --yes
bash <skill>/scripts/release.sh resume --yes
bash <skill>/scripts/release.sh verify
bash <skill>/scripts/release.sh rollback --version v1.4.0 --yes
bash <skill>/scripts/release.sh version
```

| 命令 | 作用 |
|---|---|
| `doctor` | git / remote / provider 认证 / 配置 / 依赖 / 磁盘 / 分支 / 版本同步 |
| `plan` | 只读计划；`--json` 供 Agent 渲染计划页 |
| `run` | 执行；Gate 1 + Gate 2 确认后加 `--yes` |
| `resume` | 从最后一个未完成阶段继续 |
| `verify` | tag、资产、sha256、feed、差分 |
| `rollback` | 删除 Release 与 tag；24h / 下载量保护 |
| `version` | skill 版本 |

退出码：`0` 成功、`10` 配置、`11` 预检、`12` 计划/版本、`13` 构建/feed/差分、`14` 发布、`15` 验证、`20` 中止。

## 计划示例

```
📋 发版计划
  目标:     stable (main)
  版本:     v1.3.2 → v1.4.0 (minor)
  变更:     12 提交 + 2 个未提交文件
  构建:     swift build -c release
  更新包:   sparkle；上一版产物可获取，预期差分
  Release:  MyApp v1.4.0 / structured-cn / 正式 Release
  Provider: github (owner/repo)
  配置:     .release.json
```

## 报告示例

```
📋 发版报告
  ✅ 版本:   v1.4.0 (正式 Release)
  ✅ 目标:   stable (main)
  ✅ Release: https://github.com/owner/repo/releases/tag/v1.4.0
  ✅ 更新包: 差分 1 个（sparkle，0.9MB / 完整包 10.2MB）
  ✅ 收尾:   工作区干净
```

## 架构

```
Core        版本、文档、提交、tag、状态、验证、报告
Provider    github | none（gitlab 只留契约，未实现）
Build       Swift / Node / Rust / Go / Python / Make / Gradle / Flutter / Elixir / custom
Feed        none | sparkle | electron | tauri | custom
Notes       auto | simple | bilingual | changelog | structured-cn
Host        opencode | claude | codex | gemini | cli
Config      .release.json → release.config.json → XDG 全局 → 旧路径 → 默认
```

`SKILL.md` 是操作手册（219 行），细节在 `release/references/`：

- `config.md` — 全部字段与默认值
- `adapters.md` — provider / build / feed / notes / host 契约
- `delta.md` — seed、check、Sparkle / Electron
- `troubleshooting.md` — doctor、退出码、resume、rollback
- `migration.md` — v4.2.0 → v4.3.0

## 差分更新

构建产物通常被 gitignore，新 worktree 或 CI job 默认没有上一版产物；feed 生成器不会报错，只会静默退回完整包。

```bash
bash release/scripts/seed-update-artifacts.sh --previous v1.3.2
RELEASE_VERSION=v1.4.0 bash scripts/appcast.sh
bash release/scripts/check-update-delta.sh --version v1.4.0 --feed release/appcast/appcast.xml
```

- `delta_strategy: auto`：允许完整包，但计划与报告必须写明原因。
- `delta_strategy: always`：没有差分就在推 tag 前停止。

## PR 流程

`pr_flow: auto`：存在 `.github/workflows` 时要求 PR。发布分支 `release/vX.Y.Z`，CI 通过后 squash 合并，再在合并后的 HEAD 打 tag。冲突停止并给摘要。

## 配置

最小 `.release.json`：

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

完整说明见 [release/references/config.md](release/references/config.md)。

## 开发

```bash
bash tests/run.sh
bash scripts/check-version-sync.sh
```

测试使用 fixture 仓库与 `gh` stub，不访问网络。

## 变更记录

见 [CHANGELOG.md](CHANGELOG.md)。

## 安全

见 [SECURITY.md](SECURITY.md)。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## License

MIT
