---
name: release
description: 通用发版助手。用于待发变更分析、语义化版本判定、文档更新、打 tag、本地构建与创建 GitHub Release，并处理自更新 feed 与差分（增量）更新包。支持 develop 预发布 / main 稳定双轨：默认发版到 develop，发布后主动推荐可同步到 main 的已验收变更。触发词：发版、发布、release、bump version、版本号、大版本、重大更新、发版 vX.Y.Z、同步 main、差分更新、增量更新、appcast、blockmap。
version: 4.2.0
author: 杨昊燃
tags: [release, versioning, git, github, ci-cd, automation, dual-track, prerelease, delta-update, auto-update, sparkle]
dependencies: [gh, git, python3]
compatibility: [macOS, Linux]
---

# Release - 通用发版助手

自动完成语义化版本发布：分析变更 → 判定版本 → 更新文档 → 提交 → 打 tag → 推送 → 构建 → 创建 Release → PR 处理 → 同步评估（可选，develop → main）。

## When to Use

- 中文触发词："发版"、"发布"、"准备发版"、"更新版本"、"发布新版本"、"发布 vX.Y.Z"
- 英文触发词："release"、"bump version"、"create release"、"publish"
- 版本级覆盖口令："大版本"（强制 MINOR）、"重大更新"（强制 MAJOR）
- 双轨口令："发版到 main" / "正式发版" / "stable"（直接走稳定线）、"发版并同步 main"（dev 发布后预承诺同步）

## When NOT to Use

- 项目不使用 Git / 没有 GitHub remote
- 只想要一个 tag，不走完整 release 流程

## 核心原则

1. **一致性** — Release Note 的标题、格式、分组标题跟随历史 Release；`.release.json` 只是 fallback，不是覆盖。
2. **一次提交** — 本版所有内容（含发版前已存在的未提交变更）合并为一个 `release:` 提交，不用 `git add -A`。
3. **两次闸门** — 每条发布线只在 Gate 1（计划）与 Gate 2（对外操作）打断；main 同步线把「清单选择 + 对外确认」合并为一问。
4. **发版后必须干净** — 打 tag 前与收尾时 `git status` 都必须干净，否则停止。
5. **默认 develop，稳定靠 cherry-pick** — 有开发分支时默认发 develop；进入 main 只允许已验收提交 `cherry-pick -x`，**禁止整支合并** `develop → main`。
6. **差分优先** — 构建前先让上一版产物就位（本地 → 主 checkout → GitHub 资产）；退回完整包可以，但必须在计划与报告里写明原因，不许静默降级。

---

## Workflow

```
Phase 1  环境 + 双轨判定 + 变更分析
         ├── git 仓库 / remote / gh 可用性 / 配置加载
         ├── 目标线判定：默认 develop（存在时），双轨口令可覆盖
         ├── analyze-changes.sh --target <develop|stable> → 提交数、脏文件、分类、建议版本
         └── HAS_CONTENT=false → 停止，不发版
Phase 2  🔒 Gate 1 发版计划确认（渲染计划页 + 一次问全）
Phase 3  文档更新（CHANGELOG / README / 版本引用）
Phase 4  提交：一次 release commit（文档 + 起始脏文件，排忽略清单）
Phase 5  🔒 干净闸门：git status --porcelain 为空，否则停止
Phase 6  🔒 Gate 2 对外操作确认（tag + push + 构建 + 差分 + Release 一次打包）
Phase 6.5 差分准备：seed-update-artifacts.sh 让上一版产物就位
          （本地 release/<上一版> → --source-dir 主 checkout → gh release download）
          取不到就是完整包；delta_strategy=always 时此处即停
Phase 7  按序执行：构建 → 生成 feed → 差分判定 → 推送 tag → gh release create
         （走 PR 的线：先推送分支并合并 PR，再在该线 HEAD 打 tag）
Phase 8  PR 处理（场景 A 合并 / 场景 B 只出清理清单）
Phase 9  🔒 收尾：最终干净复核 + 渲染发版报告
── 双轨同步（仅 develop 线发布成功且 main_sync≠never）──
Phase S1 渲染「同步推荐页」（analyze-changes.sh --sync-candidates）
Phase S2 🔒 同步决策：question 全选 / 自选 / 跳过（跳过即结束）
Phase S3 建 sync 分支 → cherry-pick -x → PR → CI 合并 → tag vX.Y.Z → Stable Release
```

