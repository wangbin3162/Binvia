import AppKit
import SwiftUI

/// 全局应用委托：把应用设为 accessory（仅菜单栏，不占 Dock），并支持 `--smoke-test`。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if CommandLine.arguments.contains("--smoke-test") {
            Task { @MainActor in
                await AppState.runSmokeTest()
            }
        }
    }
}

@main
struct BinviaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(appState)
                .frame(width: 320)
        } label: {
            // 用固定稍大尺寸的模板图替代默认 systemImage（默认偏小）
            Image(nsImage: Self.menuBarIcon(running: appState.isServerRunning))
        }
        .menuBarExtraStyle(.window)

        // 注：不注册 `Settings` 场景 —— 菜单栏应用中该场景不可靠（窗口打不开），
        // 设置窗口由 SettingsWindowController 自建（NSWindow + NSHostingController）。
    }

    /// 菜单栏图标：SF Symbol 以 16pt 渲染成模板图（略大于默认尺寸）。
    /// 运行/停止切换 `bolt.shield.fill` / `bolt.shield`。
    private static func menuBarIcon(running: Bool) -> NSImage {
        let name = running ? "bolt.shield.fill" : "bolt.shield"
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: "Binvia") else {
            return NSImage()
        }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }
}
