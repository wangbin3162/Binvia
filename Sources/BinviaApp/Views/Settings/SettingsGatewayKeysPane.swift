import AppKit
import SwiftUI
import BinviaCore

/// 设置窗口「网关密钥」面板：网关 API Key 列表 + 复制/删除/模型白名单 + 生成新 Key。
/// 样式与 CodexBar `Form` `.grouped` 一致。
struct SettingsGatewayKeysPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var copiedKey: String?
    /// 各 key 的模型白名单草稿（key → 原始文本，行分隔）。
    @State private var whitelistDrafts: [String: String] = [:]
    /// 各 key 是否展开白名单编辑。
    @State private var expandedKeys: Set<String> = []
    /// 各 key 的保存反馈。
    @State private var saveMessages: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                if appState.config.apiKeys.isEmpty {
                    Text("尚未配置网关 Key")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.config.apiKeys, id: \.key) { gateway in
                        keyRow(gateway)
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
            } footer: {
                Text("新生成的 Key 使用 sk-bv- 前缀；旧 sk-tg- Key 仍可鉴权（向后兼容）。")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// 单个 Key 行：遮蔽显示 + 复制（带“已复制”反馈） + 删除 + 模型白名单编辑。
    private func keyRow(_ gateway: GatewayKeyConfig) -> some View {
        let key = gateway.key
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                Text("\(String(key.prefix(5)))••••\(key.suffix(4))")
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

            // 模型白名单（Phase 12 需求 2：每 gateway key 独立白名单）
            DisclosureGroup(isExpanded: Binding(
                get: { expandedKeys.contains(key) },
                set: { newValue in
                    if newValue { expandedKeys.insert(key) } else { expandedKeys.remove(key) }
                }
            )) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("格式：每行一个模型，`<alias>/<modelID>`（如 ds/deepseek-v4-flash）。留空 = 全部启用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { whitelistDrafts[key] ?? whitelistText(for: gateway) },
                        set: { whitelistDrafts[key] = $0 }
                    ))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 64, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack {
                        if let msg = saveMessages[key] {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("已保存") ? .green : .red)
                        }
                        Spacer()
                        Button("应用白名单") { applyWhitelist(key) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .pointingHandCursor()
                        Button("清除（全部启用）") {
                            appState.setGatewayKeyEnabledModels(key, enabledModels: nil)
                            whitelistDrafts[key] = ""
                            saveMessages[key] = "已保存（全部启用）"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointingHandCursor()
                    }
                }
                .padding(.top, 4)
            } label: {
                Label(
                    gateway.enabledModels == nil ? "模型白名单：全部启用" : "模型白名单：\(gateway.enabledModels?.count ?? 0) 个模型",
                    systemImage: "checklist"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// 把网关 key 的已保存白名单转成多行文本（草稿未填时回退到这里）。
    private func whitelistText(for gateway: GatewayKeyConfig) -> String {
        (gateway.enabledModels ?? []).joined(separator: "\n")
    }

    private func applyWhitelist(_ key: String) {
        let raw = whitelistDrafts[key] ?? ""
        let models = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        appState.setGatewayKeyEnabledModels(key, enabledModels: models)
        saveMessages[key] = "已保存（\(models.count) 个模型）"
    }
}
