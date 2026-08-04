import AppKit
import SwiftUI

/// 统一的应用背景材质（借鉴 CodexBar `SettingsSidebarMaterial`）：
///
/// - 主面板（MenuBarExtra 弹出窗口）：`.menu` 材质 —— 对齐 CodexBar 原生 NSMenu 的菜单背景
///   （半透明、随桌面壁纸透色，深/浅色模式自适应）；
/// - 设置窗口侧栏：`.sidebar` 材质 —— 与 CodexBar `PreferencesView` 侧栏完全一致
///   （轻微半透明、边缘到边缘延伸到透明标题栏后方）。
struct AppBackgroundMaterial: NSViewRepresentable {
    /// 使用的 NSVisualEffectView 材质，默认 `.sidebar`（设置窗口侧栏风格）。
    var material: NSVisualEffectView.Material = .sidebar
    /// 材质不透明度（1 = 系统默认；调低让桌面壁纸更透，如菜单面板 0.8）。
    var opacity: Double = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.alphaValue = opacity
    }
}
