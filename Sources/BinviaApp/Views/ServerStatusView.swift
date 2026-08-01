import SwiftUI

/// 服务器状态区：状态灯 + 状态文字 + 启停按钮。
struct ServerStatusView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(
                color: appState.isServerRunning ? BadgeColor.running : BadgeColor.stopped,
                tooltip: appState.isServerRunning ? "运行中" : "已停止"
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.isServerRunning
                     ? "Running on :\(appState.config.port)"
                     : "Stopped")
                    .font(.system(.body, weight: .medium))

                if let err = appState.serverError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(appState.isServerRunning ? "Stop" : "Start") {
                appState.toggleServer()
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.isServerRunning ? .red : .accentColor)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
