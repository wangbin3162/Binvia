import AppKit
import SwiftUI

/// 设置窗口「网关密钥」面板：网关 API Key 列表 + 复制/删除 + 生成新 Key。
/// 样式与 CodexBar `Form` `.grouped` 一致。
struct SettingsGatewayKeysPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var copiedKey: String?

    var body: some View {
        Form {
            Section {
                if appState.config.apiKeys.isEmpty {
                    Text("尚未配置网关 Key")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.config.apiKeys, id: \.self) { key in
                        keyRow(key)
                    }
                }
            } header: {
                Text("网关 API Key")
            } footer: {
                Text("这些 Key 用于访问本地 OpenAI 兼容接口（/v1/chat/completions、/v1/models）时的认证：Authorization: Bearer <key>。")
            }

            Section {
                Button {
                    _ = appState.addGatewayKey()
                } label: {
                    Label("生成新 Key", systemImage: "plus")
                }
                .pointingHandCursor()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// 单个 Key 行：遮蔽显示 + 复制（带“已复制”反馈） + 删除。
    private func keyRow(_ key: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .foregroundStyle(.secondary)
            Text("sk-tg-••••\(key.suffix(4))")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key, forType: .string)
                copiedKey = key
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copiedKey = nil
                }
            } label: {
                if copiedKey == key {
                    Text("已复制")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .help("复制完整 Key")

            Button {
                appState.removeGatewayKey(key)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .help("删除此 Key")
        }
    }
}
