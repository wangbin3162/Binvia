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
                    SettingsSidebarMaterial()
                        .ignoresSafeArea()
                }

            Divider()
                .ignoresSafeArea()

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case let .provider(id):
            SettingsProviderPane(providerID: id)
                .id(id)
        }
    }
}

/// 侧栏材质（借鉴 CodexBar `SettingsSidebarMaterial`）：edge-to-edge 的 sidebar 材质。
private struct SettingsSidebarMaterial: NSViewRepresentable {
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
