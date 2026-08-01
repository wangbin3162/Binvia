import SwiftUI

/// API Key 输入框：密码遮蔽 + 显示/隐藏切换。
struct APIKeyInputField: View {
    let title: String
    @Binding var text: String
    @State private var isRevealed = false

    init(title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack {
            if isRevealed {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "隐藏 Key" : "显示 Key")
        }
    }
}
