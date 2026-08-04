import AppKit
import SwiftUI

/// 设置窗口管理器。
///
/// 菜单栏应用中依赖 SwiftUI `Settings` 场景 + `SettingsLink`/`showSettingsWindow:` 不可靠
/// （裸可执行文件下场景不注册，窗口打不开）。这里直接用 `NSWindow` + `NSHostingController`
/// 承载 `SettingsView`，行为完全可控，与 bundle 与否无关。
///
/// 通过共享的 `SettingsSelectionModel` 支持“窗口已存在时切换目标面板”
/// （例如从菜单栏点某个 Provider 的齿轮，直接打开该 Provider 的配置面板）。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selectionModel = SettingsSelectionModel(pane: .general)

    private init() {}

    /// 打开（或前置）设置窗口，并选中指定面板。
    func show(appState: AppState, pane: SettingsPane = .general) {
        selectionModel.pane = pane
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(selectionModel: selectionModel).environmentObject(appState))
        let w = NSWindow(contentViewController: hosting)
        w.title = "Binvia Settings"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // 统一半透明材质背景：窗口非不透明 + 透明 titlebar，让 `AppBackgroundMaterial`
        // （sidebar 材质）真正透出模糊，并延伸到标题栏区域（edge-to-edge，对齐 CodexBar）。
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        w.isOpaque = false
        w.backgroundColor = .clear
        if !w.styleMask.contains(.fullSizeContentView) {
            w.styleMask.insert(.fullSizeContentView)
        }
        w.setContentSize(
            NSSize(
                width: SettingsWindowMetrics.windowWidth,
                height: SettingsWindowMetrics.windowHeight))
        w.minSize = NSSize(
            width: SettingsWindowMetrics.windowMinWidth,
            height: SettingsWindowMetrics.windowMinHeight)
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
