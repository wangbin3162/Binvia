#!/usr/bin/env bash
# 生成 Sources/BinviaApp/Components/ProviderIcons.swift：
# 把 Sources/BinviaApp/Resources/ProviderIcon-*.svg 以 base64 内嵌为 Swift 字典。
#
# 背景：SPM 资源包（Bundle.module）在手工打包 .app 时无法被 codesign 封存
# （bundle 位于 app 根目录 → "unsealed contents"），且漏拷会导致点击菜单栏崩溃。
# 改为编译期内嵌后，开发与发布行为完全一致，无运行时资源查找。
#
# 用法：./Scripts/embed_svgs.sh（改动 Resources/*.svg 后重跑，并把生成文件一起提交）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/BinviaApp/Components/ProviderIcons.swift"
SRC_DIR="$ROOT/Sources/BinviaApp/Resources"

[ -d "$SRC_DIR" ] || { echo "缺少资源目录：$SRC_DIR" >&2; exit 1; }

{
    echo "// 自动生成文件：修改 SVG 后运行 ./Scripts/embed_svgs.sh 重新生成，勿手改。"
    echo "// SVG → base64 内嵌（避免 SPM 资源包在打包 .app 时的丢失/codesign 问题），"
    echo "// 开发（swift run）与发布（.app）行为一致。"
    echo ""
    echo "enum ProviderIcons {"
    echo "    /// providerID → SVG 内容（base64 编码）"
    echo "    static let svgs: [String: String] = ["
    for f in "$SRC_DIR"/ProviderIcon-*.svg; do
        name="$(basename "$f" .svg | sed 's/^ProviderIcon-//')"
        b64="$(base64 < "$f" | tr -d '\n')"
        echo "        \"$name\": \"$b64\","
    done
    echo "    ]"
    echo "}"
} > "$OUT"

echo "已生成：${OUT}（$(ls "$SRC_DIR"/ProviderIcon-*.svg | wc -l | tr -d ' ') 个图标）"
