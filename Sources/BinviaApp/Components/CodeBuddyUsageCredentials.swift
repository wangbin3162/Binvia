import SwiftUI
import BinviaCore

/// CodeBuddy 积分查询凭据块（Phase 23.6 从 `ProviderUsageCard` 提取）：
/// OAuth 登录（设备码）+ 企业 ID + Refresh Token + 保存。
///
/// 说明：OAuth 登录 token 仅支持积分查询（企业账号），不参与模型调用——
/// 模型调用 token 在设置面板「模型调用 Access Token」中配置。
/// 主面板 CodeBuddy Tab 中置于「用量」卡片上方；设置面板独立成「积分凭据」Section，
/// 同样位于「用量」Section 上方。
struct CodeBuddyUsageCredentials: View {
    @EnvironmentObject private var appState: AppState

    @State private var enterpriseID = ""
    @State private var refreshToken = ""
    @State private var credentialMessage: String?
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 提示放在最上方
            Text("仅支持企业积分查询")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            OAuthLoginButton(providerID: "codebuddy-cn")

            LabeledContent("企业 ID") {
                APIKeyInputField(title: "积分查询（控制台 x-enterprise-id）", text: $enterpriseID)
            }

            LabeledContent("Refresh Token") {
                APIKeyInputField(title: "刷新登录 Token（可选）", text: $refreshToken)
            }

            HStack(spacing: 8) {
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
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .onAppear(perform: loadCredentials)
        .onChange(of: appState.config.providers["codebuddy-cn"]?.credential) { _, _ in
            // 重新登录后刷新草稿（企业 ID 保留、refreshToken 更新）
            loadCredentials()
        }
    }

    private func loadCredentials() {
        guard !didLoad || enterpriseID.isEmpty else {
            // 已加载且用户填过企业 ID 时，仅刷新 refreshToken（避免覆盖用户正在编辑的输入）
            if let pc = appState.config.providers["codebuddy-cn"] {
                refreshToken = pc.credential.refreshToken ?? ""
            }
            return
        }
        guard let pc = appState.config.providers["codebuddy-cn"] else { return }
        enterpriseID = pc.credential.workspaceId ?? ""
        refreshToken = pc.credential.refreshToken ?? ""
        didLoad = true
    }

    private func saveCredentials() {
        let app = appState
        app.setEnterpriseID(enterpriseID, for: "codebuddy-cn")
        do {
            try app.setRefreshToken(refreshToken, for: "codebuddy-cn")
            credentialMessage = "已保存"
        } catch {
            credentialMessage = "保存失败: \(error.localizedDescription)"
        }
    }
}