### Phase 1 — 环境与变更分析

```bash
bash scripts/analyze-changes.sh                    # 人类可读 KEY=VALUE
bash scripts/analyze-changes.sh --json             # 机器可读
bash scripts/analyze-changes.sh --base v1.2.3      # 指定基准
bash scripts/analyze-changes.sh --target develop   # 开发线（基线 = 最近 dev tag）
bash scripts/analyze-changes.sh --target stable    # 稳定线（基线 = 最近稳定 tag）
bash scripts/analyze-changes.sh --sync-candidates  # 同步候选集 JSON（已发 dev、未进 main）
```

```bash
# 环境校验
git fetch --tags origin                              # 先同步远端（dev tag 可能由 CI / 其他机器推送）
git rev-parse --git-dir                              # 必须成功
git remote get-url origin                            # 必须有 remote
gh auth status                                       # 需要创建 Release 时
```

同时按「构建命令自动检测」表推断项目类型与构建命令，并取 `detect-project.sh` 的 `UPDATE_FEED` 判断是否需要差分。

### Gate 1 — 发版计划确认（渲染计划页 + 一次问全，不再逐段打断）

```
📋 发版计划
  目标:   develop（默认双轨）→ vX.Y.Z-dev.N   [main 同步评估在发布成功后]
  版本:   v1.4.0-dev.3 → v1.4.0-dev.4
  理由:   patch —— 1 个 docs/杂项提交，无 feat、无 BREAKING
  变更:   1 提交 + 15 未提交文件（13 已跟踪 / 2 未跟踪），17 文件 +2049/-94
  待提交文件（将并入本次 release 提交）:
    M server/app.ts · M src/core/store.ts · ?? src/new.ts …（逐条列出）
  忽略:   .release.json, .DS_Store, tmp/, *.log（见 ignore_dirty）
  文档:   CHANGELOG.md, README.md
  构建:   swift build -c release
  Release: 标题「v1.4.0-dev.4」/ 格式 structured-cn（沿用历史）/ Pre-release
  PR 模式: 场景 A（release/v1.4.0-dev.4 → develop，CI 通过自动合并）

确认: 执行 / 改版本 / 取消
```

### Phase 3 — 文档更新

- CHANGELOG.md（存在时）：`## [Unreleased]` → `## [vX.Y.Z[-dev.N]] - YYYY-MM-DD`，顶部补新的 Unreleased，更新底部版本链接
- README.md（存在时）：更新版本引用，不新增徽章
- `docs` 列表中的其他文档

### Phase 4 — 提交

```bash
git add <Phase 1 列出的脏文件> <skill 修改的文档>   # 白名单，绝不 git add -A
git commit -m "release: vX.Y.Z[-dev.N] — 简要描述"
```

启用 `release_branch` 时，先 `git checkout -b release/vX.Y.Z[-dev.N]`，提交落在该分支。

### Phase 5 — 干净闸门（硬）

```bash
git status --porcelain   # 排除 ignore_dirty 后必须为空
```

- 不干净 → **停止**，逐条列出文件，给三个选项：并入本次提交 / 加入 `ignore_dirty` / 用户手动处理
- 临时文件一律写 `$TMPDIR`，**不得落在仓库内**（否则此闸门永远失败）

### Gate 2 — 对外操作确认（一次打包）

```
即将执行（不可逆）:
  1. seed-update-artifacts.sh --previous <上一版>   （只读拉取上一版产物，产出 DELTA_READY）
  2. git push origin release/vX.Y.Z[-dev.N]        （如启用 release_branch；PR 线此时开 PR 并合并）
  3. git tag -a vX.Y.Z[-dev.N] -m "vX.Y.Z[-dev.N] — 简要描述"   （PR 线：打在合并后的 HEAD）
  4. <build_command_dev|build_command>             （跳过：ci 模式）
  5. <update_feed_command>                         （生成 feed 与 .delta；update_feed=none 时跳过）
  6. check-update-delta.sh --version vX.Y.Z        （delta_strategy=always 时加 --require）
  7. git push origin vX.Y.Z[-dev.N]                （差分判定通过后才推 tag）
  8. gh release create vX.Y.Z[-dev.N] --title "..." --notes-file "$TMPDIR/..." [--prerelease]
     并上传 feed 与 .delta 资产
  更新包: 差分 1 个（vX.Y.(Z-1)，预计 ~0.9MB / 完整包 ~10.2MB）
          或「完整包 —— 上一版产物取不到（原因）」
```

