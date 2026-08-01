import SwiftUI

/// Antigravity PKCE 授权码输入表单（设置窗口内联展示，不再是独立 sheet）。
/// 由 `AppState.isShowingCodeInput` 驱动，在 SettingsProviderPane 内替换显示。
struct CodeInputSheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴授权码")
                .font(.headline)

            Text("请在浏览器完成授权后，把重定向地址或 authorization code 粘贴到这里。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://127.0.0.1:8325/callback?code=...", text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($focused)

            HStack {
                Spacer()
                Button("取消") {
                    appState.cancelAuthCode()
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button("提交") {
                    appState.submitAuthCode(input)
                }
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pointingHandCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            focused = true
        }
    }
}
