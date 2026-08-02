import AppKit
import SwiftUI
import BinviaCore

/// 设置窗口「网关密钥」面板：网关 API Key 列表 + 复制/删除/模型白名单 + 生成新 Key。
/// 样式与 CodexBar `Form` `.grouped` 一致。
///
/// Phase 19：模型白名单从「手动输入文本」改为「下拉勾选」——
/// 列出全部已启用供应商的模型（`<alias>/<modelID>`），勾选即保存，无需手写格式。
struct SettingsGatewayKeysPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var copiedKey: String?
    /// 全部可选模型（`<alias>/<modelID>`），onAppear 时加载。
    @State private var allModelOptions: [GatewayModelOption] = []
    @State private var loadingModels = false
    /// 各 key 的勾选状态（key → 已勾选的 `<alias>/<modelID>` 集合）。
    @State private var selectedModels: [String: Set<String>] = [:]
    /// 各 key 是否处于「限制模型」编辑模式（未点应用也立即显示勾选列表）。
    @State private var limitedMode: Set<String> = []
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
        .onAppear {
            loadAllModels()
        }
    }

    /// 单个 Key 行：遮蔽显示 + 复制（带“已复制”反馈） + 删除 + 模型白名单勾选。
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

            // 模型白名单（Phase 12 需求 2：每 gateway key 独立白名单；Phase 19：下拉勾选）
            DisclosureGroup(isExpanded: Binding(
                get: { expandedKeys.contains(key) },
                set: { newValue in
                    if newValue {
                        expandedKeys.insert(key)
                        // 展开时：已有白名单 → 进入限制模式并预填勾选；全部启用 → 保持勾选模式隐藏
                        if gateway.enabledModels != nil {
                            limitedMode.insert(key)
                            if selectedModels[key] == nil {
                                selectedModels[key] = Set(gateway.enabledModels ?? [])
                            }
                        }
                    } else {
                        expandedKeys.remove(key)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    // 全部启用开关：开 → 不限制（nil）；关 → 进入模型勾选模式
                    Toggle("全部启用（不限制模型）", isOn: allEnabledBinding(for: gateway))
                        .font(.caption)
                        .toggleStyle(.switch)
                        .controlSize(.mini)

                    if limitedMode.contains(key) {
                        // 模型勾选列表（来自全部已启用供应商的静态目录 + 动态模型）
                        if loadingModels && allModelOptions.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("加载模型列表…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else if allModelOptions.isEmpty {
                            HStack(spacing: 6) {
                                Text("暂无可用模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("重新加载") { loadAllModels() }
                                    .buttonStyle(.link)
                                    .controlSize(.small)
                                    .pointingHandCursor()
                            }
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(groupedOptions.enumerated()), id: \.element.providerID) { (index, group) in
                                        if index > 0 {
                                            Divider()
                                                .padding(.vertical, 2)
                                        }
                                        HStack(spacing: 4) {
                                            ProviderBrandIcon(providerID: group.providerID, size: 12)
                                            Text(group.label)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .padding(.top, index == 0 ? 0 : 4)
                                        ForEach(group.options) { option in
                                            modelToggleRow(key: key, option: option)
                                        }
                                    }
                                }
                                .padding(.trailing, 4)
                            }
                            .frame(maxHeight: 180)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                            Text("已选 \(selectedModels[key]?.count ?? 0) / \(allModelOptions.count) 个模型")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

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
                            .disabled(!limitedMode.contains(key))
                            .pointingHandCursor()
                        Button("清除（全部启用）") {
                            appState.setGatewayKeyEnabledModels(key, enabledModels: nil)
                            limitedMode.remove(key)
                            selectedModels[key] = nil
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
            .disclosurePointingHand(isExpanded: expandedKeys.contains(key))
        }
        .padding(.vertical, 4)
    }

    /// 「全部启用」开关：开 → 保存 nil（不限制）；关 → 进入勾选模式。
    private func allEnabledBinding(for gateway: GatewayKeyConfig) -> Binding<Bool> {
        let key = gateway.key
        return Binding(
            get: { !limitedMode.contains(key) && gateway.enabledModels == nil },
            set: { isOn in
                if isOn {
                    appState.setGatewayKeyEnabledModels(key, enabledModels: nil)
                    limitedMode.remove(key)
                    selectedModels[key] = nil
                    saveMessages[key] = "已保存（全部启用）"
                } else {
                    // 进入限制模式：预填当前白名单（或从空开始）
                    limitedMode.insert(key)
                    if selectedModels[key] == nil {
                        selectedModels[key] = Set(gateway.enabledModels ?? [])
                    }
                    saveMessages[key] = nil
                }
            }
        )
    }

    /// 单个模型勾选行。
    private func modelToggleRow(key: String, option: GatewayModelOption) -> some View {
        let selected = selectedModels[key] ?? []
        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { selected.contains(option.id) },
                set: { isOn in
                    var set = selectedModels[key] ?? []
                    if isOn {
                        set.insert(option.id)
                    } else {
                        set.remove(option.id)
                    }
                    selectedModels[key] = set
                }
            ))
            .labelsHidden()
            .controlSize(.mini)
            Text(option.id)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    /// 保存勾选结果。
    private func applyWhitelist(_ key: String) {
        let models = (selectedModels[key] ?? []).sorted()
        appState.setGatewayKeyEnabledModels(key, enabledModels: models)
        saveMessages[key] = models.isEmpty ? "已保存（未选择任何模型）" : "已保存（\(models.count) 个模型）"
    }

    // MARK: - 模型列表加载

    /// 按 provider 分组的模型选项（用于白名单勾选列表的分割线分组）。
    /// 组顺序跟随 `config.providerOrder`，组内按模型 id 字母序。
    private var groupedOptions: [ProviderModelGroup] {
        let byProvider = Dictionary(grouping: allModelOptions, by: \.providerID)
        return appState.orderedProviderDescriptors()
            .compactMap { descriptor in
                guard let opts = byProvider[descriptor.id], !opts.isEmpty else { return nil }
                let sorted = opts.sorted { $0.modelID < $1.modelID }
                return ProviderModelGroup(
                    providerID: descriptor.id,
                    label: descriptor.displayName,
                    options: sorted
                )
            }
    }

    /// 加载全部「已启用且已配置凭据」供应商的模型：先静态目录（立即），再动态模型（异步补全）。
    /// 归一化格式 `<alias>/<modelID>` 与 RouteHandler.enforceEnabledModels 一致。
    /// 未接入（无凭据）或未启用的供应商模型不展示（避免白名单中出现不可用模型）。
    @MainActor
    private func loadAllModels() {
        guard !loadingModels else { return }
        loadingModels = true

        let isIncluded: (ProviderDescriptor) -> Bool = { descriptor in
            let enabled = appState.config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id)
            return enabled && appState.isProviderConfigured(descriptor.id)
        }

        var options: [GatewayModelOption] = []
        var seen = Set<String>()
        for descriptor in ProviderRegistry.shared.allDescriptors() where isIncluded(descriptor) {
            let alias = descriptor.alias ?? descriptor.id
            for model in descriptor.models {
                let normalized = "\(alias)/\(model.id)"
                guard seen.insert(normalized).inserted else { continue }
                options.append(GatewayModelOption(id: normalized, providerID: descriptor.id, modelID: model.id))
            }
        }
        allModelOptions = options.sorted { $0.id < $1.id }

        Task {
            for descriptor in ProviderRegistry.shared.allDescriptors() where isIncluded(descriptor) {
                guard let provider = ProviderRegistry.shared.provider(for: descriptor.id) else { continue }
                let alias = descriptor.alias ?? descriptor.id
                let dynamic = (try? await provider.listModels(credential: appState.config.credential(for: descriptor.id))) ?? []
                guard !dynamic.isEmpty else { continue }
                var merged = allModelOptions
                var mergedSeen = Set(merged.map(\.id))
                for model in dynamic {
                    let normalized = "\(alias)/\(model.id)"
                    guard mergedSeen.insert(normalized).inserted else { continue }
                    merged.append(GatewayModelOption(id: normalized, providerID: descriptor.id, modelID: model.id))
                }
                allModelOptions = merged.sorted { $0.id < $1.id }
            }
            loadingModels = false
        }
    }
}

/// 白名单下拉勾选的单个模型项。
private struct GatewayModelOption: Identifiable, Equatable {
    /// 归一化 id：`<alias>/<modelID>`。
    let id: String
    let providerID: String
    let modelID: String
}

/// 白名单勾选列表中按 provider 分组的模型集合（用于分割线分组展示）。
private struct ProviderModelGroup: Identifiable, Equatable {
    let providerID: String
    let label: String
    let options: [GatewayModelOption]
    var id: String { providerID }
}
