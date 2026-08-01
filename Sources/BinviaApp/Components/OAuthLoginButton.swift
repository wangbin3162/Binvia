import SwiftUI

/// OAuth / 设备码登录按钮：根据 `oauthStates[providerID]` 显示不同状态。
struct OAuthLoginButton: View {
    let providerID: String
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.oauthStates[providerID] ?? .idle {
        case .connected:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已连接")
                    .foregroundStyle(.secondary)
                Button("重新登录") { startLogin() }
                    .buttonStyle(.plain)
                    .help("重新登录")
            }
        case .requestingCode:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在打开浏览器…")
                    .foregroundStyle(.secondary)
            }
        case .waitingForAuth:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("请在浏览器中完成授权…")
                    .foregroundStyle(.secondary)
            }
        case .waitingForCodeInput:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("请在浏览器完成授权后，在弹窗中粘贴授权码")
                    .foregroundStyle(.secondary)
            }
        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("重试") { startLogin() }
                    .help("重新尝试登录")
            }
        case .idle:
            Button("登录") { startLogin() }
                .help("使用 OAuth 登录")
        }
    }

    private func startLogin() {
        if providerID == "codebuddy-cn" {
            Task { await appState.loginCodeBuddy() }
        } else if providerID == "antigravity" {
            Task { await appState.loginAntigravity() }
        }
    }
}
