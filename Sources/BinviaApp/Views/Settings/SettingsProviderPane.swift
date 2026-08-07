import SwiftUI
import AppKit
import BinviaCore

/// 设置窗口的单个 Provider 配置面板。
///
/// 布局借鉴 CodexBar `ProviderDetailView`：头部行（品牌图标 + 名称 + 副标题 + 启用开关）、
/// 「连接」Section（按认证类型展示不同配置方式）、「连通性」Section、信息 Section。
/// 连接流程参考 OmniRoute `EditConnectionModal`：
/// - API Key 型：输入 Key → 测试连接 → 保存（支持多 Key 轮换）；
/// - OAuth 型：OAuth 登录（设备码 / PKCE）→ 状态展示 → 测试；另支持手动粘贴 Token。
struct SettingsProviderPane: View {
    let providerID: String
    @EnvironmentObject private var appState: AppState

    /// DeepSeek 多令牌草稿（带标签，CodexBar 令牌账户风格）。
    @State private var draftKeys: [KeyedToken] = []
    /// CodeBuddy 多 Access Token 草稿（首 token = 主 token，其余为轮换用）。
    @State private var draftTokens: [KeyedToken] = []
    /// 令牌添加行的标签输入。
    @State private var newTokenLabel = ""
    /// 令牌添加行的密钥输入。
    @State private var newTokenValue = ""
    /// OAuth (Antigravity) 手动 Token 草稿。
    @State private var manualToken = ""
    @State private var manualRefreshToken = ""
    /// CodeBuddy 企业 ID（积分查询用，存 credential.workspaceId）。
    @State private var tokenSaveMessage: String?
    /// 「手动配置」DisclosureGroup 展开状态（用于折叠态悬停小手光标）。
    @State private var isManualTokenExpanded = false

    /// 从上游获取的模型列表缓存（点击「获取模型列表」后填充，供添加模型时下拉选择）。
    @State private var fetchedModels: [Model] = []
    @State private var isFetchingModels = false
    @State private var fetchMessage: String?

    var body: some View {
        if appState.isShowingCodeInput {
            // Antigravity PKCE：等待用户在设置窗口中粘贴授权码。
            CodeInputSheet()
                .padding(20)
        } else if let descriptor = ProviderRegistry.shared.descriptor(for: providerID) {
            Form {
                // 第一个 Section：头部（logo + 名称 + 开关）+ 基础信息（仿 CodexBar ProviderDetailView）
                Section {
                    headerRow(descriptor)
                    infoSection(descriptor)
                }

                // 自定义 provider 无用量查询，隐藏用量 Section
                if !descriptor.isUserDefined {
                    codeBuddyCredentialsSection
                    usageSection
                }
                connectionSection(descriptor)
                modelsSection(descriptor)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                loadDrafts()
            }
            .onChange(of: appState.config.providers[providerID]?.credential) { _, _ in
                // 凭据变更时刷新令牌草稿（OAuth 登录后令牌列表即时反映新 token）；
                // 模型列表不自动拉取，留待「测试连接」时再刷新。
                loadDrafts()
            }
        } else {
            Text("未注册的 provider: \(providerID)")
                .foregroundStyle(.secondary)
                .padding(20)
        }
    }

    // MARK: - 头部行（CodexBar ProviderDetailHeaderRow）

    private func headerRow(_ descriptor: ProviderDescriptor) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // logo 28pt，对齐 CodexBar ProviderDetailBrandIcon
            ProviderBrandIcon(providerID: descriptor.id, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(descriptor.displayName)
                    .font(.title3.weight(.semibold))
                Text(appState.providerSubtitle(providerID))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("启用", isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(enabled ? "停用该供应商" : "启用该供应商")
        }
        .padding(.vertical, 2)
    }

