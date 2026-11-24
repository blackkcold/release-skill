#!/bin/bash
# analyze-changes.sh - 双轨变更分析（develop 预发布线 / main 稳定线）
#
# Usage:
#   analyze-changes.sh [--base <ref>] [--target develop|stable|auto] [--json]
#   analyze-changes.sh --sync-candidates          # 同步候选集 JSON（已发 dev、未进稳定分支）
#
# 输出 KEY=VALUE（--json 时输出 JSON 对象）:
#   BASE CURRENT NEXT SUGGESTED_BUMP HAS_CONTENT TARGET
#   DEV_BRANCH STABLE_BRANCH DEV_BASE STABLE_BASE SUGGESTED_STABLE_VERSION
#   COMMITS FEAT_COUNT FIX_COUNT BREAKING_COUNT OTHER_COUNT EXPERIMENTAL_COUNT
#   DIRTY_TRACKED DIRTY_UNTRACKED FILES_CHANGED INSERTIONS DELETIONS
#
# 版本判定（严格 Conventional Commits）:
#   BREAKING_COUNT>0 → major ; FEAT_COUNT>0 → minor ; 其余 → patch ; 无变更 → none
#   develop 线: vX.Y.Z-dev.N（base 只升不降；升级即 N=1，否则 N+1）
#   main   线: 由所选内容独立判定，不继承 dev 版本号
#
# 实验功能判定（命中即默认留 develop）:
#   experimental_paths（glob）优先；未命中时用 experimental_keywords 兜底（大小写不敏感）
#
# 脏文件忽略清单取自配置 ignore_dirty，缺省: .release.json .DS_Store tmp/ *.log
set -euo pipefail

BASE_ARG=""
TARGET_ARG="auto"
OUTPUT_JSON="false"
SYNC_MODE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base) BASE_ARG="${2:-}"; shift 2 ;;
        --base=*) BASE_ARG="${1#*=}"; shift ;;
        --target) TARGET_ARG="${2:-auto}"; shift 2 ;;
        --target=*) TARGET_ARG="${1#*=}"; shift ;;
        --json) OUTPUT_JSON="true"; shift ;;
        --sync-candidates) SYNC_MODE="true"; shift ;;
        --help|-h) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "⚠️  未知参数: $1" >&2; shift ;;
    esac
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "❌ 当前目录不是 Git 仓库" >&2; exit 1; }

# ── 配置合并：全局 → 项目 release.config.json → 项目 .release.json（后者优先） ──
REL_CFG_JSON=$(python3 - <<'PY'
import json, os
files = [
    os.path.expanduser('~/.config/opencode/release.json'),
    'release.config.json',
    '.release.json',
]
d = {}
for p in files:
    if os.path.exists(p):
        try:
            with open(p) as f:
                v = json.load(f)
            if isinstance(v, dict):
                d.update(v)
        except Exception:
            pass
print(json.dumps(d, ensure_ascii=False))
PY
)
export REL_CFG_JSON

cfg() { # cfg <key> <default>
    python3 - "$1" "$2" <<'PY'
import json, os, sys
d = json.loads(os.environ.get('REL_CFG_JSON') or '{}')
v = d.get(sys.argv[1], sys.argv[2])
if isinstance(v, list):
    print('\n'.join(str(x) for x in v))
elif v is None:
    print(sys.argv[2])
else:
    print(v)
PY
}

TARGET_BRANCH_CFG="$(cfg target_branch auto)"
STABLE_BRANCH="$(cfg stable_branch main)"
DEV_SUFFIX="$(cfg dev_tag_suffix -dev)"
TAG_PREFIX="$(cfg tag_prefix v)"
IGNORES="$(cfg ignore_dirty "$(printf '%s\n' '.release.json' '.DS_Store' 'tmp/' '*.log')")"
EXP_PATHS="$(cfg experimental_paths '')"
EXP_KEYWORDS="$(cfg experimental_keywords "$(printf '%s\n' experimental prototype preview draft wip)")"

