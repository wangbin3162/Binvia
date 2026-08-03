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
            ProviderBrandIcon(providerID: descriptor.id, size: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.body)
                captionLine
            }

            Spacer()

            Text("\(requestCount) req")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                onSettings()
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
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .hoverHighlight(cornerRadius: 0, hoverOpacity: 0.04)
        .onTapGesture {
            onTap()
        }
    }

    // MARK: - 副行

    /// 副行：关键用量 + token 聚合（如「¥ 12.34 · prompt 12.4K」）。
    private var captionLine: some View {
        HStack(spacing: 4) {
            Text(keyUsageText)
                .foregroundStyle(keyUsageIsError ? .red : .secondary)
            if !tokenAggregateText.isEmpty {
                Text("·")
                Text(tokenAggregateText)
            }
        }
        .font(.caption)
    }

    // MARK: - 数据派生

    private var providerUsage: ProviderUsage? {
        appState.usageSummary.byProvider[descriptor.id]
    }

    private var requestCount: Int {
        providerUsage?.requestCount ?? 0
    }

    /// 关键用量：余额 > 配额窗口首个 > 多 Key 余额首个 > 「—」。
    private var keyUsageText: String {
        guard let snapshot = appState.usageSnapshots[descriptor.id] else { return "—" }
        if let balance = snapshot.balance {
            return "\(balance) \(snapshot.currency ?? "")"
        }
        if let first = snapshot.quotaWindows.first {
            return "\(first.label) \(String(format: "%.0f", first.remainingPercentage))%"
        }
        if let first = snapshot.balances.first {
            return "\(first.balance) \(first.currency ?? "")"
        }
        return "—"
    }

    /// 快照存在但携带失败信息时用红色标记（提示用户进入详情查看）。
    private var keyUsageIsError: Bool {
        guard let snapshot = appState.usageSnapshots[descriptor.id] else { return false }
        return !(snapshot.error ?? "").isEmpty
    }

    /// token 聚合文本（prompt/completion 均为 0 时不展示）。
    private var tokenAggregateText: String {
        guard let usage = providerUsage,
              usage.totalPromptTokens > 0 || usage.totalCompletionTokens > 0 else { return "" }
        let prompt = Self.compactTokenText(usage.totalPromptTokens)
        let completion = Self.compactTokenText(usage.totalCompletionTokens)
        return "prompt \(prompt) · completion \(completion)"
    }

    /// 把 token 数压缩为可读文本：≥1000 用「X.XK」，否则原样。
    static func compactTokenText(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000)
        }
        return "\(count)"
    }
}
