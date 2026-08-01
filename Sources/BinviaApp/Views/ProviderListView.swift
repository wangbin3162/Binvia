import SwiftUI
import BinviaCore

/// Provider 列表区：每个 provider 一行，显示配置状态、请求数，点击行或齿轮进入配置详情。
/// 不用 `.sheet`（MenuBarExtra 中不可靠），通过 `onSelectProvider` 通知面板切换内容。
struct ProviderListView: View {
    @EnvironmentObject private var appState: AppState
    let onSelectProvider: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Providers")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(ProviderRegistry.shared.allDescriptors(), id: \.id) { descriptor in
                        row(for: descriptor)
                        Divider()
                    }
                }
            }
        }
    }

    private func row(for descriptor: ProviderDescriptor) -> some View {
        let configured = isConfigured(descriptor)
        let count = appState.usageSummary.byProvider[descriptor.id]?.requestCount ?? 0

        return HStack(spacing: 10) {
            StatusBadge(
                color: configured ? BadgeColor.connected : BadgeColor.unconfigured,
                tooltip: configured ? "已配置" : "未配置"
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.body)
                caption(for: descriptor, configured: configured)
            }

            Spacer()

            Text("\(count) reqs")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                onSelectProvider(descriptor.id)
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .help("配置")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0, hoverOpacity: 0.04)
        .onTapGesture {
            onSelectProvider(descriptor.id)
        }
    }

    /// 根据认证类型判断该 provider 是否已配置。
    private func isConfigured(_ descriptor: ProviderDescriptor) -> Bool {
        let pc = appState.config.providers[descriptor.id]
        switch descriptor.metadata.authType {
        case .apiKey, .localProbe:
            let hasKey = !(pc?.credential.apiKey ?? "").isEmpty
                || !(pc?.apiKeys ?? []).isEmpty
            return hasKey
        case .oauth, .deviceFlow:
            return !(pc?.credential.accessToken ?? "").isEmpty
        }
    }

    @ViewBuilder
    private func caption(for descriptor: ProviderDescriptor, configured: Bool) -> some View {
        switch descriptor.metadata.authType {
        case .apiKey, .localProbe:
            Text(configured ? "API Key" : "未配置 Key")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .oauth, .deviceFlow:
            Text(configured ? "OAuth 已连接" : "OAuth 未登录")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
