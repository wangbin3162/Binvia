import SwiftUI

/// 设置窗口的侧栏目的地：固定应用面板 + 每个 Provider 一项。
/// 结构借鉴 CodexBar `SettingsPane`。
enum SettingsPane: Hashable {
    case general
    case test
    case gatewayKeys
    case compatProviders
    case provider(String)

    /// 侧栏展示标题。
    var title: String {
        switch self {
        case .general: return "服务器"
        case .test: return "测试"
        case .gatewayKeys: return "网关密钥"
        case .compatProviders: return "自定义供应商"
        case let .provider(id): return id
        }
    }

    /// 侧栏 SF Symbol（仅用于固定面板；Provider 用品牌图标）。
    var systemImage: String? {
        switch self {
        case .general: return "gearshape"
        case .test: return "waveform"
        case .gatewayKeys: return "key.fill"
        case .compatProviders: return "plus.rectangle.on.rectangle"
        case .provider: return nil
        }
    }

    /// 侧栏图标主题色（仅用于固定面板）。
    var tint: SwiftUI.Color {
        switch self {
        case .general: return .blue
        case .test: return .purple
        case .gatewayKeys: return .orange
        case .compatProviders: return .green
        case .provider: return .accentColor
        }
    }
}

/// 设置窗口布局尺寸（借鉴 CodexBar `SettingsPane.windowWidth` 等）。
enum SettingsWindowMetrics {
    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 620
    static let windowMinWidth: CGFloat = 760
    static let windowMinHeight: CGFloat = 520
    static let sidebarWidth: CGFloat = 240
}

/// 设置窗口当前选中的面板。由 `SettingsWindowController` 持有，
/// 这样即使窗口已存在，也能在菜单栏点 Provider 齿轮时切换目标面板。
@MainActor
final class SettingsSelectionModel: ObservableObject {
    @Published var pane: SettingsPane

    init(pane: SettingsPane = .general) {
        self.pane = pane
    }
}
