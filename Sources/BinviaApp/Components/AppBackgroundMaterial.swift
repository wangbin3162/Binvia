import AppKit
import SwiftUI

/// 统一的应用背景材质（借鉴 CodexBar `SettingsSidebarMaterial`）：
/// 主面板（MenuBarExtra 弹出窗口）与设置窗口共用同一份 `.sidebar` 材质，
/// 保证两处背景颜色一致、轻微半透明（材质随系统深浅色自适应）。
struct AppBackgroundMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
    }
}
