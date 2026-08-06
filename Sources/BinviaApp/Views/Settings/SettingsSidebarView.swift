import SwiftUI
import BinviaCore

/// 设置窗口侧栏（借鉴 CodexBar `SettingsSidebarView`）：
/// 固定应用面板（服务器 / 网关密钥）+ 供应商列表（品牌图标 + 配置状态圆点）。
///
/// 自定义供应商管理直接内嵌侧栏：
/// - 「供应商」区块右侧显示「已配置/内置」数量统计；
/// - 「自定义供应商」区块右侧的「+」按钮 → 在列表末尾新增一个自定义供应商；
/// - 自定义供应商行的别名 / Base URL 支持内联编辑（铅笔）与移除（垃圾桶，移除时清除相关模型与令牌）；
/// - 不再需要单独的「自定义供应商」配置面板。
struct SettingsSidebarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var selectionModel: SettingsSelectionModel

    // 新增自定义供应商内联表单
    @State private var isAddingCustomProvider = false
    @State private var newCustomName = ""
    @State private var newCustomBaseURL = ""
    @State private var addCustomError: String?

    // 自定义供应商行内编辑态
    @State private var editingCustomID: String?
    @State private var editCustomName = ""
    @State private var editCustomBaseURL = ""

    var body: some View {
        VStack(spacing: 0) {
            // fullSizeContentView 下 List 会滚动到透明标题栏区域，
            // 添加顶部占位让内容起始位置在交通灯按钮下方。
            Color.clear.frame(height: 28)

            List(selection: selectionBinding) {
                Section {
                    paneRow(.general)
                    paneRow(.gatewayKeys)
                    paneRow(.test)
                    paneRow(.about)
                } header: {
                    Text("通用")
                }

                Section {
                    ForEach(builtInDescriptors, id: \.id) { descriptor in
                        providerRow(descriptor)
                            .tag(SettingsPane.provider(descriptor.id))
                    }
                    .onMove { fromOffsets, toOffset in
                        moveBuiltInProvider(fromOffsets: fromOffsets, toOffset: toOffset)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("供应商")
                        Spacer()
                        Text("\(configuredBuiltInCount)/\(builtInDescriptors.count)")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .padding(.trailing, 4)
                    }
                }

                Section {
                    if isAddingCustomProvider {
                        addCustomProviderRow
                    }
                    ForEach(customDefs, id: \.id) { def in
                        if editingCustomID == def.id {
                            editCustomProviderRow(def)
                        } else {
                            customProviderRow(def)
                                .tag(SettingsPane.provider(def.id))
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("自定义供应商")
                        Spacer()
                        Button {
                            isAddingCustomProvider = true
                            editingCustomID = nil
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 4)
                        .help("新增自定义供应商")
                        .padding(.trailing, 4)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { selectionModel.pane },
            set: { newValue in
                if let newValue {
                    selectionModel.pane = newValue
                }
            })
    }

    /// 内置（非用户自定义）供应商，按 providerOrder 排序，支持拖拽重排。
    private var builtInDescriptors: [ProviderDescriptor] {
        appState.orderedProviderDescriptors().filter { !$0.isUserDefined }
    }

    /// 用户自定义供应商定义（按添加顺序）。
    private var customDefs: [CustomProviderDef] {
        appState.config.customProviderDefs
    }

    /// 已配置凭据的内置供应商数（「供应商」标题右侧统计）。
    private var configuredBuiltInCount: Int {
        builtInDescriptors.filter { appState.isProviderConfigured($0.id) }.count
    }

    private func paneRow(_ pane: SettingsPane) -> some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIconChip(systemImage: pane.systemImage ?? "circle", color: pane.tint)
        }
        .tag(pane)
    }

    private func providerRow(_ descriptor: ProviderDescriptor) -> some View {
        let enabled = appState.config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id)
        let configured = appState.isProviderConfigured(descriptor.id)
        return HStack(spacing: 8) {
            ProviderBrandIcon(providerID: descriptor.id, size: 16)
            Text(descriptor.displayName)
                .foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: 4)
            Circle()
                .fill(configured ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)
                .help(configured ? "已配置" : "未配置")
        }
        .opacity(enabled ? 1 : 0.62)
        .contextMenu {
            Button(enabled ? "停用" : "启用") {
                appState.setProviderEnabled(!enabled, for: descriptor.id)
            }
        }
    }

    // MARK: - 自定义供应商行

    /// 自定义供应商行：图标 + 别名 + Base URL + 编辑 / 移除。点击行打开该供应商的配置面板。
    private func customProviderRow(_ def: CustomProviderDef) -> some View {
        HStack(spacing: 8) {
            ProviderBrandIcon(providerID: def.id, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(def.displayName)
                    .font(.callout)
                Text(def.baseURL)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Button {
                editingCustomID = def.id
                editCustomName = def.displayName
                editCustomBaseURL = def.baseURL
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 3)
            .help("编辑别名 / Base URL")
            Button(role: .destructive) {
                removeCustomProvider(def)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 3)
            .help("移除（同时清除该供应商的模型与令牌）")
        }
        .padding(.vertical, 1)
    }

    /// 新增自定义供应商内联表单（+ 按钮触发，出现在自定义列表底部）。
    private var addCustomProviderRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $newCustomName, prompt: Text("别名"))
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            TextField("", text: $newCustomBaseURL, prompt: Text("Base URL，如 https://api.example.com/v1"))
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            if let addCustomError {
                Text(addCustomError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") {
                    isAddingCustomProvider = false
                    newCustomName = ""
                    newCustomBaseURL = ""
                    addCustomError = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                Button("添加") { addCustomProvider() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .disabled(!isAddFormValid)
            }
        }
        .padding(.vertical, 2)
    }

    /// 自定义供应商行内编辑表单（别名 / Base URL 可手动修改）。
    private func editCustomProviderRow(_ def: CustomProviderDef) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $editCustomName, prompt: Text("别名"))
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            TextField("", text: $editCustomBaseURL, prompt: Text("Base URL，如 https://api.example.com/v1"))
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            HStack {
                Spacer()
                Button("取消") {
                    editingCustomID = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                Button("保存") {
                    try? appState.updateCustomProvider(
                        id: def.id,
                        displayName: editCustomName,
                        baseURL: editCustomBaseURL)
                    editingCustomID = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
                .disabled(editCustomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }

    private var isAddFormValid: Bool {
        !newCustomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newCustomBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addCustomProvider() {
        addCustomError = nil
        do {
            if let def = try appState.addCustomProvider(name: newCustomName, baseURL: newCustomBaseURL) {
                newCustomName = ""
                newCustomBaseURL = ""
                isAddingCustomProvider = false
                selectionModel.pane = .provider(def.id)
            } else {
                addCustomError = "名称不能为空，且 Base URL 需为合法 http/https 地址"
            }
        } catch {
            addCustomError = error.localizedDescription
        }
    }

    private func removeCustomProvider(_ def: CustomProviderDef) {
        try? appState.deleteCustomProvider(id: def.id)
        // 若当前正在查看被删除的供应商，回到通用面板避免「未注册」空态
        if case .provider(let pid) = selectionModel.pane, pid == def.id {
            selectionModel.pane = .general
        }
        if editingCustomID == def.id {
            editingCustomID = nil
        }
    }

    // MARK: - 拖拽排序（仅内置供应商）

    /// 侧栏只展示内置供应商，拖拽时仅重排内置子集；自定义供应商与未列出 provider 保持相对顺序排在末尾。
    private func moveBuiltInProvider(fromOffsets: IndexSet, toOffset: Int) {
        var builtInIDs = builtInDescriptors.map(\.id)
        builtInIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let remainingIDs = ProviderRegistry.shared.allDescriptors()
            .map(\.id)
            .filter { !builtInIDs.contains($0) }
        appState.setProviderOrder(builtInIDs + remainingIDs)
    }
}
