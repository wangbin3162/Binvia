#!/usr/bin/env bash
# Binvia 打包脚本：release 构建（默认双架构 universal）+ 自包含测试（BinviaCheck）
# + GUI 无界面自检（--smoke-test）+ adhoc 代码签名 + tar.gz 打包 + 产物拷贝到 bin/。
#
# 用法：
#   ./Scripts/build.sh                            # 默认 arm64 + x86_64（universal）
#   ARCHES="arm64" ./Scripts/build.sh             # 仅本机架构，快速构建/自检
#   MARKETING_VERSION=0.2.0 BUILD_NUMBER=2 ./Scripts/build.sh  # 临时覆盖版本号
#
# 版本号默认读取 version.env；CI 发布时会用 git tag 覆盖 version.env，保证产物与 tag 一致。
set -euo pipefail

# 切换到仓库根目录（脚本所在目录的上一级）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ---------- 版本号 ----------
if [ -f "$ROOT/version.env" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/version.env"
fi
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

# ---------- 目标架构 ----------
ARCHES="${ARCHES:-arm64 x86_64}"
ARCH_COUNT="$(echo $ARCHES | wc -w | tr -d ' ')"
ARCHES_TAG="$(echo $ARCHES | tr ' ' '-')"   # 如 arm64-x86_64，用于产物命名
HOST_ARCH="$(uname -m)"

echo "==> Binvia ${MARKETING_VERSION} (build ${BUILD_NUMBER})  架构: ${ARCHES}"

# ---------- 清理旧产物 ----------
rm -rf "$ROOT/bin"
mkdir -p "$ROOT/bin"

# ---------- 构建 ----------
echo "==> [1/6] swift build -c release（逐架构，独立 scratch 目录）"
for arch in $ARCHES; do
    echo "    -- 构建 ${arch} ..."
    # 每个架构用独立 scratch 目录：多架构顺序构建时，SwiftPM 顶层 .build/release
    # 符号链接会在各架构间翻转，导致 "swift-version file not registered" 错误。
    swift build -c release --arch "$arch" --scratch-path "$ROOT/.build/$arch"
done

# 产物位于各架构 scratch 目录下：.build/<arch>/release/
build_dir() { echo "$ROOT/.build/$1/release"; }

# ---------- 测试（仅当宿主架构在目标架构内时执行） ----------
if [[ " $ARCHES " == *" $HOST_ARCH "* ]]; then
    HOST_BUILD="$(build_dir "$HOST_ARCH")"

    echo "==> [2/6] BinviaCheck（自包含测试，本机可直接运行）"
    "$HOST_BUILD/BinviaCheck"

    echo "==> [3/6] BinviaApp 无界面自检（--smoke-test）"
    "$HOST_BUILD/BinviaApp" --smoke-test
else
    echo "==> [2-3/6] 跳过测试：宿主架构 ${HOST_ARCH} 不在目标架构 ${ARCHES} 内"
fi

# ---------- 合并可执行文件 ----------
echo "==> [4/6] 合并可执行文件到 bin/"
combine() {
    local name="$1"
    local out="$ROOT/bin/$name"
    local srcs=()
    for arch in $ARCHES; do
        srcs+=("$(build_dir "$arch")/$name")
    done
    if [ "$ARCH_COUNT" -ge 2 ]; then
        lipo -create -output "$out" "${srcs[@]}"
    else
        cp "${srcs[0]}" "$out"
    fi
    chmod +x "$out"
}
combine BinviaServer
combine BinviaCLI
combine BinviaApp

# ---------- .app bundle ----------
echo "==> [5/6] 打包 .app（LSUIElement 菜单栏应用）"
make_app_bundle() {
    local APP="$ROOT/bin/Binvia.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$ROOT/bin/BinviaApp" "$APP/Contents/MacOS/BinviaApp"

    # git 提交信息（无 git 环境时容错）
    local GIT_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    local BUILD_TIME="$(date +%Y-%m-%dT%H:%M:%S%z)"

    # App 图标：从 assets/logo.png 生成 .icns（缺失时静默跳过，便于开发期容错）
    local ICON_SRC="$ROOT/assets/logo.png"
    if [ -f "$ICON_SRC" ]; then
        local ICONSET="$ROOT/build/AppIcon.iconset"
        rm -rf "$ICONSET" "$ROOT/build/AppIcon.icns"
        mkdir -p "$ICONSET"
        # macOS 11+ 标准图标尺寸（@1x 与 @2x，覆盖 16~1024）
        sips -z 16 16      "$ICON_SRC" --out "$ICONSET/icon_16x16.png"       >/dev/null
        sips -z 32 32      "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
        sips -z 32 32      "$ICON_SRC" --out "$ICONSET/icon_32x32.png"       >/dev/null
        sips -z 64 64      "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"    >/dev/null
        sips -z 128 128    "$ICON_SRC" --out "$ICONSET/icon_128x128.png"     >/dev/null
        sips -z 256 256    "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
        sips -z 256 256    "$ICON_SRC" --out "$ICONSET/icon_256x256.png"     >/dev/null
        sips -z 512 512    "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
        sips -z 512 512    "$ICON_SRC" --out "$ICONSET/icon_512x512.png"     >/dev/null
        sips -z 1024 1024  "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png"  >/dev/null
        iconutil -c icns "$ICONSET" -o "$ROOT/build/AppIcon.icns"
        cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    fi

    # Info.plist：版本号由 version.env / 环境变量注入，不再硬编码
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BinviaApp</string>
    <key>CFBundleIdentifier</key>
    <string>dev.binvia.app</string>
    <key>CFBundleName</key>
    <string>Binvia</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>BinviaGitCommit</key>
    <string>${GIT_COMMIT}</string>
    <key>BinviaBuildTime</key>
    <string>${BUILD_TIME}</string>
</dict>
</plist>
PLIST
    chmod +x "$APP/Contents/MacOS/BinviaApp"
}
make_app_bundle

# ---------- adhoc 代码签名 ----------
echo "==> [6/6] adhoc 代码签名 + 清理扩展属性（xattr -cr）"
codesign --force --deep --sign - "$ROOT/bin/Binvia.app"
codesign --force --sign - "$ROOT/bin/BinviaServer"
codesign --force --sign - "$ROOT/bin/BinviaCLI"
xattr -cr "$ROOT/bin/Binvia.app" "$ROOT/bin/BinviaServer" "$ROOT/bin/BinviaCLI"

# ---------- 打包 ----------
echo "==> 打包 tar.gz + SHA256"
TARBALL="Binvia-${MARKETING_VERSION}-macos-${ARCHES_TAG}.tar.gz"
(cd "$ROOT/bin" && tar -czf "$TARBALL" Binvia.app BinviaServer BinviaCLI \
    && shasum -a 256 "$TARBALL" > SHA256SUMS)

echo ""
echo "==> 产物清单"
ls -lh "$ROOT/bin/"
echo ""
echo "打包完成：bin/ 下的可执行文件可直接运行；GUI 用 bin/Binvia.app。"
echo "发布用压缩包：bin/${TARBALL}（校验和见 bin/SHA256SUMS）"
