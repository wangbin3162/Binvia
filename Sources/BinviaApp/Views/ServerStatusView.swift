import AppKit
import SwiftUI

/// 服务器状态区（概况 Tab 顶部）：Binvia logo + 服务地址（可复制）+ 状态灯 + 启停按钮。
///
/// 顶部用分割线与上方的 Provider 切换器分隔；服务运行时展示可复制的本地地址，
/// 停止时展示「服务已停止」。复制按钮带 1.5s 的「已复制」反馈。
struct ServerStatusView: View {
    @EnvironmentObject private var appState: AppState
    @State private var copied = false

    /// 对外展示的服务地址（与 `RouteHandler` 监听地址一致）。
    private var address: String {
        "http://\(appState.config.host):\(appState.config.port)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "bolt.shield")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 3) {
                    // 服务地址 + 复制按钮
                    HStack(spacing: 6) {
                        Text(appState.isServerRunning ? address : "服务已停止")
                            .font(.system(.body, weight: .medium))
                            .monospaced()
                            .foregroundStyle(appState.isServerRunning ? .primary : .secondary)
                        if appState.isServerRunning {
                            copyButton
                        }
                    }
                    // 状态灯 + 状态文字 + 错误信息
                    HStack(spacing: 5) {
                        StatusBadge(
                            color: appState.isServerRunning ? BadgeColor.running : BadgeColor.stopped,
                            tooltip: appState.isServerRunning ? "运行中" : "已停止"
                        )
                        Text(appState.isServerRunning ? "运行中" : "已停止")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let err = appState.serverError, !err.isEmpty {
                            Text("· \(err)")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }

                Spacer()

                Button(appState.isServerRunning ? "停止" : "启动") {
                    appState.toggleServer()
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isServerRunning ? .red : .accentColor)
                .controlSize(.small)
                .pointingHandCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: - 复制地址按钮（带「已复制」反馈）

    private var copyButton: some View {
        Button {
            copyAddress()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(copied ? .green : .secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("复制地址")
        .pointingHandCursor()
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.15)) { copied = false }
        }
    }
}
