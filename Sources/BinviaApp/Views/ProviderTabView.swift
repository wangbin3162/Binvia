import AppKit
import SwiftUI
import BinviaCore

/// 主面板单个 provider 详情 Tab（Phase 23.4）：
/// 头部行 → 用量卡片 → 本地统计 → 最近请求 → 操作按钮。
struct ProviderTabView: View {
    let providerID: String
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let descriptor = ProviderRegistry.shared.descriptor(for: providerID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow(descriptor)
                    Divider()
                    usageSection
                    Divider()
                    localStatsSection
                    Divider()
                    modelCountsSection
                    Divider()
                    RecentRequestsView(providerID: providerID)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    Divider()
                    actionSection(descriptor)
                }
                // 上报内容完整自然高度（放在 ScrollView 内容内部，取完整高度而非可视区）
                .reportContentHeight()
            }
            // 内容超出可滚动，但隐藏滚动条（含 AppKit 兜底，兼容 MenuBarExtra 窗口）
            .hiddenScrollIndicators()
        }
    }

    // MARK: - 头部行（对齐 SettingsProviderPane.headerRow 精简版，移除启用开关）

    private func headerRow(_ descriptor: ProviderDescriptor) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderBrandIcon(providerID: descriptor.id, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.title3.weight(.semibold))
                Text(appState.providerSubtitle(providerID))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                SettingsWindowController.shared.show(appState: appState, pane: .provider(providerID))
            } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .help("配置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 用量卡片

    /// 有快照或声明了网页看板 → 展示共享组件 `ProviderUsageCard`；否则展示占位。
    @ViewBuilder
    private var usageSection: some View {
        let hasCard = appState.usageSnapshots[providerID] != nil
            || ProviderRegistry.shared.descriptor(for: providerID)?.usageDashboardURL != nil
        VStack(alignment: .leading, spacing: 6) {
            Text("用量")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if hasCard {
                ProviderUsageCard(providerID: providerID)
            } else {
                Text("暂无用量数据")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 本地统计（req / err / token）

    private var localStatsSection: some View {
        let usage = appState.usageSummary.byProvider[providerID]
        let errorCount = usage?.errorCount ?? 0
        let prompt = usage?.totalPromptTokens ?? 0
        let completion = usage?.totalCompletionTokens ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("本地统计")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Text("请求 \(usage?.requestCount ?? 0)")
                    .font(.callout)
                    .monospacedDigit()
                if errorCount > 0 {
                    Text("错误 \(errorCount)")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .monospacedDigit()
                }
                Spacer()
            }
            if prompt > 0 || completion > 0 {
                Text("token：prompt \(ProviderHealthRow.compactTokenText(prompt)) · completion \(ProviderHealthRow.compactTokenText(completion))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 模型调用次数（usage.models：model → 请求数，按次数降序）

    /// 无模型维度数据时不渲染（避免空分区占位）。
    @ViewBuilder
    private var modelCountsSection: some View {
        let models = appState.usageSummary.byProvider[providerID]?.models ?? [:]
        if !models.isEmpty {
            let sorted = models.sorted { $0.value > $1.value }
            VStack(alignment: .leading, spacing: 4) {
                Text("模型调用次数")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(sorted, id: \.key) { model, count in
                    HStack(spacing: 8) {
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 操作

    private func actionSection(_ descriptor: ProviderDescriptor) -> some View {
        HStack(spacing: 8) {
            Button("测试连接") {
                Task { await appState.testProvider(providerID) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()

            if let url = descriptor.usageDashboardURL {
                Button("在网页查看") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            }

            testStateIndicator

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var testStateIndicator: some View {
        switch appState.testStates[providerID] ?? .idle {
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("测试中…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        case .idle:
            EmptyView()
        }
    }
}
