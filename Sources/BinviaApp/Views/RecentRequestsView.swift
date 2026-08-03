import SwiftUI
import BinviaCore

/// 最近请求列表（Phase 23.6）：展示最近请求的时间 / 模型 / token / 耗时 / 状态。
///
/// 数据源：`appState.recentEntries`（倒序最近 10 条，随 2s metrics 轮询刷新）。
/// `providerID` 非 nil 时仅展示该 provider 的条目（Provider Tab 场景）。
/// 流式请求的 token 在流结束才回填，期间显示「—」，下一轮刷新补上。
struct RecentRequestsView: View {
    /// nil = 展示全部 provider 的最近请求；非 nil = 仅展示该 provider。
    let providerID: String?
    @EnvironmentObject private var appState: AppState

    private var filtered: [RequestLogEntry] {
        guard let providerID else { return appState.recentEntries }
        return appState.recentEntries.filter { $0.providerID == providerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近请求")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if filtered.isEmpty {
                Text("暂无请求记录")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(filtered.prefix(6).enumerated()), id: \.element.id) { _, entry in
                    row(entry)
                }
            }
        }
    }

    // MARK: - 行

    private func row(_ entry: RequestLogEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Text(modelText(entry))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            Text(tokenText(entry))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Text(String(format: "%.1fs", entry.durationMS / 1000))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            statusIcon(entry)
        }
        .padding(.vertical, 1)
    }

    private func modelText(_ entry: RequestLogEntry) -> String {
        guard let providerID = entry.providerID else { return entry.path }
        let prefix = ProviderRegistry.shared.descriptor(for: providerID)?.alias ?? providerID
        if let model = entry.model, !model.isEmpty { return "\(prefix)/\(model)" }
        return prefix
    }

    private func tokenText(_ entry: RequestLogEntry) -> String {
        guard let tokens = entry.tokens else { return "—" }
        return "\(tokens.promptTokens)→\(tokens.completionTokens) tok"
    }

    @ViewBuilder
    private func statusIcon(_ entry: RequestLogEntry) -> some View {
        if entry.statusCode >= 400 || entry.error != nil {
            Text("✗ \(entry.statusCode)")
                .font(.caption2)
                .foregroundStyle(.red)
                .monospacedDigit()
        } else {
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.green)
        }
    }
}