    private var enabled: Bool {
        appState.config.providers[providerID]?.enabled ?? ProviderCatalog.isEnabledByDefault(providerID)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { appState.setProviderEnabled($0, for: providerID) })
    }

    /// 描述符声明的 API 区域选项（空 = 无区域选择）。
    private var regions: [ProviderAPIRegion] {
        ProviderRegistry.shared.descriptor(for: providerID)?.regions ?? []
    }

    /// 区域 Picker 绑定：config 值为 nil 时回退到首个区域（描述符默认）。
    private var regionBinding: Binding<String> {
        let current = appState.config.providers[providerID]?.region
        let fallback = regions.first?.id ?? ""
        return Binding(
            get: { current ?? fallback },
            set: { appState.setProviderRegion($0, for: providerID) }
        )
    }

    // MARK: - 连接 Section（按认证类型）

    @ViewBuilder
    private func connectionSection(_ descriptor: ProviderDescriptor) -> some View {
        switch descriptor.metadata.authType {
        case .apiKey, .localProbe:
            apiKeyConnectionSection
        case .deviceFlow:
            deviceFlowConnectionSection
        case .oauth:
            oauthConnectionSection
        }
    }

    /// DeepSeek：带标签 API 令牌列表（CodexBar 令牌账户风格）——已有令牌行 = 标签 + 掩码 + 移除；
    /// 常驻添加行 = 标签输入 + 密钥输入 + 「添加」按钮；添加/移除即时持久化。
    /// z.ai 等带区域选项的供应商在顶部渲染「API 区域」Picker。
    private var apiKeyConnectionSection: some View {
        Section {
            if !regions.isEmpty {
                Picker("API 区域", selection: regionBinding) {
                    ForEach(regions, id: \.id) { region in
                        Text(region.displayName).tag(region.id)
                    }
                }
            }

            if draftKeys.isEmpty {
                Text("暂无令牌")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(draftKeys.enumerated()), id: \.offset) { index, token in
                    tokenRow(label: token.label, value: token.value) {
                        draftKeys.remove(at: index)
                        persistAPIKeys()
                    }
                }
            }

            tokenAddRow(placeholder: "粘贴API密钥/Token") {
                addAPIKey()
            }

            HStack {
                Spacer()
                Button("测试连接") { startTest() }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
            }
        } header: {
            // 标题黑体：分区标题用粗体（默认 Form 小标题样式偏细，用户反馈 API 令牌标题不醒目）。
            Text("API 令牌")
                .font(.headline)
        } footer: {
            Text("请求会通过 Authorization: Bearer <key> 转发到 DeepSeek。保存后立即热更新。")
        }
    }

    /// 令牌添加行：标签输入框 + 密钥输入框 + 右侧「添加」按钮（对齐 CodexBar 令牌账户）。
    /// 标签框限宽 160；密钥框用 SecureField 撑满剩余宽度（无显示/隐藏切换）；按钮 .bordered .small。
    private func tokenAddRow(placeholder: String, onAdd: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField("", text: $newTokenLabel, prompt: Text("标签"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
                .frame(maxWidth: 160)
            SecureField("", text: $newTokenValue, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.footnote)
            Button("添加") { onAdd() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newTokenValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 单个令牌行：图标 + 标签 + 掩码值 + 右侧「移除」按钮（对齐 CodexBar 令牌账户）。
    private func tokenRow(label: String, value: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(KeyedToken.defaultLabel(for: value))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("移除") { onRemove() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// CodeBuddy：OAuth 设备码登录 + 手动 Access Token（支持多 token 轮换）。
    /// 令牌行样式对齐 DeepSeek 的 API 令牌列表（标签 + 掩码 + 移除，添加/移除即时持久化）。
    private var deviceFlowConnectionSection: some View {
        Section {
            if draftTokens.isEmpty {
                Text("暂无模型调用 Token")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(draftTokens.enumerated()), id: \.offset) { index, token in
                    tokenRow(label: token.label, value: token.value) {
                        draftTokens.remove(at: index)
                        persistDeviceTokens()
                    }
                }
            }

            tokenAddRow(placeholder: "粘贴Access Token") {
                addDeviceToken()
            }

            HStack {
                if let msg = tokenSaveMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(msg.contains("失败") ? .red : .green)
                }
                Spacer()
                Button("测试连接") { startTest() }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
            }
        } header: {
            Text("模型调用 Access Token")
        } footer: {
            Text("请求通过 Authorization: Bearer <access_token> 转发到腾讯 CodeBuddy；多个 token 自动轮换（首个 401/403 时试用下一个）。OAuth 登录 token 仅用于积分查询（见用量面板），不参与模型调用。")
        }
    }

    /// Antigravity：OAuth PKCE 登录（需粘贴授权码）+ 手动 Access/Refresh Token。
    private var oauthConnectionSection: some View {
        Section {
            OAuthLoginButton(providerID: providerID)

            DisclosureGroup("手动配置 Token", isExpanded: $isManualTokenExpanded) {
                // 每个 Token 一行：左侧固定标签 + 右侧输入框（LabeledContent 保证行间距，
                // 避免两个输入框贴在一起；标签明确 Access / Refresh 用途）。
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Access Token") {
                        APIKeyInputField(title: "粘贴 Access Token", text: $manualToken)
                    }
                    LabeledContent("Refresh Token") {
                        APIKeyInputField(title: "粘贴 Refresh Token（可选）", text: $manualRefreshToken)
                    }
                }
                .padding(.vertical, 4)

                HStack {
                    if let msg = tokenSaveMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.contains("失败") ? .red : .green)
                    }
                    Spacer()
                    Button("保存 Token") { saveManualToken() }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 2)
            }
            .disclosurePointingHand(isExpanded: isManualTokenExpanded)

            HStack {
                Spacer()
                Button("测试连接") { startTest() }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
            }
        } header: {
            Text("Access Token")
        } footer: {
            Text("使用 Google OAuth (PKCE) 登录：授权后在弹窗中粘贴授权码完成连接。也可手动粘贴 Token。")
        }
    }

    // MARK: - 模型列表

    /// 当前面板的模型列表（内置 provider 从 config.userModels 派生，自定义 provider 从 customProviderDef.models 派生）。
    private var modelEntries: [ProviderModelEntry] {
        if ProviderRegistry.shared.descriptor(for: providerID)?.isUserDefined == true {
            return appState.customProviderDef(for: providerID)?.models ?? []
        }
        return appState.userModels(for: providerID)
    }

    /// 「模型列表」Section：获取模型列表 + 添加模型按钮 + 模型行（显示名/模型名/上下文窗口 + 删除）。
    @ViewBuilder
    private func modelsSection(_ descriptor: ProviderDescriptor) -> some View {
        Section {
            // 获取模型列表 + 添加模型按钮
            modelActionsRow

            // 模型列表
            if modelEntries.isEmpty {
                Text("暂无模型，点击「+添加模型」新增")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                modelColumnsLayout
            }
        } header: {
            Text("模型列表")
        } footer: {
            if descriptor.isUserDefined {
                Text("调用时系统自动补上 provider 前缀。")
            } else {
                Text("点击「获取模型列表」从上游拉取，成功后可下拉选择模型名称。")
            }
        }
    }

    /// 模型列表按列布局，保证表头和输入框使用同一个 leading 起点。
    private var modelColumnsLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                modelColumnHeader("菜单显示名")
                ForEach(modelEntries) { entry in
                    leadingTextField(
                        text: displayNameBinding(for: entry),
                        prompt: "菜单显示名"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                modelColumnHeader("实际请求模型")
                ForEach(modelEntries) { entry in
                    modelNameField(entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                modelColumnHeader("上下文窗口")
                ForEach(modelEntries) { entry in
                    leadingTextField(
                        value: contextLengthBinding(for: entry)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Color.clear.frame(height: 17)
                ForEach(modelEntries) { entry in
                    Button(role: .destructive) {
                        removeModel(modelName: entry.modelName)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 4)
                    .help("删除模型")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 24)
        }
    }

    private func modelColumnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 17, alignment: .leading)
    }

    private func leadingTextField(text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .font(.footnote)
            .multilineTextAlignment(.leading)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leadingTextField(value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number)
            .font(.footnote)
            .multilineTextAlignment(.leading)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 120, alignment: .leading)
    }

    private func modelNameField(_ entry: ProviderModelEntry) -> some View {
        HStack(spacing: 4) {
            TextField("", text: modelNameBinding(for: entry), prompt: Text("实际请求模型"))
                .font(.footnote)
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 下拉选择固定占宽（无论是否已获取模型列表），避免获取列表后本列被挤压错位
            Group {
                if !fetchedModels.isEmpty {
                    Menu {
                        ForEach(fetchedModels) { fetched in
                            Button(fetched.id) {
                                updateEntryModelName(
                                    entry: entry,
                                    modelName: fetched.id,
                                    displayName: fetched.name ?? ""
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                    .help("选择已获取的模型")
                }
            }
            .frame(width: 16)
        }
    }

    /// 获取模型列表 + 添加模型按钮行。
    @ViewBuilder
    private var modelActionsRow: some View {
        HStack(spacing: 8) {
            if isFetchingModels {
                ProgressView().controlSize(.small)
                Text("获取中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("获取模型列表") { fetchModels() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                if let msg = fetchMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(msg.contains("失败") ? .red : .secondary)
                }
            }
            Spacer()
            Button {
                addBlankModel()
            } label: {
                Label("添加模型", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
        }
    }

    // MARK: - 模型列表操作

    /// 获取模型列表：调用供应商接口（CodeBuddy 返回静态列表），成功后缓存到面板。
    private func fetchModels() {
        guard let provider = ProviderRegistry.shared.provider(for: providerID) else {
            fetchMessage = "未注册的供应商"
            return
        }
        isFetchingModels = true
        fetchMessage = nil
        let credential = appState.config.credential(for: providerID)
        Task { @MainActor in
            do {
                let result = try await provider.listModels(credential: credential)
                fetchedModels = result
                isFetchingModels = false
                fetchMessage = "已获取 \(result.count) 个模型"
            } catch {
                isFetchingModels = false
                fetchMessage = "获取失败: \(error.localizedDescription)"
            }
        }
    }

    /// 添加一个空白模型条目。
    private func addBlankModel() {
        let entry = ProviderModelEntry(modelName: "")
        if ProviderRegistry.shared.descriptor(for: providerID)?.isUserDefined == true {
            try? appState.addCustomModel(providerID: providerID, entry: entry)
        } else {
            try? appState.addUserModel(entry, for: providerID)
        }
    }

    /// 删除一个模型条目。
    private func removeModel(modelName: String) {
        if ProviderRegistry.shared.descriptor(for: providerID)?.isUserDefined == true {
            try? appState.removeCustomModel(providerID: providerID, modelName: modelName)
        } else {
            try? appState.removeUserModel(modelName: modelName, for: providerID)
        }
    }

    /// 从下拉选择模型时，更新模型名并自动填充显示名（为空时用模型名）。
    private func updateEntryModelName(entry: ProviderModelEntry, modelName: String, displayName: String) {
        let newEntry = ProviderModelEntry(
            displayName: displayName.isEmpty ? modelName : displayName,
            modelName: modelName,
            contextLength: entry.contextLength
        )
        if ProviderRegistry.shared.descriptor(for: providerID)?.isUserDefined == true {
            try? appState.updateCustomModel(
                providerID: providerID,
                originalModelName: entry.modelName,
                entry: newEntry
            )
        } else {
            try? appState.updateUserModel(
                originalModelName: entry.modelName,
                entry: newEntry,
                for: providerID
            )
        }
    }

    // MARK: - 模型条目双向绑定

    private func displayNameBinding(for entry: ProviderModelEntry) -> Binding<String> {
        Binding(
            get: { entry.displayName },
            set: { newValue in
                updateEntryField(entry: entry, displayName: newValue, modelName: nil, contextLength: nil)
            }
        )
    }

    private func modelNameBinding(for entry: ProviderModelEntry) -> Binding<String> {
        Binding(
            get: { entry.modelName },
            set: { newValue in
                updateEntryField(entry: entry, displayName: nil, modelName: newValue, contextLength: nil)
            }
        )
    }

    private func contextLengthBinding(for entry: ProviderModelEntry) -> Binding<Int> {
        Binding(
            get: { entry.contextLength },
            set: { newValue in
                updateEntryField(entry: entry, displayName: nil, modelName: nil, contextLength: newValue)
            }
        )
    }

    /// 局部更新模型条目的某个字段（nil 表示不修改）。
    private func updateEntryField(entry: ProviderModelEntry, displayName: String?, modelName: String?, contextLength: Int?) {
        let newEntry = ProviderModelEntry(
            displayName: displayName ?? entry.displayName,
            modelName: modelName ?? entry.modelName,
            contextLength: contextLength ?? entry.contextLength
        )
        if ProviderRegistry.shared.descriptor(for: providerID)?.isUserDefined == true {
            try? appState.updateCustomModel(
                providerID: providerID,
                originalModelName: entry.modelName,
                entry: newEntry
            )
        } else {
            try? appState.updateUserModel(
                originalModelName: entry.modelName,
                entry: newEntry,
                for: providerID
            )
        }
    }

    // MARK: - 基础信息行（与头部同处一个 Section，无独立「信息」标题）

    /// 基础信息行：别名 / Base URL / 认证方式 / 已配置，紧跟 logo + 启用开关下方
    /// （对齐 CodexBar ProviderDetailInfoRows：同一 Section 内直接排布 LabeledContent）。
    @ViewBuilder
    private func infoSection(_ descriptor: ProviderDescriptor) -> some View {
        LabeledContent("别名") {
            Text(descriptor.alias ?? "—")
                .foregroundStyle(.secondary)
        }
        LabeledContent("Base URL") {
            Text(descriptor.baseURL?.absoluteString ?? "—")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        LabeledContent("认证方式") {
            Text(authTypeLabel(descriptor.metadata.authType))
                .foregroundStyle(.secondary)
        }
        LabeledContent("已配置") {
            let configured = isConfigured
            Text(configured ? "是" : "否")
                .foregroundStyle(configured ? .green : .secondary)
        }
    }

    /// 已配置判定。
    private var isConfigured: Bool {
        appState.isProviderConfigured(providerID)
    }

    private func authTypeLabel(_ type: ProviderAuthType) -> String {
        switch type {
        case .apiKey: "API Key"
        case .oauth: "OAuth (PKCE)"
        case .deviceFlow: "OAuth 设备码"
        case .localProbe: "本地探测"
        }
    }

    // MARK: - 用量 Section（Phase 16 / Phase 23.1）

    /// CodeBuddy 积分查询凭据：独立成「积分凭据」Section，置于「用量」上方。
    @ViewBuilder
    private var codeBuddyCredentialsSection: some View {
        if providerID == "codebuddy-cn" {
            Section {
                CodeBuddyUsageCredentials()
            } header: {
                Text("积分凭据")
            }
        }
    }

    /// 用量卡片：余额 / 配额窗口 / 模型配额。无快照时不展示（「有则展示无则隐藏」）；
    /// 供应商声明了 `usageDashboardURL` 且无公开用量 API 时，显示「官网」入口。
    /// Phase 23.1：渲染逻辑抽取到共享组件 `ProviderUsageCard`，行为与原实现一致。
    @ViewBuilder
    private var usageSection: some View {
        Section {
            ProviderUsageCard(providerID: providerID)
        } header: {
            Text("用量")
        }
    }

    // MARK: - Actions

    /// 首次显示时加载已有配置：DeepSeek 的令牌列表、deviceFlow 多 Token、oauth 的 Token 草稿。
    private func loadDrafts() {
        let pc = appState.config.providers[providerID]

        // apiKey：已保存的带标签令牌列表
        if draftKeys.isEmpty {
            if let tokens = pc?.apiKeys, !tokens.isEmpty {
                draftKeys = tokens
            } else if let key = pc?.credential.apiKey, !key.isEmpty {
                draftKeys = [KeyedToken(value: key)]
            }
        }

        // deviceFlow (CodeBuddy)：模型调用 token 列表（apiKeys）。
        // OAuth 登录 token 单独存于 credential（仅积分查询，见用量面板），不在此列表。
        if draftTokens.isEmpty, let stored = pc?.apiKeys, !stored.isEmpty {
            draftTokens = stored
        }

        // oauth (Antigravity)：单 token 草稿
        if manualToken.isEmpty, let token = pc?.credential.accessToken, !token.isEmpty,
           ProviderRegistry.shared.descriptor(for: providerID)?.metadata.authType == .oauth {
            manualToken = token
        }
    }

    /// 从添加行取标签+值构造 KeyedToken（空标签自动用掩码），并清空添加行。
    private func makeTokenFromAddRow() -> KeyedToken? {
        let label = newTokenLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = newTokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        newTokenLabel = ""
        newTokenValue = ""
        return KeyedToken(label: label.isEmpty ? KeyedToken.defaultLabel(for: value) : label, value: value)
    }

    private func addAPIKey() {
        guard let token = makeTokenFromAddRow() else { return }
        draftKeys.append(token)
        persistAPIKeys()
    }

    private func addDeviceToken() {
        guard let token = makeTokenFromAddRow() else { return }
        draftTokens.append(token)
        persistDeviceTokens()
    }

    private func persistAPIKeys() {
        try? appState.setTokens(draftKeys, for: providerID)
    }

    private func persistDeviceTokens() {
        do {
            // 模型调用 token 只写 apiKeys；登录 token（credential）不在此列表、不受影响
            try appState.setModelTokens(draftTokens, for: providerID)
            tokenSaveMessage = draftTokens.isEmpty ? nil : "已保存 \(draftTokens.count) 个 Token"
        } catch {
            tokenSaveMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    private func saveManualToken() {
        do {
            try appState.saveManualToken(
                accessToken: manualToken,
                refreshToken: manualRefreshToken,
                for: providerID)
            tokenSaveMessage = "已保存"
        } catch {
            tokenSaveMessage = "保存失败: \(error.localizedDescription)"
        }
    }

    private func startTest() {
        Task { @MainActor in
            await appState.testProvider(providerID)
        }
    }

}
