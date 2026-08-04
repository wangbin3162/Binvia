import AppKit
import SwiftUI

/// 设置窗口：左侧栏（服务器 / 网关密钥 / 供应商）+ 右侧详情面板。
/// 整体布局与 CodexBar `PreferencesView` 一致（sidebar + Divider + detailView）。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var selectionModel: SettingsSelectionModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(selectionModel: selectionModel)
                .frame(width: SettingsWindowMetrics.sidebarWidth)
                .background {
                    // 侧栏保持 sidebar 材质（参考原 CodexBar 风格）
                    AppBackgroundMaterial()
                        .ignoresSafeArea()
                }

            Divider()
                .ignoresSafeArea()

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 详情区背景为浅白色（标准窗口背景色），与侧栏材质区分
                .background {
                    Color(nsColor: .windowBackgroundColor)
                        .ignoresSafeArea()
                }
        }
        .frame(
            minWidth: SettingsWindowMetrics.windowMinWidth,
            minHeight: SettingsWindowMetrics.windowMinHeight)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectionModel.pane {
        case .general:
            SettingsGeneralPane()
        case .test:
            SettingsTestPane()
        case .gatewayKeys:
            SettingsGatewayKeysPane()
        case .compatProviders:
            SettingsCompatProvidersPane()
        case let .provider(id):
            SettingsProviderPane(providerID: id)
                .id(id)
        }
    }
}
