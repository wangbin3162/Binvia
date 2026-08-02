import AppKit
import SwiftUI

/// 菜单栏弹出面板主视图。
///
/// 注意：`MenuBarExtra(.window)` 中不能可靠使用 `SettingsLink`（窗口打不开）与 `.sheet`
/// （macOS 14.6+ 点击 sheet 会导致面板消失）。因此：
/// - 设置改为自建 `NSWindow`（SettingsWindowController），与场景注册无关；
/// - Provider 配置统一收敛到设置窗口：点 Provider 行/齿轮即打开设置面板对应页。
struct MenuPanelView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            homeContent
        }
        .onAppear {
            appState.startMetricsRefresh()
            appState.startUsageRefresh()
            appState.startOAuthRefresh()
            Task { @MainActor in
                await appState.bootstrapOAuth()
            }
        }
    }

    // MARK: - 首页内容

    private var homeContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "bolt.shield")
                    .foregroundStyle(.tint)
                Text("Binvia")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ServerStatusView()

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ProviderListView { id in
                        SettingsWindowController.shared.show(appState: appState, pane: .provider(id))
                    }
                    Divider()
                    APIKeyManagerView()
                }
            }
            .frame(maxHeight: 420)

            Divider()

            UsageView()

            Divider()

            footer
        }
    }

    // MARK: - 底部操作

    /// 底部按钮行（对齐 CodexBar 菜单的 Settings / Quit 风格）：
    /// 图标 + 文字 + 悬停高亮 + 小手光标。
    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                openSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .imageScale(.medium)
                        .frame(width: 18, alignment: .center)
                    Text("设置")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                // 让整个悬停高亮区域（含 padding）都可点击，否则只有图标/文字本身命中
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("打开设置")

            Spacer()

            Button {
                appState.stopServer()
                NSApp.terminate(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.rectangle")
                        .imageScale(.medium)
                        .frame(width: 18, alignment: .center)
                    Text("退出")
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                // 同设置按钮：让整个悬停区域可点击
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("退出 Binvia")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// 打开设置窗口。`SettingsLink` 与 `showSettingsWindow:` 在 MenuBarExtra 中不可靠，
    /// 改用自建的 `NSWindow` + `NSHostingController`（见 SettingsWindowController）。
    private func openSettings() {
        SettingsWindowController.shared.show(appState: appState)
    }
}
