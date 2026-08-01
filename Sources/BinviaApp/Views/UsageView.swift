import SwiftUI
import BinviaCore

/// 用量统计区：展示各 provider 的请求/错误计数汇总（菜单面板中的紧凑区块）。
struct UsageView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if appState.usageSummary.byProvider.isEmpty {
                Text("暂无请求记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ForEach(providerRows, id: \.key) { row in
                    rowView(row)
                }
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            appState.startMetricsRefresh()
            appState.startUsageRefresh()
        }
        .onDisappear {
            appState.stopMetricsRefresh()
            appState.stopUsageRefresh()
        }
    }

    private var totalRequests: Int {
        appState.usageSummary.byProvider.values.reduce(0) { $0 + $1.requestCount }
    }

    private var totalErrors: Int {
        appState.usageSummary.byProvider.values.reduce(0) { $0 + $1.errorCount }
    }

    /// 按请求数降序排列的 provider 用量列表。
    private var providerRows: [(key: String, value: ProviderUsage)] {
        appState.usageSummary.byProvider.sorted { $0.value.requestCount > $1.value.requestCount }
    }

    private var header: some View {
        HStack {
            Text("Usage").font(.headline)
            Spacer()
            Text("\(totalRequests) reqs · \(totalErrors) err")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
    }

    private func rowView(_ row: (key: String, value: ProviderUsage)) -> some View {
        HStack {
            Text(row.key).font(.callout)
            Spacer()
            Text("\(row.value.requestCount) reqs")
                .font(.caption)
                .foregroundStyle(.secondary)
            if row.value.errorCount > 0 {
                Text("\(row.value.errorCount) err")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
    }
}