- 上一版产物必须在**构建之前**就位；feed 生成器只会静默退回完整包，不会报错
- **tag 先建、后推**：`delta_strategy=always` 时第 6 步失败即停，远端不会留下指向未发布版本的标签
- 走 PR 的线：**先合并 PR，再在该线 HEAD 打 tag**（避免 tag 指向未合并提交）
- develop 线默认加 `--prerelease`；stable 线为正式 Release

### Phase 9 — 收尾

发版报告 + 最终 `git status --porcelain` 复核（含未跟踪文件）；不干净则明确报出，不算发版完成。

---

## 双轨发版（develop / main）

存在开发分支（默认 `develop`）时默认走双轨；显式"发版到 main / 正式发版"才直接走稳定线。单分支项目自动回退原流程。

| 线 | 分支 | 版本号 | Release | 内容 |
|---|---|---|---|---|
| Dev | `develop`（`target_branch`） | `vX.Y.Z-dev.N` | `--prerelease` | 日常开发，可含实验功能 |
| Stable | `main`（`stable_branch`） | `vX.Y.Z` | 正式 Release | 仅已验收变更 |

- **版本号**：develop base 只升不降，级别升高 → base 提升且 `N=1`，否则 `N+1`；main 由所选内容独立判定，**不继承 dev 版本号**（dev `v1.4.0-dev.3` 只同步 fix → stable `v1.3.2`）。校验用 `validate-version.sh … --target`。
- **同步**（develop 线发布成功后，`main_sync≠never`）：`--sync-candidates`（候选 = `main..最后 dev tag`，累计不漏项）→ 渲染推荐页 → question 选择 → 建 sync 分支（补 CHANGELOG 稳定版条目）`cherry-pick -x` → PR → CI 合并 → `tag vX.Y.Z` → Stable Release。事前说"发版并同步 main"则跳过询问。
- **推荐分级**：✅ 强推荐 `fix`/`docs`/`perf`/`refactor`/`chore`/`test`/`ci`/`build`（非 BREAKING、非实验）｜❓ 待确认 `feat`、安全相关｜⛔ 排除 BREAKING 与命中实验规则的项。实验规则：`experimental_paths`（glob）优先，`experimental_keywords` 兜底（匹配提交标题/正文与改动路径，大小写不敏感）。
- **禁令**：禁止整支合并 `develop → main`（只允许 `cherry-pick -x` 已验收提交）、禁止 force push、stable tag 必须无后缀。冲突一律停止并给选项。

---

## 版本判定

```bash
# 稳定线 / 开发线格式（tag_prefix 默认 v；其他前缀由脚本按首个数字解析）
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]              # vX.Y.Z
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+$ ]]  # vX.Y.Z-dev.N
bash scripts/validate-version.sh "$version" "$latest" --target develop|stable
```

| analyze-changes 结果 | bump | 示例 |
|---|---|---|
| `BREAKING_COUNT > 0`（`type!:` 或 body 含 `BREAKING CHANGE`） | `major` | v1.4.2 → v2.0.0 |
| `FEAT_COUNT > 0` | `minor` | v1.4.2 → v1.5.0 |
| 其余（fix / docs / refactor / chore / 无前缀） | `patch` | v1.4.2 → v1.4.3 |
| `HAS_CONTENT=false` | 停止 | 提示无需发版 |

覆盖规则（优先级高于自动判定）：
- 用户显式给出 `vX.Y.Z` → 直接用，analyze 结果仅作展示
- 用户说"大版本" → 强制 `minor`；"重大更新" → 强制 `major`
- 非 Conventional 前缀不猜测语义，统一计入 `OTHER` → patch

---

## 配置

优先级：项目 `.release.json` → 项目 `release.config.json` → `~/.config/opencode/release.json` → 自动检测。

