#!/usr/bin/env bash
# Binvia 打包脚本：release 构建 + 自包含测试（BinviaCheck）+ 拷贝产物到 bin/。
# 用法：./Scripts/build.sh
set -euo pipefail

# 切换到仓库根目录（脚本所在目录的上一级）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> [1/4] swift build -c release"
swift build -c release

echo "==> [2/4] swift run BinviaCheck（自包含测试，本机可直接运行）"
swift run BinviaCheck
# 注：Xcode 环境下也可用 `swift test`（需 XCTest）；本机仅 CLT 无 xctest，故不用。

echo "==> [3/4] BinviaApp 无界面自检（--smoke-test）"
swift run BinviaApp --smoke-test

echo "==> [4/4] 拷贝可执行文件到 bin/"
mkdir -p bin
# 服务端 / CLI 直接拷贝可执行文件；GUI 打包为 .app（LSUIElement，仅菜单栏）
cp .build/release/BinviaServer bin/
cp .build/release/BinviaCLI bin/
make_app_bundle() {
    local APP="$ROOT/bin/Binvia.app"
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp "$ROOT/.build/release/BinviaApp" "$APP/Contents/MacOS/BinviaApp"
    cat > "$APP/Contents/Info.plist" <<'PLIST'
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
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
    chmod +x "$APP/Contents/MacOS/BinviaApp"
}
make_app_bundle
chmod +x bin/*

echo ""
echo "==> 产物清单"
ls -lh bin/
echo ""
echo "打包完成：bin/ 下的可执行文件可直接运行；GUI 用 bin/Binvia.app。"
