---
name: release
description: 通用发版助手：分析变更、判定语义化版本、更新 CHANGELOG、提交、构建、生成自更新 feed 与差分、打 tag、创建 GitHub Release，支持 develop 预发布 / main 稳定双轨、失败续跑与回滚。触发词：发版、发布、release、bump version、版本号、大版本、重大更新、发版 vX.Y.Z、同步 main、差分更新、增量更新、appcast、blockmap。
license: MIT
compatibility: opencode, claude-code, codex, gemini-cli, macOS, Linux
metadata:
  version: "4.3.0"
  author: blackkcold
  repository: https://github.com/blackkcold/release-skill
  tags: "release, versioning, git, github, ci-cd, automation, delta-update"
---
# Release — 通用发版助手

发版是低频、高后果、顺序敏感的操作。本 skill 把「分析 → 计划 → 文档 → 提交 → 构建 → feed → tag → Release → 验证」做成可续跑的状态机，最多两次确认。

## 何时使用

- 中文：发版、发布、准备发版、更新版本、发版 vX.Y.Z、大版本、重大更新、同步 main
- English：release, bump version, publish, create release
- 自更新：差分更新、增量更新、appcast、blockmap

## 核心原则

1. **一致性** — Release Note 的标题、格式、分组跟随最近历史 Release；配置只是 fallback。
2. **一次提交** — 本版所有内容（含发版前已存在的脏文件）合并为一个 `release:` 提交，不用 `git add -A`。
3. **两次闸门** — Gate 1 确认计划，Gate 2 确认不可逆动作；其余阶段不打断。
4. **发版后必须干净** — 提交后与收尾时 `git status` 都要干净（排除 `ignore_dirty`）。
5. **双轨不混** — 有 dev 线时默认发 develop；进入 main 只允许已验收提交 `cherry-pick -x`，禁止整支合并。
6. **差分优先** — 构建前先让上一版产物就位；退回完整包可以，但必须写明原因，不许静默降级。
7. **单一版本源** — `release/VERSION` 是权威版本；`metadata.version`、plugin.json、CHANGELOG、tag 必须一致。


## 入口

所有命令都在项目根目录执行：

```bash
bash <skill>/scripts/release.sh <command> [options]
```

| 命令 | 作用 |
|---|---|
| `doctor` | git / remote / provider 认证 / 配置 / 依赖 / 磁盘 / 分支 / 版本同步 |
| `plan` | 只读分析，输出计划；`--json` 供 Agent 渲染计划页 |
| `run` | 执行；Agent 在 Gate 1 + Gate 2 确认后调用 `run --yes` |
| `resume` | 从最后一个未完成阶段继续 |
| `verify` | 校验 tag、资产 sha256、feed 版本、差分 |
| `rollback` | 删除 Release 与 tag（24h / 下载量保护） |
| `version` | 打印 skill 版本 |

常用选项：`--version vX.Y.Z`、`--target auto|develop|stable`、`--repo-dir`、`--json`、`--dry-run`、`--yes`、`--force`、`--update`、`--skip-build`、`--skip-release`、`--through`。

退出码：`0` 成功、`10` 配置、`11` 预检、`12` 计划/版本、`13` 构建/差分、`14` 发布、`15` 验证、`20` 中止。


## 工作流

```
Phase 0  doctor                  环境一次查完；失败给可执行修复命令
Phase 1  plan                    变更分类、版本建议、目标线、构建、更新包预期
Gate 1   🔒 计划确认             唯一计划页：目标、版本、待提交文件、构建、差分预期
Phase 2  docs + commit           CHANGELOG / 版本文件；一次 release 提交
Phase 3  clean gate              排除 ignore_dirty 后工作区必须为空
Gate 2   🔒 不可逆确认           推送、tag、构建、feed、Release、资产一次打包
Phase 4  seed → build → feed     上一版产物先就位，再构建、生成 feed
Phase 5  delta                   差分判定；always 无差分即停
Phase 6  PR merge（可选）        先合并 PR，再在目标线 HEAD 打 tag
Phase 7  tag → push → Release    本地 tag 先建；差分通过后才推
Phase 8  verify → report         tag 指向、资产 sha256、feed、差分逐项打勾
Phase 9  resume / rollback       失败续跑；高风险回滚有保护
```

### Gate 1 — 计划页

Agent 调用 `release.sh plan --json`，渲染：

- 目标线（develop / stable）与分支
- 上一版 → 本次版本，bump 理由（BREAKING / feat / 其余）
- 提交数、待提交文件（逐条）、`ignore_dirty` 排除项
- 构建命令、feed 类型、差分预期或完整包原因
- PR 流程、Release 标题与格式

确认后调用 `release.sh run --yes`；未确认时 CLI 只打印计划并退出。

### Gate 2 — 不可逆动作

`run` 内部按顺序执行；`delta_strategy=always` 时 seed 不通过会在构建前停止：

1. seed 上一版产物（本地 → 主 checkout → GitHub 资产）
2. 构建
3. 生成 feed
4. 差分判定
5. 工作区干净复核
6. 推送 tag
7. 创建 Release 并上传 feed / 差分 / 额外资产


