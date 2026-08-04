import SwiftUI
import BinviaCore

/// 主面板「概况」Tab（Phase 23.3）：
/// ServerStatusView → Summary 卡片 → Provider 健康度列表。
///
/// 点击健康度行切换 SegmentedControl 到对应 provider Tab（由 `onSelectProvider` 回调驱动）。
struct OverviewTabView: View {
    let onSelectProvider: (String) -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ServerStatusView()
                Divider()
                summaryCard
                Divider()
                providerHealthList
            }
            // 上报内容完整自然高度（放在 ScrollView 内容内部，取完整高度而非可视区）
            .reportContentHeight()
        }
        // 内容超出可滚动，但隐藏滚动条（含 AppKit 兜底，兼容 MenuBarExtra 窗口）
        .hiddenScrollIndicators()
    }

    // MARK: - Summary 卡片

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                summaryMetric(title: "总请求", value: "\(appState.totalRequests)")
                summaryMetric(title: "错误", value: "\(appState.totalErrors)", tint: appState.totalErrors > 0 ? .red : .secondary)
                summaryMetric(title: "活跃", value: "\(appState.activeProviderCount)")
                Spacer()
            }
            tokenLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// token 汇总行：总 token：prompt X · completion Y（无数据时显示 —）。
    private var tokenLine: some View {
        let prompt = appState.totalPromptTokens
        let completion = appState.totalCompletionTokens
        let hasData = prompt > 0 || completion > 0
        return HStack(spacing: 4) {
            Text("总 token")
                .foregroundStyle(.secondary)
            if hasData {
                Text("prompt \(ProviderHealthRow.compactTokenText(prompt)) · completion \(ProviderHealthRow.compactTokenText(completion))")
                    .monospacedDigit()
            } else {
                Text("—")
            }
        }
        .font(.caption)
    }

    private func summaryMetric(title: String, value: String, tint: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Provider 健康度列表

    /// 概览列表最多展示的供应商数：超出则截断并提示去上方 Tab 查看。
    /// 目的：避免供应商较多时概览内容超高触发内部滚动条，造成概览区宽度收窄抖动。
    private static let maxOverviewRows = 6

    private var providerHealthList: some View {
        VStack(spacing: 0) {
            if appState.configuredProviders.isEmpty {
                Text("尚未配置任何供应商，点击右上角设置进行接入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            } else {
                ForEach(appState.configuredProviders.prefix(Self.maxOverviewRows), id: \.id) { descriptor in
                    ProviderHealthRow(
                        descriptor: descriptor,
                        onTap: { onSelectProvider(descriptor.id) },
                        onSettings: { openSettings(providerID: descriptor.id) }
                    )
                    Divider()
                }
                if appState.configuredProviders.count > Self.maxOverviewRows {
                    Text("还有 \(appState.configuredProviders.count - Self.maxOverviewRows) 个供应商，请在上方 Tab 查看")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    private func openSettings(providerID: String) {
        SettingsWindowController.shared.show(appState: appState, pane: .provider(providerID))
    }
}
