#!/usr/bin/env bash
# Binvia DMG 打包脚本：把 bin/ 下的产物（Binvia.app + BinviaServer + BinviaCLI）
# 制作成拖入安装的 DMG 安装包（含 Applications 快捷方式与中文安装说明）。
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
for f in "$ROOT/bin/Binvia.app" "$ROOT/bin/BinviaServer" "$ROOT/bin/BinviaCLI"; do
    [ -e "$f" ] || { echo "缺少产物：$f（请先运行 ./Scripts/build.sh）" >&2; exit 1; }
done

DMG_NAME="Binvia-${MARKETING_VERSION}-macos-${ARCHES_TAG}.dmg"
STAGING="$ROOT/build/dmg-staging"

echo "==> 制作 DMG：${DMG_NAME}"

# ---------- 组装 staging 目录 ----------
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$ROOT/bin/Binvia.app" "$STAGING/"
cp "$ROOT/bin/BinviaServer" "$ROOT/bin/BinviaCLI" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/安装说明.txt" <<'TXT'
Binvia 安装方法
==================================================

【1. Binvia.app（菜单栏应用，必装）】
    把 Binvia.app 拖入左侧的「Applications」快捷方式即可。

【2. BinviaServer / BinviaCLI（命令行工具，可选）】
    打开「终端」，执行下面一行命令（需要输入开机密码）：

        sudo cp BinviaServer BinviaCLI /usr/local/bin/

    之后即可在终端使用 BinviaServer / BinviaCLI 命令。
    不需要命令行工具的话，这两项可以忽略。

【首次打开提示】
    若系统提示「无法验证开发者」，请：
    右键 Binvia.app → 打开 → 确认。
    （后续公证版将不再出现该提示）
TXT

# ---------- 生成 DMG（UDZO 压缩格式） ----------
hdiutil create \
    -volname "Binvia ${MARKETING_VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$ROOT/bin/$DMG_NAME"

rm -rf "$STAGING"

echo "==> DMG 完成：bin/${DMG_NAME}"
