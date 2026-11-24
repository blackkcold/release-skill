#!/bin/bash
# validate-version.sh - 验证版本号格式与递增（双轨：稳定 X.Y.Z / 预发布 X.Y.Z-dev.N）
#
# Usage: validate-version.sh <version> [latest_tag] [--target develop|stable]
#
# 前缀无关：tag_prefix 可以是 v / rel- / 任意前缀，按首个数字起解析。
# 规则:
#   稳定 X.Y.Z         必须严格大于 latest 稳定 tag
#   预发布 X.Y.Z-dev.N 同 base → N 必须递增；跨 base → base 必须更高
#   稳定 vs 预发布     稳定 base 必须 ≥ 对照 dev base（等于即"预发布转正式"）
#
# latest_tag 为对照基准：开发线传最近 dev tag，稳定线传最近稳定 tag。
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: validate-version.sh <version> [latest_tag] [--target develop|stable]

Prefix-agnostic: tag_prefix may be v / rel- / anything; parsing starts at the
first digit. Rules:
  stable X.Y.Z          must be greater than latest stable tag
  pre    X.Y.Z-dev.N    same base -> N increases; higher base -> N resets
Exit: 0 valid · 1 invalid · 2 usage
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

VERSION="${1:-}"
LATEST_TAG="${2:-}"
TARGET="auto"

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="${2:-auto}"; shift 2 ;;
        --target=*) TARGET="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo "❌ 错误: 缺少版本号"
    echo "   用法: validate-version.sh <version> [latest_tag] [--target develop|stable]"
    exit 1
fi

[[ -n "$LATEST_TAG" ]] || LATEST_TAG="0.0.0"

strip()   { printf '%s' "$1" | sed -E 's/^[^0-9]*//'; }
base_of() { printf '%s' "$(strip "$1")" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
num_of()  { strip "$1" | sed -E 's/^.*[^0-9]([0-9]+)$/\1/'; }
ver_gt()  { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }
is_dev()  { [[ "$(strip "$1")" =~ ^[0-9]+\.[0-9]+\.[0-9]+-(dev|pre|beta|rc)\.[0-9]+$ ]]; }

V_NORM="$(strip "$VERSION")"
L_NORM="$(strip "$LATEST_TAG")"
L_BASE="$(base_of "$LATEST_TAG")"; [[ -n "$L_BASE" ]] || L_BASE="0.0.0"

fail() {
    echo "❌ 错误: $1"
    echo "   对照: $LATEST_TAG"
    echo "   输入: $VERSION"
    exit 1
}

# ── 预发布版本 ──
if [[ "$V_NORM" =~ ^[0-9]+\.[0-9]+\.[0-9]+-(dev|pre|beta|rc)\.[0-9]+$ ]]; then
    V_BASE="$(base_of "$VERSION")"
    V_N="$(num_of "$VERSION")"

    if is_dev "$LATEST_TAG"; then
        L_DEVBASE="$(base_of "$LATEST_TAG")"
        L_N="$(num_of "$LATEST_TAG")"
        if [[ "$V_BASE" == "$L_DEVBASE" ]]; then
            if [[ "$V_N" -gt "$L_N" ]]; then
                echo "✅ 预发布递增: $LATEST_TAG → $VERSION"
                exit 0
            fi
            fail "同一 base 的预发布序号未递增"
        elif ver_gt "$V_BASE" "$L_DEVBASE"; then
            echo "✅ 预发布基线提升: $LATEST_TAG → $VERSION（序号重置为 1）"
            exit 0
        fi
        fail "预发布 base 不能低于最近 dev 基线"
    else
        if ver_gt "$V_BASE" "$L_BASE"; then
            echo "✅ 预发布基线提升: $LATEST_TAG → $VERSION"
            exit 0
        fi
        fail "预发布 base 必须高于当前稳定版"
    fi
fi

# ── 稳定版本 ──
if [[ ! "$V_NORM" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ 错误: 版本号格式不正确"
    echo "   稳定格式: X.Y.Z（可带 tag_prefix，如 v0.9.2）/ 预发布格式: X.Y.Z-dev.N"
    echo "   实际输入: $VERSION"
    exit 1
fi

if is_dev "$LATEST_TAG"; then
    V_BASE="$(base_of "$VERSION")"
    L_DEVBASE="$(base_of "$LATEST_TAG")"
    if ver_gt "$V_BASE" "$L_DEVBASE" || [[ "$V_BASE" == "$L_DEVBASE" ]]; then
        echo "✅ 预发布转正式: $LATEST_TAG → $VERSION"
        exit 0
    fi
    fail "稳定版 base 不能低于已发布的 dev 基线"
fi

IFS='.' read -r major minor patch <<< "$V_NORM"
IFS='.' read -r latest_major latest_minor latest_patch <<< "$L_BASE"

if [[ "$major" -gt "$latest_major" ]]; then
    echo "✅ MAJOR 版本升级: $LATEST_TAG → $VERSION"
    exit 0
elif [[ "$major" -lt "$latest_major" ]]; then
    fail "版本号不能低于当前版本"
fi

if [[ "$minor" -gt "$latest_minor" ]]; then
    echo "✅ MINOR 版本升级: $LATEST_TAG → $VERSION"
    exit 0
elif [[ "$minor" -lt "$latest_minor" ]]; then
    fail "版本号不能低于当前版本"
fi

if [[ "$patch" -gt "$latest_patch" ]]; then
    echo "✅ PATCH 版本升级: $LATEST_TAG → $VERSION"
    exit 0
elif [[ "$patch" -eq "$latest_patch" ]]; then
    fail "版本号已存在"
else
    fail "版本号不能低于当前版本"
fi
