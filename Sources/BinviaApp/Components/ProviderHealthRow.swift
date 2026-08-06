import SwiftUI
import BinviaCore

/// Overview Tab 中的 provider 健康度行（Phase 23.2）。
///
/// 每行展示：品牌图标 + 名称 + 关键用量（余额 > 配额窗口 > —）+ 本地请求计数 + 齿轮。
/// 关键用量从 `appState.usageSnapshots[id]` 派生；token 聚合从 `usageSummary.byProvider[id]` 派生。
/// 点击整行切换 SegmentedControl 到对应 provider Tab；齿轮打开设置面板对应 provider。
struct ProviderHealthRow: View {
    let descriptor: ProviderDescriptor
    let onTap: () -> Void
    let onSettings: () -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            ProviderBrandIcon(providerID: descriptor.id, size: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.displayName)
                    .font(.callout.weight(.medium))
                captionLine
            }

            Spacer()

            Button {
                onSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 3)
            .help("配置")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0, hoverOpacity: 0.04)
        .onTapGesture {
            onTap()
        }
    }

    // MARK: - 副行

    /// 副行：仅展示关键用量（余额 / 配额窗口）。
    private var captionLine: some View {
        HStack(spacing: 4) {
            Text(keyUsageText)
                .foregroundStyle(keyUsageTint)
        }
        .font(.caption)
    }

    // MARK: - 数据派生

    /// 关键用量：余额 > 配额窗口首个 > 多 Key 余额首个 > 「—」。余额用币种符号 + 两位小数（¥120.50）。
    private var keyUsageText: String {
        guard let snapshot = appState.usageSnapshots[descriptor.id] else { return "—" }
        if let balance = snapshot.balance {
            return UsageBalanceText.format(balance, currency: snapshot.currency)
        }
        if let first = snapshot.quotaWindows.first {
            return "\(first.label) \(String(format: "%.0f", first.remainingPercentage))%"
        }
        if let first = snapshot.balances.first {
            return UsageBalanceText.format(first.balance, currency: first.currency)
        }
        return "—"
    }

    /// 关键用量文字颜色：失败红；余额（DeepSeek / Kimi）绿；其余次要色。
    private var keyUsageTint: Color {
        if keyUsageIsError { return .red }
        if let snapshot = appState.usageSnapshots[descriptor.id],
           snapshot.balance != nil || !snapshot.balances.isEmpty {
            return .green
        }
        return .secondary
    }

    /// 快照存在但携带失败信息时用红色标记（提示用户进入详情查看）。
    private var keyUsageIsError: Bool {
        guard let snapshot = appState.usageSnapshots[descriptor.id] else { return false }
        return !(snapshot.error ?? "").isEmpty
    }

    /// 把 token 数压缩为可读文本：≥1000 用「X.XK」，否则原样。
    static func compactTokenText(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}