# ── 发版目标判定 ──
DEV_BRANCH="develop"
if [[ "$TARGET_BRANCH_CFG" != "" && "$TARGET_BRANCH_CFG" != "auto" && "$TARGET_BRANCH_CFG" != "$STABLE_BRANCH" ]]; then
    DEV_BRANCH="$TARGET_BRANCH_CFG"
fi

resolve_target() {
    case "$TARGET_ARG" in
        develop|dev) echo develop; return ;;
        main|stable) echo stable; return ;;
    esac
    case "$TARGET_BRANCH_CFG" in
        ""|auto) ;;
        "$STABLE_BRANCH") echo stable; return ;;
        *) echo develop; return ;;
    esac
    if git show-ref --verify --quiet "refs/heads/$DEV_BRANCH" \
        || git show-ref --verify --quiet "refs/remotes/origin/$DEV_BRANCH"; then
        echo develop
    else
        echo stable
    fi
}
TARGET="$(resolve_target)"

# ── 脏文件判定 ──
is_ignored() {
    local path="$1" pat base
    while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        base="${pat%/}"
        case "$path" in
            "$pat"|"$base") return 0 ;;
        esac
        case "$pat" in
            *\**|*\?*|*\[*)
                case "$path" in $pat) return 0 ;; esac
                ;;
            *)
                case "$path" in "$base"/*) return 0 ;; esac
                ;;
        esac
    done <<< "$IGNORES"
    return 1
}

# ── tag 查询（前缀无关：tag_prefix 可为 v / rel- 等） ──
latest_stable_tag() {
    if [[ -n "$DEV_SUFFIX" ]]; then
        git describe --tags --abbrev=0 --match "${TAG_PREFIX}[0-9]*" --exclude "*${DEV_SUFFIX}.*" 2>/dev/null || echo ""
    else
        git describe --tags --abbrev=0 --match "${TAG_PREFIX}[0-9]*" 2>/dev/null || echo ""
    fi
}
latest_dev_tag() {
    [[ -n "$DEV_SUFFIX" ]] || { echo ""; return; }
    git describe --tags --abbrev=0 --match "${TAG_PREFIX}*${DEV_SUFFIX}.*" 2>/dev/null || echo ""
}

STABLE_BASE="$(latest_stable_tag)"; [[ -n "$STABLE_BASE" ]] || STABLE_BASE="v0.0.0"
DEV_BASE_TAG="$(latest_dev_tag)"

# ── 分析基准（按目标分支选基线） ──
CURRENT=""
if [[ -n "$BASE_ARG" ]]; then
    CURRENT="$BASE_ARG"
elif [[ "$TARGET" == "develop" && -n "$DEV_BASE_TAG" ]]; then
    CURRENT="$DEV_BASE_TAG"
else
    CURRENT="$(latest_stable_tag)"
fi
[[ -n "$CURRENT" ]] || CURRENT="v0.0.0"
BASE="$CURRENT"

if git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
    RANGE="$BASE..HEAD"
    DIFF_BASE="$BASE"
else
    RANGE="HEAD"
    DIFF_BASE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
fi

# ── 实验功能判定 ──
commit_experimental() { # <sha> <subject> <body>
    local sha="$1" subj="$2" body="$3" kw pat p paths hay
    hay="$(printf '%s\n%s' "$subj" "$body")"
    if [[ -n "$EXP_KEYWORDS" ]]; then
        shopt -s nocasematch
        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            if [[ "$hay" == *"$kw"* ]]; then shopt -u nocasematch; return 0; fi
        done <<< "$EXP_KEYWORDS"
        shopt -u nocasematch
    fi
    [[ -n "$EXP_PATHS$EXP_KEYWORDS" ]] || return 1

    paths="$(git show --pretty='' --name-only "$sha" 2>/dev/null || true)"
    [[ -n "$paths" ]] || return 1

    if [[ -n "$EXP_PATHS" ]]; then
        while IFS= read -r pat; do
            [[ -z "$pat" ]] && continue
            pat="${pat%/}"
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                case "$p" in
                    $pat|"$pat"/*) return 0 ;;
                esac
            done <<< "$paths"
        done <<< "$EXP_PATHS"
    fi
    if [[ -n "$EXP_KEYWORDS" ]]; then
        shopt -s nocasematch
        while IFS= read -r kw; do
            [[ -z "$kw" ]] && continue
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                if [[ "$p" == *"$kw"* ]]; then shopt -u nocasematch; return 0; fi
            done <<< "$paths"
        done <<< "$EXP_KEYWORDS"
        shopt -u nocasematch
    fi
    return 1
}

# ── 提交分类（严格 Conventional Commits） ──
COMMITS=0
FEAT_COUNT=0
FIX_COUNT=0
BREAKING_COUNT=0
OTHER_COUNT=0
EXPERIMENTAL_COUNT=0

while IFS= read -r -d $'\x1e' record; do
    record="${record#$'\n'}"
    [[ -z "$record" ]] && continue
    sha="${record%%$'\x1f'*}"
    rest="${record#*$'\x1f'}"
    subject="${rest%%$'\x1f'*}"
    body="${rest#*$'\x1f'}"
    [[ -z "$subject" ]] && continue
    COMMITS=$((COMMITS + 1))

    if [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]*\))?!:\  ]] || [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]*\))?!:$ ]] || [[ "$body" == *"BREAKING CHANGE"* ]]; then
        BREAKING_COUNT=$((BREAKING_COUNT + 1))
    elif [[ "$subject" =~ ^feat(\([^\)]*\))?:\  ]]; then
        FEAT_COUNT=$((FEAT_COUNT + 1))
    elif [[ "$subject" =~ ^fix(\([^\)]*\))?:\  ]]; then
        FIX_COUNT=$((FIX_COUNT + 1))
    else
        OTHER_COUNT=$((OTHER_COUNT + 1))
    fi

    if commit_experimental "$sha" "$subject" "$body"; then
        EXPERIMENTAL_COUNT=$((EXPERIMENTAL_COUNT + 1))
    fi
done < <(git log "$RANGE" --no-merges --format='%H%x1f%s%x1f%b%x1e' 2>/dev/null || true)

# ── 工作区未提交变更 ──
DIRTY_TRACKED=0
DIRTY_UNTRACKED=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    status="${line:0:2}"
    path="${line:3}"
    path="${path%\"}"; path="${path#\"}"
    path="${path##* -> }"
    is_ignored "$path" && continue
    if [[ "$status" == "??" ]]; then
        DIRTY_UNTRACKED=$((DIRTY_UNTRACKED + 1))
    else
        DIRTY_TRACKED=$((DIRTY_TRACKED + 1))
    fi
done < <(git status --porcelain 2>/dev/null || true)

# ── 改动规模（含已提交 + 工作区，仅跟踪文件） ──
SHORTSTAT=$(git diff --shortstat "$DIFF_BASE" 2>/dev/null || true)
FILES_CHANGED=$(printf '%s' "$SHORTSTAT" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo 0)
INSERTIONS=$(printf '%s' "$SHORTSTAT" | grep -oE '[0-9]+ insertions?' | grep -oE '[0-9]+' || echo 0)
DELETIONS=$(printf '%s' "$SHORTSTAT" | grep -oE '[0-9]+ deletions?' | grep -oE '[0-9]+' || echo 0)
FILES_CHANGED=${FILES_CHANGED:-0}
INSERTIONS=${INSERTIONS:-0}
DELETIONS=${DELETIONS:-0}

# ── 版本判定 ──
HAS_CONTENT="true"
if [[ "$COMMITS" -eq 0 && "$DIRTY_TRACKED" -eq 0 && "$DIRTY_UNTRACKED" -eq 0 ]]; then
    HAS_CONTENT="false"
fi

if [[ "$HAS_CONTENT" == "false" ]]; then
    SUGGESTED_BUMP="none"
elif [[ "$BREAKING_COUNT" -gt 0 ]]; then
    SUGGESTED_BUMP="major"
elif [[ "$FEAT_COUNT" -gt 0 ]]; then
    SUGGESTED_BUMP="minor"
else
    SUGGESTED_BUMP="patch"
fi

apply_bump() { # apply_bump <bump> <baseVersion>
    local bump="$1" base="$2" nums prefix major minor patch
    nums=$(printf '%s' "$base" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
    prefix="${base%"$nums"}"
    IFS='.' read -r major minor patch <<< "$nums"
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}
    case "$bump" in
        major) echo "${prefix}$((major + 1)).0.0" ;;
        minor) echo "${prefix}${major}.$((minor + 1)).0" ;;
        patch) echo "${prefix}${major}.${minor}.$((patch + 1))" ;;
        *)     echo "$base" ;;
    esac
}
ver_gt() { # ver_gt <a> <b>  → a > b
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

SUGGESTED_STABLE_VERSION="$(apply_bump "$SUGGESTED_BUMP" "$STABLE_BASE")"

if [[ "$TARGET" == "develop" ]]; then
    if [[ "$SUGGESTED_BUMP" == "none" ]]; then
        NEXT="${DEV_BASE_TAG:-$STABLE_BASE}"
    else
        stable_target="$(apply_bump "$SUGGESTED_BUMP" "$STABLE_BASE")"
        if [[ -n "$DEV_BASE_TAG" ]]; then
            devnums=$(printf '%s' "$DEV_BASE_TAG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
            devn=$(printf '%s' "$DEV_BASE_TAG" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/' || echo 0)
            devn=${devn:-0}
            devprefix="${DEV_BASE_TAG%%[0-9]*}"
            if ver_gt "$stable_target" "${devprefix}${devnums}"; then
                NEXT="${stable_target}${DEV_SUFFIX}.1"
            else
                NEXT="${devprefix}${devnums}${DEV_SUFFIX}.$((devn + 1))"
            fi
        else
            NEXT="${stable_target}${DEV_SUFFIX}.1"
        fi
    fi
else
    NEXT="$SUGGESTED_STABLE_VERSION"
fi

# ── 同步候选集（已发 dev、未进稳定分支） ──
emit_sync_candidates() {
    local stable_ref="" dev_ref="$DEV_BASE_TAG"

    for r in "origin/$STABLE_BRANCH" "$STABLE_BRANCH"; do
        if git rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1; then stable_ref="$r"; break; fi
    done

    if [[ -z "$stable_ref" || -z "$dev_ref" ]] \
        || ! git rev-parse --verify --quiet "$stable_ref^{commit}" >/dev/null 2>&1; then
        echo "[]"
        return 0
    fi

    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/sync-candidates.XXXXXX")"
    : > "$tmp"

    while IFS=$'\x1f' read -r sha subject; do
        [[ -z "$sha" ]] && continue
        local type="other" breaking="false" experimental="false" devtags=""
        if [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]*\))?!:\  ]] || [[ "$subject" =~ ^[a-zA-Z]+(\([^\)]*\))?!:$ ]]; then
            breaking="true"
        elif [[ "$subject" =~ ^feat(\([^\)]*\))?:\  ]]; then
            type="feat"
        elif [[ "$subject" =~ ^fix(\([^\)]*\))?:\  ]]; then
            type="fix"
        elif [[ "$subject" =~ ^(docs|perf|refactor|chore|test|ci|build|release|security)(\([^\)]*\))?:\  ]]; then
            type="${BASH_REMATCH[1]}"
        fi
        if commit_experimental "$sha" "$subject" ""; then experimental="true"; fi
        devtags=$(git tag --contains "$sha" --list "${TAG_PREFIX}*${DEV_SUFFIX}.*" 2>/dev/null | paste -sd, - || true)
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${sha:0:8}" "$type" "$breaking" "$experimental" "$subject" "$devtags" >> "$tmp"
    done < <(git log "$stable_ref..$dev_ref" --no-merges --format='%H%x1f%s' 2>/dev/null || true)

    python3 - "$tmp" <<'PY'
import json, sys

rows = []
try:
    fh = open(sys.argv[1])
except OSError:
    fh = []
for raw in fh:
    parts = raw.rstrip("\n").split("\t")
    if len(parts) < 6:
        continue
    short, typ, breaking, experimental, subject, devtags = parts[:6]
    low = subject.lower()
    if breaking == "true":
        rec, reason = "exclude", "BREAKING 变更"
    elif experimental == "true":
        rec, reason = "exclude", "命中实验规则"
    elif typ == "feat":
        rec, reason = "confirm", "feat 需确认已验收"
    elif typ == "security" or "security" in low or "cve" in low:
        rec, reason = "confirm", "安全相关，需评估影响面"
    else:
        rec, reason = "strong", "非 BREAKING、非实验"
    rows.append({
        "sha": short,
        "type": typ,
        "subject": subject,
        "breaking": breaking == "true",
        "experimental": experimental == "true",
        "dev_tags": [t for t in devtags.split(",") if t],
        "recommendation": rec,
        "reason": reason,
    })
print(json.dumps(rows, ensure_ascii=False, indent=2))
PY
    rm -f "$tmp"
}

if [[ "$SYNC_MODE" == "true" ]]; then
    emit_sync_candidates
    exit 0
fi

# ── 输出 ──
emit_kv() {
    cat <<EOF
BASE=$BASE
CURRENT=$CURRENT
NEXT=$NEXT
SUGGESTED_BUMP=$SUGGESTED_BUMP
HAS_CONTENT=$HAS_CONTENT
TARGET=$TARGET
DEV_BRANCH=$DEV_BRANCH
STABLE_BRANCH=$STABLE_BRANCH
DEV_BASE=$DEV_BASE_TAG
STABLE_BASE=$STABLE_BASE
SUGGESTED_STABLE_VERSION=$SUGGESTED_STABLE_VERSION
COMMITS=$COMMITS
FEAT_COUNT=$FEAT_COUNT
FIX_COUNT=$FIX_COUNT
BREAKING_COUNT=$BREAKING_COUNT
OTHER_COUNT=$OTHER_COUNT
EXPERIMENTAL_COUNT=$EXPERIMENTAL_COUNT
DIRTY_TRACKED=$DIRTY_TRACKED
DIRTY_UNTRACKED=$DIRTY_UNTRACKED
FILES_CHANGED=$FILES_CHANGED
INSERTIONS=$INSERTIONS
DELETIONS=$DELETIONS
EOF
}

if [[ "$OUTPUT_JSON" == "true" ]]; then
    emit_kv | python3 -c '
import json, sys
TEXT_KEYS = {"base","current","next","suggested_bump","target","dev_branch",
             "stable_branch","dev_base","stable_base","suggested_stable_version"}
out = {}
for line in sys.stdin:
    key, _, val = line.strip().partition("=")
    if not key:
        continue
    key = key.lower()
    if key == "has_content":
        out[key] = (val == "true")
    elif key in TEXT_KEYS:
        out[key] = val
    else:
        try:
            out[key] = int(val or 0)
        except ValueError:
            out[key] = val
print(json.dumps(out, indent=2, ensure_ascii=False))
'
else
    emit_kv
fi

if [[ "$HAS_CONTENT" == "false" ]]; then
    echo "⚠️  基准（$CURRENT）以来没有任何变更（0 提交、工作区干净），无需发版" >&2
fi
