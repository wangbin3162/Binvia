import AppKit
import SwiftUI

/// 菜单栏弹出面板主视图（Phase 23.5 重构 + 本期主面板调整）。
///
/// 信息架构：顶部 ProviderSwitcherView（概况 + 已配置 provider，对齐 CodexBar 多行换行切换器）
/// → 内容区（Overview 概况 Tab + 每个已配置 provider 的详情 Tab）
/// → 底部 Footer（网关密钥 / 设置 / 退出，对齐 CodexBar meta section）。
///
/// 注意：`MenuBarExtra(.window)` 中不能可靠使用 `SettingsLink`（窗口打不开）与 `.sheet`
/// （macOS 14.6+ 点击 sheet 会导致面板消失）。因此：
/// - 设置改为自建 `NSWindow`（SettingsWindowController）；
/// - 内容切换用 ProviderSwitcherView + `if/switch` 驱动（等价于「TabView 容器 + SegmentedControl」，
///   但避免 macOS 原生 `TabView` 顶部再渲染一条 tab strip，也规避 MenuBarExtra 中
///   TabView 高度跳变/闪烁风险；且 SegmentedControl 在供应商较多时会被压缩得不可用，
///   故改用可自动折行的按钮网格）。
///
/// 内容区高度自适应：ScrollView 内容通过 `reportContentHeight()` 上报完整自然高度，
/// 面板高度取 `min(内容高度, 上限)` —— 内容少时面板自动变矮，内容多时封顶内部滚动。
struct MenuPanelView: View {
    @EnvironmentObject private var appState: AppState

    /// 当前选中的 Tab：「overview」或已配置 provider 的 id。
    @State private var selectedTab: String = "overview"

    /// 内容区自然高度（由子视图测量上报）。
    @State private var contentHeight: CGFloat = 0

    /// 内容区高度上限：超过则内部滚动（MenuBarExtra 面板不可过高）。
    /// 供应商较多时允许面板继续长高（从 400 提升到 560），减少内部滚动。
    private static let maxContentHeight: CGFloat = 560

    /// 测量值未到达前的兜底高度，避免初始闪跳。
    private static let fallbackContentHeight: CGFloat = 260

    var body: some View {
        VStack(spacing: 0) {
            // 上部（Tab 页签 + 内容区）带整体面板内边距
            VStack(spacing: 0) {
                if !appState.configuredProviders.isEmpty {
                    tabPicker
                    // 与 CodexBar 一致：切换器下方紧跟分割线，而非内容区顶部
                    Divider()
                }
                tabContent
                    // 内容区高度自适应：取内容自然高度与上限的较小值。
                    // MenuBarExtra 窗口中 ScrollView 的理想高度会被算成 0（窗口会塌），
                    // 故用测量到的自然高度显式撑开；超出上限则内部滚动。
                    .frame(height: resolvedContentHeight)
                    .onPreferenceChange(ContentHeightPreferenceKey.self) { height in
                        contentHeight = height
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()
            // 底部设置条：设置 / 密钥 / 退出一排
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
        // 主面板背景：menu 材质（CodexBar 原生 NSMenu 的菜单背景，随桌面壁纸透色），
        // 透明度 0.8 让壁纸更透；与设置窗口侧栏的 sidebar 材质区分——菜单面板对齐原生菜单弹出层。
        .background {
            AppBackgroundMaterial(material: .menu, opacity: 0.55)
                .ignoresSafeArea()
        }
    }

    // MARK: - 内容区高度（自适应）

    private var resolvedContentHeight: CGFloat {
        guard contentHeight > 0 else { return Self.fallbackContentHeight }
        return min(contentHeight, Self.maxContentHeight)
    }

    // MARK: - 顶部 Provider 切换器（CodexBar 风格，超宽自动折行）

    private var tabPicker: some View {
        ProviderSwitcherView(providers: appState.configuredProviders, selection: $selectedTab)
    }

    // MARK: - 底部 Footer（设置 / 密钥 / 退出一排，对齐 CodexBar meta section）

    private var footer: some View {
        HStack(spacing: 0) {
            footerButton(systemName: "gearshape", title: "设置") {
                SettingsWindowController.shared.show(appState: appState, pane: .general)
            }
            footerButton(systemName: "key.fill", title: "密钥") {
                SettingsWindowController.shared.show(appState: appState, pane: .gatewayKeys)
            }
            Spacer()
            footerButton(systemName: "xmark.rectangle", title: "退出") {
                appState.stopServer()
                NSApp.terminate(nil)
            }
        }
        // 设置条边距：左右 6pt、顶部 8pt 与内容区隔开；底部 8pt 避免操作列贴边
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    /// 底部文字按钮：图标 + 文字 + 悬停高亮 + 小手光标。
    private func footerButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .imageScale(.medium)
                    .frame(width: 18, alignment: .center)
                Text(title)
                    .font(.callout)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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

// MARK: - 内容自然高度测量

/// 子视图把自身完整布局高度上报给 MenuPanelView，用于内容区自适应高度。
struct ContentHeightPreferenceKey: PreferenceKey {
    // get-only 计算属性：无可变全局存储，满足 StrictConcurrency
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 在视图底部挂一个测量视图，上报完整布局高度。
    /// 用法：`ScrollView { content }.reportContentHeight()`（或置于内容内部），
    /// 以拿到完整内容高度而非可视区高度。
    func reportContentHeight() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ContentHeightPreferenceKey.self,
                    value: proxy.size.height)
            }
        )
    }
}
