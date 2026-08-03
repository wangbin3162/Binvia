import AppKit
import SwiftUI

/// 菜单栏弹出面板主视图（Phase 23.5 重构 + 本期主面板调整）。
///
/// 信息架构：TopBar（标题）→ 顶部 ProviderSwitcherView（概况 + 已配置 provider，
/// 对齐 CodexBar 多行换行切换器）→ 内容区（Overview 概况 Tab + 每个已配置 provider 的详情 Tab）
/// → 底部 Footer（网关密钥 / 设置 / 退出，对齐 CodexBar meta section）。
///
/// 注意：`MenuBarExtra(.window)` 中不能可靠使用 `SettingsLink`（窗口打不开）与 `.sheet`
/// （macOS 14.6+ 点击 sheet 会导致面板消失）。因此：
/// - 设置改为自建 `NSWindow`（SettingsWindowController）；
/// - 内容切换用 ProviderSwitcherView + `if/switch` 驱动（等价于「TabView 容器 + SegmentedControl」，
///   但避免 macOS 原生 `TabView` 顶部再渲染一条 tab strip，也规避 MenuBarExtra 中
///   TabView 高度跳变/闪烁风险；且 SegmentedControl 在供应商较多时会被压缩得不可用，
///   故改用可自动折行的按钮网格）。
struct MenuPanelView: View {
    @EnvironmentObject private var appState: AppState

    /// 当前选中的 Tab：「overview」或已配置 provider 的 id。
    @State private var selectedTab: String = "overview"

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !appState.configuredProviders.isEmpty {
                tabPicker
            }
            tabContent
                // 固定内容区高度：MenuBarExtra 窗口按内容理想尺寸撑窗口，
                // ScrollView 的理想高度在 MenuBarExtra 中会被算成 0（maxHeight 只设上限不设下限，
                // 会被压成 0），故用固定高度强制撑开，内容超出则内部滚动。
                .frame(height: 440)
            Divider()
            footer
        }
        .onAppear {
            appState.startMetricsRefresh()
            appState.startUsageRefresh()
            appState.startOAuthRefresh()
            Task { @MainActor in
                await appState.bootstrapOAuth()
            }
        }
        // §6.5：用户移除某 provider 后 `selectedTab` 可能指向不存在的 Tab，重置回 overview。
        .onChange(of: appState.configuredProviders.map(\.id)) { _, newIDs in
            if selectedTab != "overview" && !newIDs.contains(selectedTab) {
                selectedTab = "overview"
            }
        }
    }

    // MARK: - 顶部条（Logo + 文字上下排列；操作按钮统一放底部 Footer）

    private var topBar: some View {
        VStack(spacing: 4) {
            Image(systemName: "bolt.shield")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
            Text("Binvia")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - 顶部 Provider 切换器（CodexBar 风格，超宽自动折行）

    private var tabPicker: some View {
        ProviderSwitcherView(providers: appState.configuredProviders, selection: $selectedTab)
    }

    // MARK: - 底部 Footer（对齐 CodexBar meta section：网关密钥 / 设置 / 退出）

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton(systemName: "key.fill", title: "网关密钥") {
                SettingsWindowController.shared.show(appState: appState, pane: .gatewayKeys)
            }
            footerButton(systemName: "gearshape", title: "设置") {
                SettingsWindowController.shared.show(appState: appState, pane: .general)
            }
            footerButton(systemName: "xmark.rectangle", title: "退出") {
                appState.stopServer()
                NSApp.terminate(nil)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    /// 底部文字按钮：图标 + 文字 + 悬停高亮 + 小手光标。
    private func footerButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .imageScale(.medium)
                    .frame(width: 18, alignment: .center)
                Text(title)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // 让整个悬停高亮区域（含 padding）都可点击，否则只有图标/文字本身命中
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: 5)
        .help(title)
    }

    // MARK: - Tab 内容

    @ViewBuilder
    private var tabContent: some View {
        if selectedTab == "overview" {
            OverviewTabView { providerID in
                selectedTab = providerID
            }
        } else if let descriptor = appState.configuredProviders.first(where: { $0.id == selectedTab }) {
            ProviderTabView(providerID: descriptor.id)
        } else {
            // 兜底：selectedTab 指向已不存在的 provider（如刚被移除），显示概况
            OverviewTabView { providerID in
                selectedTab = providerID
            }
        }
    }
}
