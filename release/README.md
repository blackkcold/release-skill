# Release - 通用发版助手

自动完成语义化版本发布：分析待发变更 → 判定版本号 → 更新文档 → 提交 → 打 tag → 推送 → 构建 → 创建 GitHub Release → PR 处理。支持双轨：默认发到 `develop`（预发布），发布后主动推荐并询问是否把已验收变更 `cherry-pick` 同步到 `main`（稳定版）。

主定义见 [SKILL.md](SKILL.md)，此处只列快速上手与脚本接口。

## 快速上手

```bash
# 自动判定版本（分析变更后给出建议，一次确认）
skill(name="release", user_message="发版")

# 双轨口令
skill(name="release", user_message="发版到 main")      # 直接走稳定线
skill(name="release", user_message="发版并同步 main")  # dev 发布后直接进入同步清单选择

# 指定版本号（覆盖自动判定）
skill(name="release", user_message="发版 v0.9.2 备份管理 bug 修复")

# 试运行：只输出计划，不写任何东西
skill(name="release", user_message="发版 --dry-run")

# 版本级覆盖
skill(name="release", user_message="发大版本")     # 强制 MINOR
skill(name="release", user_message="发重大更新")   # 强制 MAJOR

# 英文触发
skill(name="release", user_message="release v0.9.2")
```

## 版本判定

由 `scripts/analyze-changes.sh` 分析「上个 tag 之后的提交 + 工作区未提交变更（含未跟踪）」后给出建议：

| 条件 | bump |
|---|---|
| `BREAKING_COUNT > 0`（`type!:` 或 body 含 `BREAKING CHANGE`） | MAJOR |
| `FEAT_COUNT > 0` | MINOR |
| 其余（fix / docs / refactor / chore / 无前缀） | PATCH |
| 无任何变更 | 停止，提示无需发版 |

用户显式给出的版本号优先级最高。

双轨版本号：

| 线 | 版本号 | 规则 |
|---|---|---|
| develop | `vX.Y.Z-dev.N` | base 只升不降；级别升高即 base 提升且 `N=1`，否则 `N+1` |
| main | `vX.Y.Z` | 由所选 cherry-pick 内容独立判定，不继承 dev 版本号 |

`--target develop|stable` 决定基线（最近 dev tag / 最近稳定 tag）；`--sync-candidates` 输出「已发 dev、未进 main」的候选集 JSON。

## 流程与闸门

```
Phase 1  环境 + 变更分析 → Phase 2 🔒Gate1 计划确认 → Phase 3 文档更新
→ Phase 4 一次 release 提交（白名单 add）→ Phase 5 🔒干净闸门
→ Phase 6 🔒Gate2 对外操作确认 → Phase 6.5 差分准备（上一版产物就位）
→ Phase 7 tag/push/构建/feed/差分判定/Release
→ Phase 8 PR 处理 → Phase 9 🔒收尾干净复核

双轨同步（仅 develop 线发布成功后，main_sync≠never）:
Phase S1 渲染同步推荐页 → Phase S2 🔒同步决策（全选/自选/跳过）
→ Phase S3 sync 分支 cherry-pick -x → PR → CI 合并 → tag vX.Y.Z → Stable Release
```

- **Gate 1**：一次问全（目标线/版本+理由、变更统计、待提交文件清单、文档、构建命令、**更新包预期**、Release 预览、PR 模式）
- **Gate 2**：tag + push + 构建 + feed/差分 + Release 一次打包确认（走 PR 的线先合并 PR 再打 tag）
- **同步决策**：三档推荐（✅强推荐 / ❓待确认 / ⛔排除），用 question 工具全选/自选/跳过
- **干净闸门**：`git status --porcelain`（含未跟踪、排除 `ignore_dirty`）必须为空，否则停止

## 差分更新（自更新）

构建产物被 gitignore，新 worktree / CI / 另一台机器默认没有上一版产物，feed 生成器会**静默退回完整包**。所以发版流程里有两步是固定动作：

```bash
# 1. 构建前：上一版产物就位（local → --source-dir → gh release download）
bash scripts/seed-update-artifacts.sh --previous v1.3.2
# → STAGED_FROM=local|source-dir|github|none · DELTA_READY=true|false

# 2. feed 生成后：确认真的产出了差分
bash scripts/check-update-delta.sh --version v1.4.0 --feed release/1.4.0/appcast.xml --archive release/appcast
# → DELTA_KIND=sparkle|electron|none · DELTA_READY=true|false
```

| 策略 | 行为 |
|---|---|
| `delta_strategy=auto`（默认） | 没有差分也发版，但 Gate 2 与报告必须写明「完整包 + 原因」 |
| `delta_strategy=always` | `--require`，没有差分就停止 |
| `delta_strategy=off` | 不尝试、不检测 |

