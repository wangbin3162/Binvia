import SwiftUI
import BinviaCore

/// OpenCode / OpenCode Go 网页会话 Cookie 凭据块（Phase 24，参考 `CodeBuddyUsageCredentials`）：
/// 会话 Cookie（SecureField）+ Workspace（可选）+ 保存 / 清除。
///
/// Cookie 用于用量/余额查询（`_server` RPC / dashboard 抓取）。从浏览器开发者工具
/// 「网络」面板复制请求的 `Cookie` 头粘贴；保存时仅保留 `auth` / `__Host-auth` 两项
/// （见 `OpenCodeCookieConfig.filteredHeader`），不落盘其他跟踪 Cookie。
/// Workspace 可跳过 workspace 自动发现，接受 `wrk_...` 或完整 URL。
struct OpenCodeCookieCredentials: View {
    let providerID: String

    @EnvironmentObject private var appState: AppState

    @State private var cookie = ""
    @State private var workspace = ""
    @State private var credentialMessage: String?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("会话 Cookie") {
                APIKeyInputField(title: "auth=... 或直接粘贴 Cookie 值", text: $cookie)
            }

            LabeledContent("Workspace（可选）") {
                APIKeyInputField(title: "wrk_... 或完整 URL", text: $workspace)
            }

            HStack(spacing: 8) {
                Text("仅保存 auth / __Host-auth，用于用量/余额查询")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if let msg = credentialMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("失败") ? .red : .green)
                }
                Spacer()
                Button("保存") { saveCredentials() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                Button("清除") { clearCredentials() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .disabled(cookie.isEmpty && workspace.isEmpty)
            }
        }
        .onAppear(perform: loadCredentials)
    }

    private func loadCredentials() {
        guard !didLoad else { return }
        didLoad = true
        guard let pc = appState.config.providers[providerID] else {
            cookie = ""
            workspace = ""
            return
        }
        cookie = pc.credential.cookieHeader ?? ""
        workspace = pc.credential.workspaceId ?? ""
    }

    private func saveCredentials() {
        appState.setCookieHeader(cookie, for: providerID)
        appState.setOpenCodeWorkspace(workspace, for: providerID)
        credentialMessage = "已保存"
    }

    private func clearCredentials() {
        cookie = ""
        workspace = ""
        appState.setCookieHeader(nil, for: providerID)
        appState.setOpenCodeWorkspace(nil, for: providerID)
        credentialMessage = "已清除"
    }
}