## 配置

优先级（后者覆盖前者）：

1. `release/config/default.json`（内置）
2. `~/.config/opencode/release.json`（旧路径，仍读取，打印弃用提示）
3. `${XDG_CONFIG_HOME:-~/.config}/release-skill/config.json`
4. 项目 `release.config.json`
5. 项目 `.release.json`

最小配置：

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

完整字段、默认值、兼容字段见 `references/config.md`；适配器契约见 `references/adapters.md`。

### 目标线

- `branch_model: auto`：只有「dev 分支存在」且「有 dev tag 或显式 target_branch」才走双轨；普通仓库默认单轨。
- 显式 `--target develop|stable` 覆盖配置。
- stable 版本独立判定，不继承 dev 版本号。

### 版本判定

`BREAKING_COUNT > 0` → major；`FEAT_COUNT > 0` → minor；其余 → patch。
非 Conventional 前缀不猜语义，统一 patch。显式 `--version` 优先。


## 适配器

| 层 | 可替换点 | v4.3 |
|---|---|---|
| Provider | Release / PR / 认证 / 资产 | `github`、`none`；`gitlab` 明确报未实现 |
| Build | 项目类型与命令 | Swift / Node / Rust / Go / Python / Make / Gradle / Flutter / Elixir / custom |
| Feed | 自更新 feed 与差分 | `none` / `sparkle` / `electron` / `tauri` / `custom` |
| Notes | Release Note 格式 | `auto` / `simple` / `bilingual` / `changelog` / `structured-cn` |
| Host | 渲染与提问 | Agent 渲染计划页；CLI 文本；CI 用 `--yes` |

新增适配器只改对应 lib，不改主流程。


## 差分更新（关键）

上一版产物通常被 gitignore，新 worktree / 新 CI job / 另一台机器默认没有它。feed 生成器不会报错，只会静默退回完整包。

```bash
# 1. 取上一版产物（只读；落点必须被 gitignore）
bash scripts/seed-update-artifacts.sh --previous vX.Y.(Z-1)

# 2. 生成 feed（项目命令）
RELEASE_VERSION=vX.Y.Z bash scripts/appcast.sh

# 3. 判定
bash scripts/check-update-delta.sh --version vX.Y.Z --feed <feed> --archive <dir>
```

- `delta_strategy=auto`：允许完整包，但计划页与报告必须写明原因。
- `delta_strategy=always`：没有差分就停止，远端不会留下指向未发布版本的 tag。
- 资产必须带 sha256；下载中断的截断文件会被丢弃。

详见 `references/delta.md`。


## 状态、续跑与回滚

状态文件：`${XDG_STATE_HOME:-~/.local/state}/release-skill/<repo-id>.json`

```bash
release.sh run --yes        # 失败后状态保留
release.sh resume --yes     # 从失败阶段继续
release.sh verify           # 校验 tag / 资产 / feed / 差分
release.sh rollback --yes   # 24h 内且下载量低于阈值才允许
```

幂等：tag 已存在且指向 HEAD 则跳过；Release 已存在只允许 `--update` 更新说明；资产 sha256 一致则跳过。


## PR 流程

- `pr_flow: auto`：有 `.github/workflows` 视为需要 PR；`always` 强制；`never` 直接在当前分支。
- 场景 A：`release/vX.Y.Z → 目标线`，CI 通过且无冲突自动 squash 合并；有冲突停止并给摘要。
- 场景 B：发版后只输出可清理清单，不自动删除。
- 合并后 checkout 目标线、pull、在 HEAD 打 tag。


## 错误处理

| 场景 | 处理 |
|---|---|
| 无变更 | 停止，提示无需发版 |
| 版本格式 / 未递增 | `validate-version.sh` 报错，给正确格式 |
| 工作区不干净 | 停止，列文件，三选项：并入 / ignore_dirty / 手动处理 |
| 构建失败 | 保留状态，`resume` 续跑；不改源码 |
| 上一版产物取不到 | 明确报完整包与原因；`always` 时停止 |
| feed 无本版版本号 | 停止，检查 feed 命令与版本注入 |
| Release 失败 | 给原因与手动兜底命令；状态可续跑 |
| PR 冲突 / CI 失败 | 展示摘要与诊断；需改源码则停 |
| 回滚超窗 / 下载量高 | 默认拒绝，确认风险后 `--force` |


## 参考文件（按需加载）

- `references/config.md` — 全部字段、默认值、配置优先级、兼容字段
- `references/adapters.md` — provider / build / feed / notes / host 契约与扩展方式
- `references/delta.md` — 差分产物、校验、Sparkle / Electron 细节
- `references/troubleshooting.md` — doctor 检查项、退出码、resume / rollback
- `references/migration.md` — v4.2.0 → v4.3.0 迁移与兼容

## 输出

优先渲染「发版计划页」与「发版报告页」；文本只留结论。报告含：两条线结果、tag/Release 链接、差分数量与节省比例（或完整包原因）、cherry-pick 清单、可清理项。
