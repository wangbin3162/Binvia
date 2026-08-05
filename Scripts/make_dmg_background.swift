// Binvia DMG 背景图生成器（纯 AppKit，零依赖）
// 用法：swift Scripts/make_dmg_background.swift [输出路径]
// 输出：1320x800（660x400 @2x）PNG，供 DMG 安装窗口背景使用
import AppKit

let W: CGFloat = 660   // 逻辑尺寸（点）
let H: CGFloat = 400
let scale: CGFloat = 2

// ---------- 画布（2x 位图） ----------
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// ---------- 背景渐变（浅色 macOS 风格） ----------
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.976, green: 0.978, blue: 0.984, alpha: 1),
    NSColor(calibratedRed: 0.925, green: 0.933, blue: 0.949, alpha: 1),
])!
gradient.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// ---------- 文字工具 ----------
func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat,
          weight: NSFont.Weight, color: NSColor, align: NSTextAlignment = .left) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let w = str.size().width
    let dx = align == .center ? (W - w) / 2 - x : 0
    str.draw(at: NSPoint(x: x + dx, y: y))
}

// ---------- 标题区（左上） ----------
draw("Binvia", x: 38, y: 330, size: 34, weight: .semibold,
     color: NSColor(calibratedWhite: 0.11, alpha: 1))
draw("本地 AI 聚合网关 · 菜单栏应用", x: 39, y: 292, size: 13, weight: .regular,
     color: NSColor(calibratedWhite: 0.52, alpha: 1))

// ---------- 箭头（两个图标槽位之间） ----------
let arrowY: CGFloat = 206
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.move(to: NSPoint(x: 252, y: arrowY))
arrow.line(to: NSPoint(x: 396, y: arrowY))
arrow.stroke()
// 箭头头部
let head = NSBezierPath()
head.move(to: NSPoint(x: 396, y: arrowY - 9))
head.line(to: NSPoint(x: 414, y: arrowY))
head.line(to: NSPoint(x: 396, y: arrowY + 9))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

// ---------- 说明文字（箭头下方） ----------
draw("拖拽到 Applications 文件夹", x: 0, y: 160, size: 14, weight: .medium,
     color: NSColor(calibratedWhite: 0.30, alpha: 1), align: .center)

// ---------- 底部提示 ----------
draw("BinviaServer / BinviaCLI 命令行工具：curl 安装，见 GitHub Releases 说明", x: 0, y: 26,
     size: 10.5, weight: .regular, color: NSColor(calibratedWhite: 0.58, alpha: 1), align: .center)

NSGraphicsContext.restoreGraphicsState()

// ---------- 导出 PNG ----------
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/dmg-background.png"
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outPath))
print("background written: \(outPath) (\(Int(W * scale))x\(Int(H * scale)))")
