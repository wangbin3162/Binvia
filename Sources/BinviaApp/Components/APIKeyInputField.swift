import SwiftUI

/// API Key 输入框：密码遮蔽 + 显示/隐藏切换。
/// `title` 作为输入框内的占位提示（prompt）展示，仿「标签」输入框（`TextField("", prompt:)`）；
/// 外层 HStack 与内层字段均 `.frame(maxWidth: .infinity)`，在任何容器（Form / VStack）下都撑满剩余宽度。
/// `.font(.footnote)` 与「标签」字段对齐（仿 CodexBar）。
struct APIKeyInputField: View {
    let title: String
    @Binding var text: String
    @State private var isRevealed = false

    init(title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isRevealed {
                    TextField("", text: $text, prompt: Text(title))
                } else {
                    SecureField("", text: $text, prompt: Text(title))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.footnote)
            .frame(maxWidth: .infinity)
            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 3)
            .help(isRevealed ? "隐藏 Key" : "显示 Key")
        }
        .frame(maxWidth: .infinity)
    }
}
