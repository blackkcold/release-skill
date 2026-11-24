#!/bin/bash
# detect-project.sh - 检测项目类型和构建命令

set -e

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR"

# 检测项目类型
detect_project_type() {
    if [ -f "Package.swift" ]; then
        echo "swift"
        return
    fi
    
    if [ -f "package.json" ]; then
        if grep -q '"build"' package.json 2>/dev/null; then
            echo "node"
            return
        fi
    fi
    
    if [ -f "Cargo.toml" ]; then
        echo "rust"
        return
    fi
    
    if [ -f "go.mod" ]; then
        echo "go"
        return
    fi
    
    if [ -f "pyproject.toml" ]; then
        echo "python"
        return
    fi
    
    if [ -f "Makefile" ]; then
        if grep -q "^build:" Makefile 2>/dev/null; then
            echo "make"
            return
        fi
    fi
    
    if [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
        echo "gradle"
        return
    fi
    
    echo "unknown"
}

# 获取构建命令
get_build_command() {
    local project_type="$1"
    local version="$2"
    
    case "$project_type" in
        swift)
            echo "swift build -c release"
            ;;
        node)
            echo "npm run build"
            ;;
        rust)
            echo "cargo build --release"
            ;;
        go)
            echo "go build -o ./release/"
            ;;
        python)
            echo "python -m build"
            ;;
        make)
            echo "make build"
            ;;
        gradle)
            echo "./gradlew build"
            ;;
        *)
            echo ""
            ;;
    esac
}

# 获取自更新 feed 类型：sparkle | electron | none | custom
detect_update_feed() {
    if [ -f "Package.swift" ] && grep -qi 'sparkle' Package.swift 2>/dev/null; then
        echo "sparkle"
        return
    fi

    if [ -f "scripts/appcast.sh" ] || [ -f "appcast.xml" ]; then
        echo "sparkle"
        return
    fi

    if [ -f "package.json" ] && grep -qE '"(electron-builder|electron-updater)"' package.json 2>/dev/null; then
        echo "electron"
        return
    fi

    # Tauri v2 的 updater 没有差分，只需要签名 feed
    if [ -f "src-tauri/tauri.conf.json" ] || [ -f "tauri.conf.json" ]; then
        echo "none"
        return
    fi

    echo "none"
}

# 生成 feed 的命令（空 = 由配置 update_feed_command 决定）
detect_update_feed_command() {
    if [ -f "scripts/appcast.sh" ]; then
        echo "bash scripts/appcast.sh"
        return
    fi
    if [ -f "scripts/generate-appcast.sh" ]; then
        echo "bash scripts/generate-appcast.sh"
        return
    fi
    echo ""
}

# 获取 release 命令
get_release_command() {
    local project_type="$1"
    local version="$2"
    
    # 优先检测项目特定的 release 脚本
    if [ -f "script/build_and_run_codex.sh" ]; then
        echo "RELEASE_VERSION=$version bash script/build_and_run_codex.sh release"
        return
    fi
    
    if [ -f "scripts/release.sh" ]; then
        echo "bash scripts/release.sh $version"
        return
    fi
    
    if [ -f "Makefile" ] && grep -q "^release:" Makefile 2>/dev/null; then
        echo "make release VERSION=$version"
        return
    fi
    
    # 回退到默认构建命令
    get_build_command "$project_type" "$version"
}

# 主逻辑
PROJECT_TYPE=$(detect_project_type)
BUILD_COMMAND=$(get_build_command "$PROJECT_TYPE" "")
RELEASE_COMMAND=$(get_release_command "$PROJECT_TYPE" "")
UPDATE_FEED=$(detect_update_feed)
UPDATE_FEED_COMMAND=$(detect_update_feed_command)

# 输出结果
echo "PROJECT_TYPE=$PROJECT_TYPE"
echo "BUILD_COMMAND=$BUILD_COMMAND"
echo "RELEASE_COMMAND=$RELEASE_COMMAND"
echo "UPDATE_FEED=$UPDATE_FEED"
echo "UPDATE_FEED_COMMAND=$UPDATE_FEED_COMMAND"
