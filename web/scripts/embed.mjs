#!/usr/bin/env node
// 构建后内联 embed.mjs
// 把 dist/index.html 及引用的 JS/CSS 内联为单文件 HTML → base64 → Swift 源码
// 用法：node scripts/embed.mjs

import { readFileSync, writeFileSync, existsSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const distDir = resolve(__dirname, '..', 'dist')
const indexPath = resolve(distDir, 'index.html')
const swiftPath = resolve(__dirname, '..', '..', 'Sources', 'BinviaCore', 'Server', 'WebPanelAssets.swift')

if (!existsSync(indexPath)) {
  console.error('错误: dist/index.html 不存在，请先运行 npm run build')
  process.exit(1)
}

let html = readFileSync(indexPath, 'utf-8')

// 内联 JS：替换 <script type="module" src="/assets/xxx.js"></script>
html = html.replace(
  /<script type="module" ([^>]*)?src="([^"]+)"([^>]*)?><\/script>/g,
  (match, _before, src, _after) => {
    const jsPath = resolve(distDir, src.replace(/^\//, ''))
    if (!existsSync(jsPath)) {
      console.warn(`警告: ${jsPath} 不存在，跳过内联`)
      return match
    }
    const content = readFileSync(jsPath, 'utf-8')
    return `<script type="module">\n${content}\n</script>`
  }
)

// 内联 CSS：替换 <link rel="stylesheet" href="/assets/xxx.css">
html = html.replace(
  /<link rel="stylesheet"([^>]*)?href="([^"]+)"([^>]*)?\/?>/g,
  (match, _before, href, _after) => {
    const cssPath = resolve(distDir, href.replace(/^\//, ''))
    if (!existsSync(cssPath)) {
      console.warn(`警告: ${cssPath} 不存在，跳过内联`)
      return match
    }
    const content = readFileSync(cssPath, 'utf-8')
    return `<style>\n${content}\n</style>`
  }
)

// 移除 vite 模块预加载 polyfill 链接（已内联后不需要）
html = html.replace(/<link rel="modulepreload"[^>]*>/g, '')

// Base64 编码
const base64 = Buffer.from(html, 'utf-8').toString('base64')

// 生成 Swift 源码
const swift = `import Foundation

/// Web 管理面板内嵌 HTML（base64 编码，由 web/scripts/embed.mjs 自动生成）。
/// 提交入库保证任何机器 swift build 不依赖 node。
/// 修改前端后执行 \`make web\` 重新生成此文件。
public enum WebPanelAssets {
    public static let htmlBase64 = "${base64}"

    /// 解码为 HTML 字符串。失败时返回空字符串（不应发生，若发生则是构建期错误）。
    public static var html: String {
        guard let data = Data(base64Encoded: htmlBase64),
              let decoded = String(data: data, encoding: .utf8) else {
            return "<html><body><p>面板加载失败</p></body></html>"
        }
        return decoded
    }
}
`

writeFileSync(swiftPath, swift, 'utf-8')
console.log(`✅ WebPanelAssets.swift 已生成 (${(base64.length / 1024).toFixed(1)} KB base64)`)
console.log(`   解码后 HTML: ${(html.length / 1024).toFixed(1)} KB`)