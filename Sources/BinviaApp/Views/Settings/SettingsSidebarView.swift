import SwiftUI
import BinviaCore

/// 设置窗口侧栏（借鉴 CodexBar `SettingsSidebarView`）：
/// 固定应用面板（服务器 / 网关密钥）+ 供应商列表（品牌图标 + 配置状态圆点）。
struct SettingsSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var selectionModel: SettingsSelectionModel

    var body: some View {
        List(selection: selectionBinding) {
            Section {
                paneRow(.general)
                paneRow(.gatewayKeys)
                paneRow(.test)
            } header: {
                Text("通用")
            }

            Section {
                ForEach(providerDescriptors, id: \.id) { descriptor in
                    providerRow(descriptor)
                        .tag(SettingsPane.provider(descriptor.id))
                }
                .onMove { fromOffsets, toOffset in
                    appState.moveProvider(fromOffsets: fromOffsets, toOffset: toOffset)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("供应商")
                    Spacer()
                    Text("\(configuredCount)/\(providerDescriptors.count)")
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .padding(.trailing, 6)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { selectionModel.pane },
            set: { newValue in
                if let newValue {
                    selectionModel.pane = newValue
                }
            })
    }

    private var providerDescriptors: [ProviderDescriptor] {
        appState.orderedProviderDescriptors()
    }

    private var configuredCount: Int {
        providerDescriptors.filter { appState.isProviderConfigured($0.id) }.count
    }

    private func paneRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIconChip(systemImage: pane.systemImage ?? "circle", color: pane.tint)
        }
        .tag(pane)
    }

    private func providerRow(_ descriptor: ProviderDescriptor) -> some View {
        let enabled = appState.config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id)
        let configured = appState.isProviderConfigured(descriptor.id)
        return HStack(spacing: 8) {
            ProviderBrandIcon(providerID: descriptor.id, size: 16)
            Text(descriptor.displayName)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: 4)
            Circle()
                .fill(configured ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
                .help(configured ? "已配置" : "未配置")
        }
        .opacity(enabled ? 1 : 0.62)
        .contextMenu {
            Button(enabled ? "停用" : "启用") {
                appState.setProviderEnabled(!enabled, for: descriptor.id)
            }
        }
    }
}
