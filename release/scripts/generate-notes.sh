#!/bin/bash
# Usage: generate-notes.sh <changelog> <version> [--style auto|bilingual|simple|changelog|structured-cn]
# Style auto-detection: .release.json → GitHub Releases API analysis → fallback "simple"
set -euo pipefail

CHANGELOG_FILE="${1:-CHANGELOG.md}"
VERSION="${2:-}"
STYLE="auto"
OWNER=""
REPO=""

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --style) STYLE="$2"; shift 2 ;;
        --style=*) STYLE="${1#*=}"; shift ;;
        --owner) OWNER="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 <changelog> <version> [--style auto|bilingual|simple|changelog|structured-cn]"
            exit 0
            ;;
        *) shift ;;
    esac
done

[[ -n "$VERSION" ]] || { echo "❌ version required" >&2; exit 1; }

# —— Style resolution ——

detect_style_from_config() {
    local config_file="${1:-.release.json}"
    if [[ -f "$config_file" ]]; then
        python3 -c "import json; d=json.load(open('$config_file')); print(d.get('release_note_style',''))" 2>/dev/null || true
    fi
}

detect_style_from_github() {
    [[ -n "$OWNER" && -n "$REPO" ]] || return 1

    local releases_json
    releases_json=$(curl -sf "https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=3" 2>/dev/null || echo "[]")

    local bodies cjk_count latin_count
    bodies=$(echo "$releases_json" | python3 -c "
import json, sys
releases = json.load(sys.stdin)
print(' '.join([r.get('body','') for r in releases[:3]]))
" 2>/dev/null || echo "")

    [[ -n "$bodies" ]] || return 1

    # CJK range: U+4E00–U+9FFF, U+3400–U+4DBF
    cjk_count=$(python3 -c "import sys; body=sys.stdin.read(); print(sum(1 for c in body if '\u4e00'<=c<='\u9fff' or '\u3400'<=c<='\u4dbf'))" <<< "$bodies" 2>/dev/null || echo "0")
    latin_count=$(python3 -c "import sys; body=sys.stdin.read(); print(sum(1 for c in body if c.isascii() and c.isalpha()))" <<< "$bodies" 2>/dev/null || echo "0")

    if [[ "${cjk_count:-0}" -gt 50 ]] && [[ "${latin_count:-0}" -gt 100 ]]; then
        echo "bilingual"; return 0
    fi
    if echo "$bodies" | grep -qE '(🐛|✨|🔧|🔐|♿)' 2>/dev/null; then
        echo "structured-cn"; return 0
    fi
    if echo "$bodies" | grep -q '## \[' 2>/dev/null; then
        echo "changelog"; return 0
    fi
    echo "simple"
}

resolve_style() {
    [[ "$STYLE" != "auto" ]] && { echo "$STYLE"; return; }

    local s; s=$(detect_style_from_config); [[ -n "$s" && "$s" != "auto" ]] && { echo "$s"; return; }
    local s; s=$(detect_style_from_github); [[ -n "$s" ]] && { echo "$s"; return; }
    echo "simple"
}

RESOLVED_STYLE=$(resolve_style)

# —— Changelog extraction ——

CHANGELOG_ENTRY=$(sed -n "/^## \[${VERSION}\]/,/^## \[v/p" "$CHANGELOG_FILE" | sed '1d;$d')
[[ -n "$CHANGELOG_ENTRY" ]] || { echo "❌ No entry for $VERSION in $CHANGELOG_FILE" >&2; exit 1; }

SUMMARY_ZH=$(echo "$CHANGELOG_ENTRY" | head -3 | sed -n 's/^> \(.*\)$/\1/p' | head -1)
SUMMARY_EN=$(echo "$CHANGELOG_ENTRY" | head -5 | sed -n 's/^> \(.*\)$/\1/p' | tail -1)

PROJECT_NAME="${PROJECT_NAME:-}"
[[ -z "$PROJECT_NAME" && -f "README.md" ]] && PROJECT_NAME=$(head -1 README.md | sed 's/^# //')

PREV_VERSION=""
command -v git &>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 && \
    PREV_VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude="$VERSION" 2>/dev/null || true)
PREV_VERSION="${PREV_VERSION:-v0.0.0}"