```json
{
  "repo": "owner/repo",
  "tag_prefix": "v",
  "build_command": "npm run build",
  "release_command": null,
  "test_command": null,
  "docs": ["CHANGELOG.md", "README.md"],
  "changelog_format": "keep-a-changelog",
  "ci_mode": "local",
  "release_branch": true,
  "release_note_style": "auto",
  "summary": "",
  "summary_en": "",
  "validation": "",
  "pr_flow": "auto",
  "pr_cleanup": "report",
  "pr_cleanup_stale_days": 30,
  "target_branch": "auto",
  "stable_branch": "main",
  "dev_tag_suffix": "-dev",
  "experimental_paths": [],
  "experimental_keywords": ["experimental", "prototype", "preview", "draft", "wip"],
  "main_sync": "ask",
  "build_command_dev": null,
  "build_command_stable": null,
  "update_feed": "auto",
  "update_feed_command": null,
  "update_archive_dir": "release/updates",
  "update_artifact_glob": "*.dmg,*.zip,*.exe,*.AppImage,*.tar.gz,*.pkg",
  "delta_strategy": "auto",
  "delta_max": 2,
  "ignore_dirty": [".release.json", ".DS_Store", "tmp/", "*.log"]
}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `release_note_style` | `auto` | `auto`/`bilingual`/`simple`/`changelog`/`structured-cn` |
| `ci_mode` | `local` | `local` 本地全流程；`ci` 只打 tag；`auto` 检测 `.github/workflows` |
| `release_branch` | true | 是否创建 `release/vX.Y.Z[-dev.N]` |
| `pr_flow` | `auto` | `always` 发版必经 PR；`never` 不走 PR；`auto` 检测 workflows / protected main |
| `pr_cleanup` | `report` | `report` 只出可清理清单；`off` 跳过 |
| `pr_cleanup_stale_days` | 30 | stale PR 阈值 |
| `target_branch` | `auto` | 默认发版目标：`auto` 检测到 `develop` 即走双轨；也可显式写分支名 |
| `stable_branch` | `main` | 稳定发布分支 |
| `tag_prefix` | `v` | tag 前缀；脚本按首个数字解析，支持 `v` / `rel-` 等任意前缀 |
| `dev_tag_suffix` | `-dev` | 预发布后缀（`vX.Y.Z-dev.N`） |
| `experimental_paths` | `[]` | 实验目录 glob，命中强制留 develop |
| `experimental_keywords` | 见上 | 实验关键词兜底（匹配提交与改动路径，大小写不敏感） |
| `main_sync` | `ask` | `ask` 每次发布后询问是否同步 main；`never` 从不询问 |
| `build_command_dev` / `build_command_stable` | 继承 `build_command` | 双线构建差异（如不同产物命名或参数） |
| `update_feed` | `auto` | `auto`/`sparkle`/`electron`/`custom`/`none`；`auto` 依据依赖与脚本检测 |
| `update_feed_command` | null | 生成 feed 的命令（如 `scripts/appcast.sh`）；null 时按 `update_feed` 推断 |
| `update_archive_dir` | `release/updates` | feed 与差分资产所在目录 |
| `update_artifact_glob` | 见上 | 需要从上一版取回的产物 glob（逗号分隔） |
| `delta_strategy` | `auto` | `auto` 允许完整包但必须报告；`always` 无差分即停；`off` 不尝试 |
| `delta_max` | 2 | 传给 feed 工具的最大差分数量 |
| `ignore_dirty` | 见上 | 不计入「脏」的路径（支持 `tmp/` 前缀与 `*.log` 通配） |

> 是否合并到 main 由 `pr_flow` 决定（已取代旧字段 `auto_merge`）：只有场景 A 且无冲突、CI 通过时才自动合并，其余一律人工确认。

### 常用标志

| 标志 | 作用 |
|---|---|
| `--dry-run` | 只执行 Phase 1 并输出 Gate 1 计划；不修改文件、不提交、不推送 |
| `--force-config` | 跳过历史一致性推断，强制使用 `.release.json` 的 `release_note_style` |

---

## 构建命令自动检测

| 项目特征 | 构建命令 |
|---|---|
| `Package.swift` | `swift build -c release` |
| `package.json` + `build` script | `npm run build` |
| `Cargo.toml` | `cargo build --release` |
| `go.mod` | `go build -o ./release/` |
| `pyproject.toml` | `python -m build` |
| `Makefile` + `build` target | `make build` |
| `build.gradle` / `.kts` | `./gradlew build` |
| `pubspec.yaml` | `flutter build` |
| `mix.exs` | `mix release` |

Release 命令优先级：`release_command` 配置 → `scripts/release.sh` → `Makefile release` target → 回退 `build_command`。双线差异用 `build_command_dev` / `build_command_stable` 覆盖。

---

## 更新产物与差分（自更新）

差分更新的前提是**上一版产物就在本地**。构建产物通常被 gitignore，所以新建 worktree、新的 CI job、另一台机器默认都没有它；feed 生成器不会因此报错，只会静默退回完整包——发版看起来完全成功，用户每次却要下整包。这一步由 skill 负责，不能指望构建脚本。

### 检测

| 项目特征 | `update_feed` | feed 命令 |
|---|---|---|
| `Package.swift` + Sparkle 依赖 | `sparkle` | `scripts/appcast.sh`、`generate_appcast` |
| `electron-builder` / `electron-updater` | `electron` | 构建后的 publish 步骤（`latest*.yml` + `*.blockmap`）|
| `tauri.conf.json` | `none` | Tauri v2 无差分，只做签名 feed |
| 其他 | `custom` | 显式配置 `update_feed_command` |
| 都不匹配 | `none` | 跳过 |

`auto` 取 `bash scripts/detect-project.sh` 输出里的 `UPDATE_FEED=` / `UPDATE_FEED_COMMAND=`；项目 `.release.json` 里的同名字段可以覆盖检测结果。

### 取上一版产物（三处来源，按序尝试）

**时机**：Gate 1/2 用 `seed-update-artifacts.sh --dry-run` 只报预期（不落盘）；真正落盘放在干净闸门之后、构建之前。产物落点必须被 `.gitignore` 覆盖（`release/*/` 或 `update_archive_dir`），否则会把干净闸门打破。

```bash
bash scripts/seed-update-artifacts.sh --previous vX.Y.(Z-1)
# PREV_TAG / REPO / TARGET_DIR / STAGED_FROM / STAGED_FILES / DELTA_READY
```

1. `release/<上一版>/` 已有匹配产物 → `STAGED_FROM=local`
2. `--source-dir`（主 checkout、另一份工作树）→ 复制
3. GitHub Release 资产 → `gh release download`（只读，一个列表请求后精确匹配文件名）

**存在 ≠ 可用**：下载中断会留下截断文件，feed 工具随后解包失败或产出坏差分。发布方给了 `<产物>.sha256` 时必须校验，不匹配就删除并按「取不到」处理。脚本已内置该检查。

### 判定

```bash
bash scripts/check-update-delta.sh --version vX.Y.Z --feed <feed> [--archive <dir>]
# --archive 省略时取 feed 同级目录（Sparkle / electron-builder 都把差分放在那里）
# DELTA_KIND / DELTA_COUNT / FEED_DELTA_FROM / FEED_HAS_VERSION / DELTA_READY
```

| 生态 | 差分证据 |
|---|---|
| Sparkle | feed 内 `deltaFrom`，或 archive 内 `*.delta` |
| electron-builder | archive 内 `*.blockmap` |
| 其他 | 交回项目命令；脚本只回答 `DELTA_READY` |

- `--archive` 省略时取 feed 同级目录；配置了 `update_archive_dir` 时以它为准（Sparkle 的 `.delta` 可能落在与 feed 不同的归档目录）
- Sparkle 的 `deltaFrom` 写在 feed 里，所以即使归档目录不同也能判定；`--archive` 只影响 `.delta` 文件的计数
- `delta_strategy=auto`：允许完整包，但 Gate 2 与发版报告**必须写明**本次是完整包及原因
- `delta_strategy=always`：`--require`，没有差分就停止发版
- `delta_strategy=off`：不尝试，也不检测

差分资产随 Release 一起上传；feed 必须指向本次 tag 的下载地址。

---

## Release Note

**一致性优先**：格式与标题从最近 3 个历史 Release 推断，配置仅在无历史或 `--force-config` 时生效。

| 历史特征 | 格式 |
|---|---|
| 中英双语摘要 + 双语 emoji 分组 | `bilingual` |
| emoji 分组标题（🐛/✨/🔧）无英文对照 | `structured-cn` |
| `## [vX.Y.Z]` / `### Added` 等 Keep-a-Changelog 标题 | `changelog` |
| 均不匹配 | `simple` |

标题沿用历史模式（`{Product} vX.Y.Z` 或纯 `vX.Y.Z`）；描述只进 body，不进标题。

```bash
bash scripts/generate-notes.sh CHANGELOG.md vX.Y.Z --style auto --owner <owner> --repo <repo>
```

`structured-cn` 按 commit 前缀分组（`fix:`🐛 / `feat:`✨ / `refactor:`♻️ / `docs:`📝 / `perf:`⚡ / `test:`✅ / `ci:`🔄 / `build:`📦 / `chore:`🔧 / `release:`🚀 / `security:`🔐 / 无前缀🔧）。

模板：`templates/release-note.md`（四种格式变体）、`templates/release-note-bilingual.md`（bilingual 专用）、`templates/changelog-entry.md`（CHANGELOG 条目）。

---

## PR 处理（Phase 8）

### 场景 A — 发版走 PR（`pr_flow: always`，或 `auto` 检测命中）

1. 检测/创建 `release/vX.Y.Z[-dev.N] → {目标分支}` 的 PR：`gh pr list --head release/vX.Y.Z[-dev.N]`
2. 轮询 CI 状态：`gh pr checks <pr> --watch`
3. **CI 通过且无冲突 → 直接自动合并**（`gh pr merge --squash`）
4. **遇到冲突 → 不擅自解决**：展示 PR 摘要（功能目标、涉及提交、冲突文件与冲突点、建议解法），确认后再消解冲突并合并
5. **CI 失败 → 先诊断归类**（flaky / 本 PR 引入 / 环境问题），可重跑则重跑；**需要改源代码时停止并询问**（本 skill 不改源码）

### 场景 B — 发版后仓库卫生（收尾固定执行，`pr_cleanup: report`）

扫描并**只输出清单**，不执行任何删除：

- 已合并的本地 / 远程分支（含 `release/*`）
- 落后于 main 的本地分支
- 超过 `pr_cleanup_stale_days` 无活动的 stale PR
- 无对应远程分支的孤儿本地分支

输出形式为「可清理项 + 建议命令」，由用户手动执行。**从不自动合并、从不自动删除。**

---

## 渲染契约（openchamber）

优先 `openchamber_render`（render.page），文本只留结论；需要用户在多个方案中选择时用 `awaitAnswer` 在页面内收集，一次性二选一仍用 `question`；无渲染环境降级文本表并说明原因。

| 页面 | 时机 | 必含 |
|---|---|---|
| 发版计划页 | Gate 1 | 目标线 + dev/stable 版本对照 + 变更分组 + 待提交文件 + 构建命令 + **更新包预期（差分 / 完整包）** + 确认项 |
| 同步推荐页 | S1 | ✅/❓/⛔ 三档表（含理由与所含 dev 标签）+ stable 版本预测 |
| 发版报告页 | Phase 9 / S3 后 | 两条线结果 + tag/Release 链接 + **差分数量与节省比例（或完整包原因）** + cherry-pick 清单 + 可清理项 |

---

## Git 操作规范

```bash
git checkout -b release/vX.Y.Z[-dev.N]                       # 分支（如启用）
git commit -m "release: vX.Y.Z[-dev.N] — 简要描述"           # 提交

# 差分：构建前取上一版产物（落点需被 gitignore）
bash scripts/seed-update-artifacts.sh --previous vX.Y.(Z-1)

git tag -a vX.Y.Z[-dev.N] -m "vX.Y.Z[-dev.N] — 简要描述"     # annotated tag（先只在本地）
git push origin release/vX.Y.Z[-dev.N]                       # 推分支 / 开 PR
# …构建 → 生成 feed…
bash scripts/check-update-delta.sh --version vX.Y.Z --feed <feed> --archive <dir> [--require]
git push origin vX.Y.Z[-dev.N]                               # 判定通过后才推 tag
gh release create vX.Y.Z[-dev.N] --title "..." --notes-file <file> [--prerelease]

# 同步到稳定线（Phase S3）
git checkout -b sync/vX.Y.Z <stable_branch>
git cherry-pick -x <sha>…                                    # 只取已验收项
git push origin sync/vX.Y.Z && gh pr create --base <stable_branch> --head sync/vX.Y.Z
```

- Release 标题只放版本号（或历史推断的产品名前缀），描述走 `--notes-file`
- 临时文件写 `$TMPDIR`，不落仓库

---

## 安全边界

| 操作 | 权限 | 说明 |
|---|---|---|
| 读取配置 / 文档 / 分析变更 / 生成同步候选 | ✅ 自动 | 只读分析，不落文件 |
| 修改文档、创建分支、提交 | ✅ 自动 | 白名单 add，不用 `git add -A` |
| 拉取上一版产物（`gh release download`） | ✅ 自动 | 只读下载到本地 `release/<上一版>/`，不改变远端 |
| 打 tag / 推送 / 本地构建 / 创建 Release | ⚠️ 需确认 | Gate 2 一次打包 |
| 上传 feed 与差分资产 | ⚠️ 需确认 | 随 Gate 2 一并确认 |
| 场景 A 合并 PR（无冲突 + CI 通过） | ⚠️ 自动 | 有冲突必须确认 |
| cherry-pick 到 sync 分支并开 PR | ⚠️ 需确认 | 同步决策闸门（Phase S2） |
| 场景 B 清理 | 📄 只出清单 | 不执行删除 |
| 整支合并 develop → main | ❌ 禁止 | 只能 `cherry-pick -x` 已验收提交 |
| 修改源代码 | ❌ 不执行 | cherry-pick 重建提交、冲突消解需确认 |

## Error Handling

| 场景 | 处理 |
|---|---|
| 不是 Git 仓库 / 无 remote | 提示切换目录或添加 remote |
| 无任何变更（`HAS_CONTENT=false`） | 停止，提示无需发版 |
| 版本号格式错误 / 未递增 | `validate-version.sh` 报错，提示正确格式 |
| CHANGELOG 无 Unreleased | 提示先补变更记录 |
| Phase 5/9 工作区不干净 | **停止**，列文件，三选项处理 |
| 构建失败 | 提示错误，询问是否继续（不自动跳过） |
| 上一版产物取不到 | 明确报「本次为完整包更新」并给出原因；`delta_strategy=always` 时停止 |
| 上一版产物校验和不符 | 删除该文件并视为取不到（脚本已内置），重试或降级完整包 |
| feed 未包含本版版本号 | 停止，检查 feed 命令与版本注入 |
| feed 生成后无差分（`auto`） | 继续发版，但必须在 Gate 2 与报告里写明完整包及原因 |
| 推送 / Release 失败 | 提示原因与手动兜底命令 |
| PR 冲突 / CI 失败 | 展示摘要与诊断，确认后处理；需改源码则停 |
| cherry-pick 冲突 | 停止，列出冲突项，选项：跳过该项 / 放弃同步 / 手动处理；禁止 force |
| 目标分支不存在 | 回退单轨（stable），行为与原流程一致 |
| 无已验收 dev 候选（`--sync-candidates` 为空） | 提示无可同步项，直接结束 |

## Output Format

优先渲染「发版报告页」（见「渲染契约」），文本只留结论：

```
📋 发版报告

Dev 线:
✅ 变更分析:  {commits} 提交 + {dirty} 未提交文件 → {bump}
✅ 版本:      vX.Y.Z-dev.N（Pre-release）
✅ 提交:      release: vX.Y.Z-dev.N — {描述}
✅ 干净闸门:  git status 干净（含未跟踪）
✅ Tag/构建:  vX.Y.Z-dev.N 已推送 origin · {build_command} 成功（local 模式）
✅ 更新包:    差分 1 个（vX.Y.(Z-1)，0.9MB / 完整包 10.2MB，省 91%）
              或「完整包 —— 上一版产物取不到（原因）」
✅ Release:   https://github.com/{owner}/{repo}/releases/tag/vX.Y.Z-dev.N

Stable 线（执行同步时）:
✅ cherry-pick: {n} 项 → {stable_branch}（PR #{pr} 已合并）
✅ Release:     https://github.com/{owner}/{repo}/releases/tag/vX.Y.Z
⛔ 留 develop:  {排除项与理由}

📄 可清理项（需手动执行）:
   - 已合并分支: release/vX.Y.(Z-1)
   - stale PR: #42（>30 天无活动）
📌 下一步: 验证 Release 页面
```
