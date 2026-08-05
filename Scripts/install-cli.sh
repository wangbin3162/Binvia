#!/usr/bin/env bash
# Binvia 命令行工具安装脚本（BinviaServer / BinviaCLI）
# 命令行工具是可选增强（无头部署 / 终端操作），日常使用只需 GUI 应用（DMG）。
#
# 用法：
#   curl -fsSL https://github.com/wangbin3162/Binvia/releases/latest/download/install-cli.sh | bash
#   # 或指定版本：
#   curl -fsSL https://github.com/wangbin3162/Binvia/releases/latest/download/install-cli.sh | bash -s 0.1.1
set -euo pipefail

REPO="wangbin3162/Binvia"
DEST="${BINVIA_CLI_PREFIX:-/usr/local/bin}"

# ---------- 解析版本 ----------
VERSION="${1:-latest}"
if [ "$VERSION" = "latest" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$VERSION" ] || { echo "无法解析最新版本号（网络或 API 问题）" >&2; exit 1; }
fi
echo "==> Binvia CLI ${VERSION}"

# ---------- 下载并校验 ----------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/${REPO}/releases/download/v${VERSION}/Binvia-${VERSION}-macos-arm64-x86_64.tar.gz"
echo "==> 下载 ${URL}"
curl -fL --retry 3 -o "$TMP/binvia.tar.gz" "$URL"

if curl -fsSL "https://github.com/${REPO}/releases/download/v${VERSION}/SHA256SUMS" -o "$TMP/SHA256SUMS" 2>/dev/null; then
    EXPECTED="$(grep "Binvia-${VERSION}-macos-arm64-x86_64.tar.gz" "$TMP/SHA256SUMS" | awk '{print $1}')"
    ACTUAL="$(shasum -a 256 "$TMP/binvia.tar.gz" | awk '{print $1}')"
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        echo "==> SHA256 校验通过"
    else
        echo "==> SHA256 校验失败，中止安装" >&2
        exit 1
    fi
else
    echo "==> 警告：无法获取 SHA256SUMS，跳过校验"
fi

tar -xzf "$TMP/binvia.tar.gz" -C "$TMP"

# ---------- 安装到目标目录 ----------
if [ -w "$DEST" ]; then
    cp "$TMP/BinviaServer" "$TMP/BinviaCLI" "$DEST/"
else
    echo "==> ${DEST} 需要管理员权限（请输入开机密码）"
    sudo cp "$TMP/BinviaServer" "$TMP/BinviaCLI" "$DEST/"
fi

echo ""
echo "==> 安装完成："
echo "    ${DEST}/BinviaServer"
echo "    ${DEST}/BinviaCLI"
echo ""
echo "验证：BinviaCLI providers list"
echo "启动服务：BinviaServer（默认 http://localhost:20427/v1）"
