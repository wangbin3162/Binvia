#!/usr/bin/env bash
# Binvia DMG 打包脚本：把 bin/Binvia.app 制作成带样式的拖入安装 DMG。
# - 只含 Binvia.app + Applications 快捷方式（CLI 工具改为 curl 安装，见 Scripts/install-cli.sh）
# - 背景图 + 图标布局来自提交的模板（Scripts/dmg-template.DS_Store + assets/dmg-background.png）
#
# 用法：./Scripts/make_dmg.sh            # 需先运行 ./Scripts/build.sh 生成 bin/ 产物
# 产物：bin/Binvia-<版本>-macos-<架构>.dmg
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

# ---------- 架构标签（与 build.sh 一致，用于产物命名） ----------
ARCHES="${ARCHES:-arm64 x86_64}"
ARCHES_TAG="$(echo $ARCHES | tr ' ' '-')"

# ---------- 前置检查 ----------
[ -d "$ROOT/bin/Binvia.app" ] || { echo "缺少产物：bin/Binvia.app（请先运行 ./Scripts/build.sh）" >&2; exit 1; }
[ -f "$ROOT/Scripts/dmg-template.DS_Store" ] || { echo "缺少布局模板：Scripts/dmg-template.DS_Store" >&2; exit 1; }
[ -f "$ROOT/assets/dmg-background.png" ] || { echo "缺少背景图：assets/dmg-background.png" >&2; exit 1; }

DMG_NAME="Binvia-${MARKETING_VERSION}-macos-${ARCHES_TAG}.dmg"
STAGING="$ROOT/build/dmg-staging"

echo "==> 制作 DMG：${DMG_NAME}"

# ---------- 组装 staging 目录（app + Applications 快捷方式 + 隐藏样式资源） ----------
rm -rf "$STAGING"
mkdir -p "$STAGING/.background"
cp -R "$ROOT/bin/Binvia.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/assets/dmg-background.png" "$STAGING/.background/background.png"
cp "$ROOT/Scripts/dmg-template.DS_Store" "$STAGING/.DS_Store"

# ---------- 生成 DMG（UDZO 压缩格式；布局由 .DS_Store 模板决定） ----------
hdiutil create \
    -volname "Binvia ${MARKETING_VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$ROOT/bin/$DMG_NAME"

rm -rf "$STAGING"

echo "==> DMG 完成：bin/${DMG_NAME}"