echo "✨ Detected style: $RESOLVED_STYLE" >&2

# —— Output generators ——

case "$RESOLVED_STYLE" in
    bilingual)
        cat <<EOF
# ${VERSION} Release Notes

${PROJECT_NAME} ${VERSION}。${SUMMARY_ZH:-核心升级}。
${PROJECT_NAME} ${VERSION}. Core upgrade.

---

${CHANGELOG_ENTRY}

---

**完整 CHANGELOG** 见 [CHANGELOG.md](https://github.com/${OWNER}/${REPO}/blob/main/CHANGELOG.md)。

**Full Changelog**: https://github.com/${OWNER}/${REPO}/compare/${PREV_VERSION}...${VERSION}
EOF
        ;;
    simple)
        cat <<EOF
# ${VERSION} Release Notes

${PROJECT_NAME} ${VERSION}.

---

${CHANGELOG_ENTRY}

---

**Full Changelog**: https://github.com/${OWNER}/${REPO}/compare/${PREV_VERSION}...${VERSION}
EOF
        ;;
    changelog)
        cat <<EOF
${CHANGELOG_ENTRY}

---

**Full Changelog**: https://github.com/${OWNER}/${REPO}/compare/${PREV_VERSION}...${VERSION}
EOF
        ;;
    structured-cn)
        subjects=""
        if command -v git &>/dev/null && git rev-parse --git-dir >/dev/null 2>&1; then
            if git rev-parse --verify --quiet "${PREV_VERSION}^{commit}" >/dev/null 2>&1; then
                subjects=$(git log "${PREV_VERSION}..HEAD" --no-merges --format='%s' 2>/dev/null || true)
            else
                subjects=$(git log HEAD --no-merges --format='%s' 2>/dev/null || true)
            fi
        fi

        if [[ -n "$subjects" ]]; then
            grouped=$(printf '%s\n' "$subjects" | python3 -c '
import re, sys

GROUPS = [
    ("feat",     "✨", "新增"),
    ("fix",      "🐛", "修复"),
    ("perf",     "⚡", "性能优化"),
    ("refactor", "♻️", "重构"),
    ("docs",     "📝", "文档"),
    ("test",     "✅", "测试"),
    ("ci",       "🔄", "CI/CD"),
    ("build",    "📦", "构建"),
    ("security", "🔐", "安全"),
    ("release",  "🚀", "发布"),
    ("chore",    "🔧", "改进"),
    ("other",    "🔧", "其他"),
]
LABEL = {key: (emoji, title) for key, emoji, title in GROUPS}
ORDER = [key for key, _, _ in GROUPS]
buckets = {key: [] for key in ORDER}
PAT = re.compile(r"^([a-zA-Z]+)(\([^)]*\))?(!)?:\s*(.*)$")

for line in sys.stdin:
    subject = line.strip()
    if not subject:
        continue
    match = PAT.match(subject)
    key, text = "other", subject
    if match:
        t = match.group(1).lower()
        if t in LABEL:
            key = t
        text = match.group(4)
    text = text.strip().rstrip("。.")
    if text:
        text = text[0].upper() + text[1:]
    buckets[key].append(text)

out = []
for key in ORDER:
    items = [i for i in buckets[key] if i]
    if not items:
        continue
    emoji, title = LABEL[key]
    out.append(f"{emoji} {title}")
    out.extend(f"- {i}" for i in items)
    out.append("")
print("\n".join(out).strip())
')
            cat <<EOF
${VERSION} — ${SUMMARY_ZH:-发布}

${grouped}

---

**Full Changelog**: https://github.com/${OWNER}/${REPO}/compare/${PREV_VERSION}...${VERSION}
EOF
        else
            cat <<EOF
${VERSION} — ${SUMMARY_ZH:-发布}

${CHANGELOG_ENTRY}

---

**Full Changelog**: https://github.com/${OWNER}/${REPO}/compare/${PREV_VERSION}...${VERSION}
EOF
        fi
        ;;
    *)
        echo "⚠️  Unknown style '$RESOLVED_STYLE', falling back to simple" >&2
        cat <<EOF
# ${VERSION} Release Notes

${CHANGELOG_ENTRY}
EOF
        ;;
esac
