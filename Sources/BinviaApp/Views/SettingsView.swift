import AppKit
import SwiftUI

/// 设置窗口：左侧栏（服务器 / 网关密钥 / 供应商）+ 右侧详情面板。
/// 整体布局与 CodexBar `PreferencesView` 一致（sidebar + Divider + detailView）。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var selectionModel: SettingsSelectionModel

    /// 详情区背景：浅色模式用浅灰（比纯白 `windowBackgroundColor` 略灰，与侧栏材质区分更清晰）；
    /// 深色模式沿用系统窗口底色。分割线色块与详情区同色，保证接缝一致。
    private static let detailBackground: Color = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(white: 0.15, alpha: 1)
            }
            return NSColor(white: 0.955, alpha: 1)
        }
    )

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebarView(selectionModel: selectionModel)
                .frame(width: SettingsWindowMetrics.sidebarWidth)
                .background {
                    // 侧栏保持 sidebar 材质（参考原 CodexBar 风格）
                    AppBackgroundMaterial()
                        .ignoresSafeArea()
                }

            // 分割线：用不透明色块替代 SwiftUI Divider（Divider 在透明窗口中
            // 背景透明，会透出桌面壁纸；改为与详情区背景色一致的不透明色块）。
            Self.detailBackground
                .frame(width: 1)
                .ignoresSafeArea(.all, edges: .vertical)

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 详情区背景为浅灰色（略灰于标准窗口背景色），与侧栏材质区分
                .background {
                    Self.detailBackground
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
        case .about:
            SettingsAboutPane()
        case let .provider(id):
            SettingsProviderPane(providerID: id)
                .id(id)
        }
    }
}
