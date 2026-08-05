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
        if providerID == "codebuddy-cn" {
            // CodeBuddy：积分凭据区（登录/企业 ID）始终显示；
            // 登录并配置企业 ID 后，下方展示积分数据。
            VStack(alignment: .leading, spacing: 8) {
                codeBuddyUsageCredentials
                if let snapshot = appState.usageSnapshots[providerID] {
                    usageSnapshotContent(snapshot)
                } else {
                    codeBuddyUsagePlaceholder
                }
            }
        } else if let snapshot = appState.usageSnapshots[providerID] {
            usageSnapshotContent(snapshot)
        } else if let dashboard = ProviderRegistry.shared.descriptor(for: providerID)?.usageDashboardURL {
            // 无公开用量 API 的供应商（如 opencode）：提供官网入口。
            HStack(spacing: 8) {
                Label("未开放用量查询，请到网页查看", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("官网") {
                    NSWorkspace.shared.open(dashboard)
                }
                .buttonStyle(.link)
                .pointingHandCursor()
            }
        }
    }

    // MARK: - 快照内容

    /// 用量快照主体：刷新按钮 + 失败提示 + 余额 / 配额窗口 / 模型配额。
    private func usageSnapshotContent(_ snapshot: ProviderUsageSnapshot) -> some View {
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

            // 余额（CodexBar ProviderMetricInlineRow 风格：标签左 semibold，余额右 footnote）
            // 余额值统一绿色 + 币种符号（¥/$），与概览健康行一致。
            if !snapshot.balances.isEmpty {
                // 多 Key 余额：逐行展示（DeepSeek / Kimi 多 api-key）
                ForEach(Array(snapshot.balances.indices), id: \.self) { index in
                    let entry = snapshot.balances[index]
                    usageMetricRow(
                        label: entry.label,
                        value: balanceText(entry.balance, currency: entry.currency),
                        valueTint: .green
                    )
                }
            } else if let balance = snapshot.balance {
                usageMetricRow(
                    label: "余额",
                    value: balanceText(balance, currency: snapshot.currency),
                    valueTint: .green
                )
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
    }

    /// CodeBuddy 未登录/未出数据时的占位：提示 + 官网入口。
    private var codeBuddyUsagePlaceholder: some View {
        HStack(spacing: 8) {
            Label("登录并配置企业 ID 后可查看积分用量", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("官网") {
                if let url = ProviderRegistry.shared.descriptor(for: providerID)?.usageDashboardURL {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .pointingHandCursor()
        }
    }

    // MARK: - CodeBuddy 积分凭据区

    /// CodeBuddy 积分查询凭据：登录（OAuth 设备码）+ 企业 ID + Refresh Token。
    /// 说明：OAuth 登录 token 仅支持积分查询（企业账号），不参与模型调用——
    /// 模型调用 token 在设置面板「模型调用 Access Token」中配置。
    @State private var codeBuddyEnterpriseID = ""
    @State private var codeBuddyRefreshToken = ""
    @State private var codeBuddyCredentialMessage: String?
    @State private var didLoadCodeBuddyCredentials = false

    private var codeBuddyUsageCredentials: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 提示放在「刷新用量」上方
            Text("仅支持企业积分查询")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            OAuthLoginButton(providerID: "codebuddy-cn")

            LabeledContent("企业 ID") {
                APIKeyInputField(title: "积分查询（控制台 x-enterprise-id）", text: $codeBuddyEnterpriseID)
            }

            LabeledContent("Refresh Token") {
                APIKeyInputField(title: "刷新登录 Token（可选）", text: $codeBuddyRefreshToken)
            }

            HStack(spacing: 8) {
                if let msg = codeBuddyCredentialMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("失败") ? .red : .green)
                }
                Spacer()
                Button("保存") { saveCodeBuddyCredentials() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .onAppear(perform: loadCodeBuddyCredentials)
        .onChange(of: appState.config.providers[providerID]?.credential) { _, _ in
            // 重新登录后刷新草稿（企业 ID 保留、refreshToken 更新）
            loadCodeBuddyCredentials()
        }
    }

    private func loadCodeBuddyCredentials() {
        guard !didLoadCodeBuddyCredentials || codeBuddyEnterpriseID.isEmpty else {
            // 已加载且用户填过企业 ID 时，仅刷新 refreshToken（避免覆盖用户正在编辑的输入）
            if let pc = appState.config.providers["codebuddy-cn"] {
                codeBuddyRefreshToken = pc.credential.refreshToken ?? ""
            }
            return
        }
        guard let pc = appState.config.providers["codebuddy-cn"] else { return }
        codeBuddyEnterpriseID = pc.credential.workspaceId ?? ""
        codeBuddyRefreshToken = pc.credential.refreshToken ?? ""
        didLoadCodeBuddyCredentials = true
    }

    private func saveCodeBuddyCredentials() {
        let app = appState
        app.setEnterpriseID(codeBuddyEnterpriseID, for: "codebuddy-cn")
        do {
            try app.setRefreshToken(codeBuddyRefreshToken, for: "codebuddy-cn")
            codeBuddyCredentialMessage = "已保存"
        } catch {
            codeBuddyCredentialMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    // MARK: - 行组件

    /// 用量指标行（CodexBar ProviderMetricInlineRow 风格）：标签左 `.subheadline.weight(.semibold)`，
    /// 值右 `.footnote` `.monospacedDigit()`。`valueTint` 控制值颜色（余额行传绿色）。
    private func usageMetricRow(label: String, value: String, valueTint: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(.footnote)
                .foregroundStyle(valueTint)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }

    /// 单个配额窗口行：label + ProgressView + 百分比 + 重置时间。
    /// CodeBuddy 积分窗口额外展示总积分 / 已用积分。
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
                    // 重置时间带日期（仅时间如「重置 0:00」无意义）
                    Text("重置 \(Self.resetTimeText(resetAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: window.remainingFraction)
                .tint(progressColor(for: window.remainingFraction))
            // CodeBuddy 积分：展示总积分 / 已用积分
            if providerID == "codebuddy-cn", window.total > 0 {
                Text("总积分 \(window.total) · 已用 \(window.used)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// 重置时间展示：`MM-dd HH:mm`（如「08-21 00:00」）。
    private static func resetTimeText(_ date: Date) -> String {
        date.formatted(
            .dateTime
            .month(.twoDigits)
            .day(.twoDigits)
            .hour(.twoDigits(amPM: .omitted))
            .minute(.twoDigits)
        )
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

    /// 余额展示文本：币种符号 + 金额（CNY → ¥、USD → $），两位小数补齐。
    private func balanceText(_ balance: Decimal, currency: String?) -> String {
        UsageBalanceText.format(balance, currency: currency)
    }
}
