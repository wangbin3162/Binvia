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
        MenuBarExtra("Binvia", systemImage: appState.statusIconName) {
            MenuPanelView()
                .environmentObject(appState)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)

        // 注：不注册 `Settings` 场景 —— 菜单栏应用中该场景不可靠（窗口打不开），
        // 设置窗口由 SettingsWindowController 自建（NSWindow + NSHostingController）。
    }
}
