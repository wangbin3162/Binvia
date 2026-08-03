import AppKit
import SwiftUI
import BinviaCore

/// 用量卡片共享组件（Phase 23.1 从 `SettingsProviderPane.usageSection` 抽取）：
/// 余额 / 配额窗口 / 模型配额 + 失败提示 + 刷新按钮。
/// 设置面板与主面板 Provider Tab 共用，避免重复实现。
///
/// 语义（对齐 Phase 16「有则展示无则隐藏」）：
/// - 有快照：展示快照内容（余额逐行 / 配额窗口 / 模型配额）；
/// - 无快照但供应商声明了 `usageDashboardURL`：展示网页看板入口；
/// - 两者皆无：不渲染（调用方自行展示「暂无用量数据」占位）。
struct ProviderUsageCard: View {
    let providerID: String
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let snapshot = appState.usageSnapshots[providerID] {
            VStack(alignment: .leading, spacing: 8) {
                // 刷新按钮
                HStack {
                    Spacer()
                    Button("刷新用量") { refreshUsage() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointingHandCursor()
                }

                // 失败提示
                if let error = snapshot.error, !error.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                        Spacer()
                        Button("刷新") { refreshUsage() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .pointingHandCursor()
                    }
                }

                // 余额（CodexBar ProviderMetricInlineRow 风格：标签左 semibold，余额右 footnote secondary）
                if !snapshot.balances.isEmpty {
                    // 多 Key 余额：逐行展示（DeepSeek 多 api-key）
                    ForEach(Array(snapshot.balances.indices), id: \.self) { index in
                        let entry = snapshot.balances[index]
                        usageMetricRow(label: entry.label, value: balanceText(entry.balance, currency: entry.currency))
                    }
                } else if let balance = snapshot.balance {
                    usageMetricRow(label: "余额", value: balanceText(balance, currency: snapshot.currency))
                }

                // 配额窗口
                if !snapshot.quotaWindows.isEmpty {
                    ForEach(Array(snapshot.quotaWindows.indices), id: \.self) { index in
                        quotaWindowRow(snapshot.quotaWindows[index])
                    }
                }

                // 模型配额
                if !snapshot.modelQuotas.isEmpty {
                    ForEach(Array(snapshot.modelQuotas.indices), id: \.self) { index in
                        modelQuotaRow(snapshot.modelQuotas[index])
                    }
                }
            }
        } else if let dashboard = ProviderRegistry.shared.descriptor(for: providerID)?.usageDashboardURL {
            // 无公开用量 API 的供应商（如 opencode）：提供网页看板入口。
            HStack(spacing: 8) {
                Label("上游暂未开放用量 API，可在网页查看余额。", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("在网页查看") {
                    NSWorkspace.shared.open(dashboard)
                }
                .buttonStyle(.link)
                .pointingHandCursor()
            }
        }
    }

    // MARK: - 行组件

    /// 用量指标行（CodexBar ProviderMetricInlineRow 风格）：标签左 `.subheadline.weight(.semibold)`，
    /// 值右 `.footnote` `.secondary` `.monospacedDigit()`。
    private func usageMetricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }

    /// 单个配额窗口行：label + ProgressView + 百分比 + 重置时间。
    private func quotaWindowRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(String(format: "%.0f", window.remainingPercentage))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetAt = window.resetAt {
                    Text("重置 \(resetAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: window.remainingFraction)
                .tint(progressColor(for: window.remainingFraction))
        }
        .padding(.vertical, 2)
    }

    /// 单个模型配额行：modelID + ProgressView + 百分比。
    private func modelQuotaRow(_ quota: ModelQuota) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quota.modelID)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(String(format: "%.0f", quota.remainingPercentage))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetAt = quota.resetAt {
                    Text("重置 \(resetAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: quota.remainingFraction)
                .tint(progressColor(for: quota.remainingFraction))
        }
        .padding(.vertical, 2)
    }

    /// 剩余比例 → 进度条颜色（健康绿 / 告警橙 / 危险红）。
    private func progressColor(for fraction: Double) -> Color {
        if fraction >= 0.5 { return .green }
        if fraction >= 0.2 { return .orange }
        return .red
    }

    private func refreshUsage() {
        Task { await appState.refreshUsageNow(for: providerID) }
    }

    /// 余额展示文本（先拼成 String 再交给 Text，避免 LocalizedStringKey 对 Decimal 插值告警）。
    private func balanceText(_ balance: Decimal, currency: String?) -> String {
        "\(balance) \(currency ?? "")"
    }
}