下载中断会留下截断文件；发布方提供 `<产物>.sha256` 时脚本会校验并在不匹配时删除，避免用坏产物生成差分。

## 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/analyze-changes.sh` | 变更分析 + 版本建议（`--base`、`--json`、`--target develop\|stable`、`--sync-candidates`） |
| `scripts/validate-version.sh` | 版本号格式与递增校验（稳定 `vX.Y.Z` / 预发布 `vX.Y.Z-dev.N`，`--target`） |
| `scripts/detect-project.sh` | 项目类型、构建命令与自更新类型检测（`UPDATE_FEED` / `UPDATE_FEED_COMMAND`） |
| `scripts/generate-notes.sh` | Release Note 生成（`--style auto\|bilingual\|simple\|changelog\|structured-cn`） |
| `scripts/seed-update-artifacts.sh` | 取上一版产物供差分使用（本地 → `--source-dir` → `gh release download`，含 sha256 校验） |
| `scripts/check-update-delta.sh` | 判定 feed 是否真的带差分（Sparkle `deltaFrom` / Electron `blockmap`），`--require` 时无差分即失败 |

## PR 处理

| 场景 | 行为 |
|---|---|
| A. 发版走 PR（`pr_flow: always`） | 创建/检测 `release/vX.Y.Z[-dev.N] → {目标分支}`；CI 通过且无冲突 → 自动合并；有冲突 → 展示 PR 摘要确认后再处理；CI 失败 → 先诊断，需改源码则停 |
| B. 发版后仓库卫生（收尾固定） | 扫描已合并/落后/stale PR 与分支，**只出清单 + 建议命令，不执行删除**；从不自动合并 |

## 配置

项目根目录 `.release.json`（优先）→ `release.config.json` → `~/.config/opencode/release.json` → 自动检测。

新增字段：

| 字段 | 默认 | 说明 |
|---|---|---|
| `pr_flow` | `auto` | `always` / `never` / `auto`（检测 workflows、保护分支） |
| `pr_cleanup` | `report` | `report` 只出清单；`off` 跳过 |
| `pr_cleanup_stale_days` | 30 | stale PR 阈值 |
| `target_branch` | `auto` | 默认发版目标：`auto` 检测到 `develop` 即走双轨；也可显式写分支名 |
| `stable_branch` | `main` | 稳定发布分支 |
| `tag_prefix` | `v` | tag 前缀；脚本按首个数字解析，支持 `v` / `rel-` 等任意前缀 |
| `dev_tag_suffix` | `-dev` | 预发布后缀（`vX.Y.Z-dev.N`） |
| `experimental_paths` | `[]` | 实验目录 glob，命中强制留 develop |
| `experimental_keywords` | `["experimental","prototype","preview","draft","wip"]` | 实验关键词兜底（匹配提交与改动路径） |
| `main_sync` | `ask` | `ask` 每次询问是否同步 main；`never` 从不询问 |
| `build_command_dev` / `build_command_stable` | 继承 `build_command` | 双线构建差异（如不同产物命名或参数） |
| `update_feed` | `auto` | `auto`/`sparkle`/`electron`/`custom`/`none` |
| `update_feed_command` | null | 生成 feed 的命令（如 `scripts/appcast.sh`） |
| `update_archive_dir` | `release/updates` | feed 与差分资产目录 |
| `update_artifact_glob` | `*.dmg,*.zip,*.exe,*.AppImage,*.tar.gz,*.pkg` | 从上一版取回的产物 |
| `delta_strategy` | `auto` | `auto` / `always` / `off` |
| `delta_max` | 2 | 最大差分数量 |
| `ignore_dirty` | `[".release.json",".DS_Store","tmp/","*.log"]` | 不计入「脏」的路径 |

完整字段与示例见 [SKILL.md](SKILL.md) 与 `config/projects.json`。

## 安全边界

- ✅ 自动：读取配置/文档、变更分析、生成同步候选、文档更新、创建分支、白名单提交、拉取上一版产物（只读下载）
- ⚠️ 需确认：打 tag、推送、本地构建、生成并上传 feed 与差分、创建 Release（Gate 2 一次打包）；场景 A 有冲突时的合并；cherry-pick 同步（同步决策闸门）
- ⚠️ 自动：场景 A 无冲突且 CI 通过时的合并
- 📄 只出清单：场景 B 清理
- ❌ 禁止：整支合并 `develop → main`；force push
- ❌ 不执行：修改源代码（cherry-pick 重建提交、冲突消解需确认）

## 文件结构

```
release/
├── SKILL.md                 # Skill 主定义
├── README.md                # 快速上手（本文件）
├── config/projects.json     # 配置示例（非硬编码）
├── templates/               # Release Note / CHANGELOG 模板
└── scripts/                 # analyze-changes / validate-version / detect-project / generate-notes
                             # / seed-update-artifacts / check-update-delta
```
