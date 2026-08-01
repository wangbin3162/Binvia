import AppKit
import SwiftUI

/// 网关 API Key 管理：展示、复制、删除，以及生成新 Key。
struct APIKeyManagerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var copiedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 区段标题
            HStack {
                Text("Gateway API Keys")
                    .font(.headline)
                Spacer()
                Button {
                    appState.addGatewayKey()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if appState.config.apiKeys.isEmpty {
                Text("尚未配置网关 Key，点击 New 生成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.config.apiKeys, id: \.self) { key in
                            keyRow(key)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 140)
            }

            // 底部说明
            Text("这些 Key 用于访问本地 API（如 /v1/chat/completions）时的认证。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    /// 单个 Key 行：遮蔽显示 + 复制 + 删除。
    @MainActor
    private func keyRow(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "key")
                .foregroundStyle(.secondary)
            Text("sk-tg-••••\(key.suffix(4))")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()

            // 复制按钮（带短暂"已复制"反馈）
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

            // 删除按钮
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
