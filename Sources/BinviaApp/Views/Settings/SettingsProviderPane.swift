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

    /// 模型列表与模型级测试状态。
    @State private var models: [Model] = []
    @State private var loadingModels = false
    /// 当前正在测试的模型 id（用于显示专属加载态）。
    @State private var testingModelID: String?
    /// 各模型的测试结果。
    @State private var modelTestResults: [String: ModelTestResult] = [:]

    /// 「测试全部模型」批量测试状态（Phase 13 需求 1：串行 + 进度条）。
    @State private var isTestingAll = false
    @State private var testAllCurrent = 0
    @State private var testAllTotal = 0
    @State private var testAllOutcomes: [ModelTestOutcome] = []

    /// 自定义 provider 的「添加模型」输入框草稿。
    @State private var newModelName = ""

    /// 单个模型的测试结果状态。
    enum ModelTestResult: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

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
                // 自定义 provider：可编辑模型列表（替代只读连通性 Section）
                if descriptor.isUserDefined {
                    customModelsSection
                } else {
                    testResultSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                loadDrafts()
                if !descriptor.isUserDefined {
                    loadModels()
                }
            }
            .onChange(of: appState.config.providers[providerID]?.credential) { _, _ in
                // 凭据变更时刷新模型列表与令牌草稿（OAuth 登录后令牌列表即时反映新 token）
                modelTestResults.removeAll()
                if !descriptor.isUserDefined {
                    loadModels()
                }
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

    // MARK: - 连通性测试结果（供应商级 + 模型级）

    @ViewBuilder
    private var testResultSection: some View {
        Section {
            // 供应商级测试
            providerTestRow

            // 测试全部模型（Phase 13 需求 1）
            testAllRow

            // 模型级测试列表
            if loadingModels {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("加载模型列表…").foregroundStyle(.secondary)
                }
            } else if models.isEmpty {
                Button("刷新模型列表") { loadModels() }
                    .buttonStyle(.link)
                    .pointingHandCursor()
            } else {
                ForEach(models) { model in
                    modelTestRow(model)
                }
            }
        } header: {
            Text("连通性")
        } footer: {
            Text("勾选 = 启用；取消勾选 = 禁用该模型（从 /v1/models、网关白名单与测试列表隐藏，仍可在本列表重新启用）。")
        }
    }

    /// 测试全部模型入口：未运行时显示按钮 + 上次批量测试汇总（结果保留在模型列表中）；
    /// 运行时显示进度条（各模型调用结果实时体现在下方模型列表中，不再单独列状态清单）。
    @ViewBuilder
    private var testAllRow: some View {
        if isTestingAll {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ProgressView(value: Double(testAllCurrent), total: Double(max(testAllTotal, 1)))
                        .controlSize(.small)
                    Text("测试全部模型：\(testAllCurrent)/\(testAllTotal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 8) {
                // 最前方：全部启用/禁用勾选（一键批量，避免逐行勾掉不需要的模型）
                allModelsToggle

                if !testAllOutcomes.isEmpty {
                    let successCount = testAllOutcomes.filter(\.success).count
                    let failedCount = testAllOutcomes.count - successCount
                    HStack(spacing: 8) {
                        Label("\(successCount) 成功", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("\(failedCount) 失败", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .font(.caption)
                    .padding(.vertical, 2)
                    Spacer()
                    Button("重新测试全部") { startTestAll() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .pointingHandCursor()
                } else {
                    Spacer()
                    Button("测试全部模型") { startTestAll() }
                        .buttonStyle(.bordered)
                        .disabled(models.isEmpty)
                        .pointingHandCursor()
                }
            }
        }
    }

    /// 「全部启用/禁用」勾选：勾选 = 启用该供应商全部模型；取消勾选 = 全部禁用。
    /// 勾选态取当前模型列表的「无任何禁用」，任一模型被禁用即变为未勾选。
    private var allModelsToggle: some View {
        let allEnabled = models.allSatisfy { !appState.isModelDisabled($0.id, for: providerID) }
        return HStack(spacing: 4) {
            Toggle("", isOn: Binding(
                get: { allEnabled },
                set: { enableAll in
                    // 批量操作，一次持久化（避免逐模型保存/热更新）
                    appState.setModelsDisabled(!enableAll, modelIDs: models.map(\.id), for: providerID)
                    modelTestResults.removeAll()
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            Text("全部启用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(allEnabled ? "取消勾选 = 禁用该供应商全部模型" : "勾选 = 启用该供应商全部模型")
        .disabled(models.isEmpty)
        .pointingHandCursor()
    }

    @ViewBuilder
    private var providerTestRow: some View {
        switch appState.testStates[providerID] ?? .idle {
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("供应商测试中…").foregroundStyle(.secondary)
            }
        case .ok(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(msg).font(.callout)
                Spacer()
                Button("重新测试") { startTest() }
                    .buttonStyle(.link).controlSize(.small)
                    .pointingHandCursor()
            }
        case .failed(let msg):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.callout)
                Spacer()
                Button("重新测试") { startTest() }
                    .buttonStyle(.link).controlSize(.small)
                    .pointingHandCursor()
            }
        case .idle:
            HStack {
                Spacer()
                Button("测试供应商") { startTest() }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
            }
        }
    }

    @ViewBuilder
    private func modelTestRow(_ model: Model) -> some View {
        let result = modelTestResults[model.id] ?? .idle
        let isDisabled = appState.isModelDisabled(model.id, for: providerID)
        HStack(alignment: .center, spacing: 6) {
            modelEnabledToggle(model.id)

            Text(model.id)
                .font(.callout)
                .foregroundStyle(isDisabled ? .tertiary : .secondary)
                .strikethrough(isDisabled)
                .frame(maxWidth: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(isDisabled ? "已禁用：从 /v1/models 与网关白名单隐藏（勾选可重新启用）" : "")

            if isDisabled {
                Spacer(minLength: 8)
                Text("已禁用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                switch result {
                case .testing:
                    ProgressView().controlSize(.small)
                case .ok(let msg):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                case .failed(let msg):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                    Text(msg).font(.caption2).foregroundStyle(.red)
                case .idle:
                    Spacer()
                    Button("测试") { startModelTest(model.id) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .pointingHandCursor()
                }
            }
        }
    }

    /// 模型行左侧「启用/禁用」勾选框（紧凑 checkbox）。
    /// 取消勾选 = 禁用：模型从 /v1/models、网关白名单与测试列表隐藏；
    /// 本列表仍保留（置灰 + 删除线）以便重新启用。
    private func modelEnabledToggle(_ modelID: String) -> some View {
        let enabled = !appState.isModelDisabled(modelID, for: providerID)
        return Toggle("", isOn: Binding(
            get: { !appState.isModelDisabled(modelID, for: providerID) },
            set: { isOn in
                appState.setModelDisabled(!isOn, modelID: modelID, for: providerID)
                // 禁用/启用后清除旧测试结果，避免重新启用时残留过期状态
                modelTestResults.removeValue(forKey: modelID)
            }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .controlSize(.mini)
        .help(enabled ? "禁用该模型（从 /v1/models 与网关白名单隐藏）" : "启用该模型")
        .pointingHandCursor()
    }

    // MARK: - 自定义 Provider 模型列表（可编辑）

    /// 自定义 provider 的模型列表（从 config 直接派生，只显示原始模型名）。响应式，无需 async 加载。
    /// 归一化：config 中的模型名若已带前缀（历史/误输入），先剥掉全部前缀。
    private var customModels: [Model] {
        let def = appState.customProviderDef(for: providerID)
        let prefix = "\(providerID)/"
        return def?.models.map { raw in
            var clean = raw
            while clean.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count))
            }
            return Model(id: clean)
        } ?? []
    }

    /// 自定义 provider 的「模型列表」Section：顶部添加模型输入 + 模型行（测试 / 删除）+ 供应商级测试。
    @ViewBuilder
    private var customModelsSection: some View {
        Section {
            // 供应商级测试
            providerTestRow

            // 添加模型行
            HStack(spacing: 8) {
                TextField("模型名（不含 provider/ 前缀）", text: $newModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .onSubmit { addCustomModel() }
                Button("添加") { addCustomModel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .disabled(newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 模型列表
            if customModels.isEmpty {
                Text("暂无模型，请在上方添加")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customModels) { model in
                    customModelRow(model)
                }
            }
        } header: {
            Text("模型列表")
        } footer: {
            Text("这里只填写原始模型名，例如 glm-5.2，不要填写 \(providerID)/glm-5.2；调用时系统会自动补上 provider 前缀。")
        }
    }

    @ViewBuilder
    private func customModelRow(_ model: Model) -> some View {
        let result = modelTestResults[model.id] ?? .idle
        let isDisabled = appState.isModelDisabled(model.id, for: providerID)
        HStack(alignment: .center, spacing: 6) {
            modelEnabledToggle(model.id)

            Text(model.id)
                .font(.callout)
                .foregroundStyle(isDisabled ? .tertiary : .secondary)
                .strikethrough(isDisabled)
                .frame(maxWidth: 180, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(isDisabled ? "已禁用：从 /v1/models 与网关白名单隐藏（勾选可重新启用）" : "")

            // 模型名后直接放弹性空白：状态区与删除按钮固定靠右，测试后删除按钮也始终在最右侧。
            Spacer(minLength: 8)

            if isDisabled {
                Text("已禁用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                switch result {
                case .testing:
                    ProgressView().controlSize(.small)
                case .ok(let msg):
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.footnote)
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                case .failed(let msg):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                    Text(msg).font(.caption2).foregroundStyle(.red)
                case .idle:
                    Button("测试") { startModelTest("\(providerID)/\(model.id)", resultKey: model.id) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .pointingHandCursor()
                }
            }

            if result != .testing {
                Button(role: .destructive) {
                    try? appState.removeCustomModel(providerID: providerID, model: model.id)
                    modelTestResults.removeValue(forKey: model.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .hoverHighlight(cornerRadius: 4)
                .help("删除模型")
            }
        }
    }

    private func addCustomModel() {
        let trimmed = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? appState.addCustomModel(providerID: providerID, model: trimmed)
        newModelName = ""
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
        Task { await appState.testProvider(providerID) }
    }

    // MARK: - 模型列表 & 模型级测试

    @MainActor
    private func loadModels() {
        guard let provider = ProviderRegistry.shared.provider(for: providerID) else {
            models = []
            return
        }
        loadingModels = true
        Task {
            let credential = appState.config.credential(for: providerID)
            let fetched = (try? await provider.listModels(credential: credential)) ?? []
            // 合并静态目录，避免动态获取失败时模型列表为空
            var merged = ProviderRegistry.shared.descriptor(for: providerID)?.models ?? []
            for m in fetched where !merged.contains(where: { $0.id == m.id }) {
                merged.append(m)
            }
            // 如果动态获取成功且非空，用动态结果；否则保留静态目录
            models = fetched.isEmpty ? merged : fetched
            loadingModels = false
        }
    }

    private func startModelTest(_ modelID: String, resultKey: String? = nil) {
        let key = resultKey ?? modelID
        modelTestResults[key] = .testing
        Task {
            await appState.testModel(modelID, for: providerID)
            // appState.testModel 把结果写到 testStates，我们同步一份到本地
            if let state = appState.testStates[providerID] {
                switch state {
                case .ok(let msg): modelTestResults[key] = .ok(msg)
                case .failed(let msg): modelTestResults[key] = .failed(msg)
                default: break
                }
            }
        }
    }

    // MARK: - 测试全部模型（Phase 13 需求 1）

    /// 串行测试该供应商全部模型，逐条更新进度与结果。
    /// 结果同步写入 `modelTestResults`，使每个模型行在测试结束后仍保留成功/失败状态。
    @MainActor
    private func startTestAll() {
        guard let provider = ProviderRegistry.shared.provider(for: providerID) else { return }
        isTestingAll = true
        testAllOutcomes = []
        modelTestResults.removeAll()
        testAllCurrent = 0
        testAllTotal = 0
        let credential = appState.config.credential(for: providerID)
        Task {
            let all = (try? await provider.listModels(credential: credential)) ?? []
            // 跳过已禁用的模型（设置面板「禁用」开关）
            let models = all.filter { !appState.isModelDisabled($0.id, for: providerID) }
            testAllTotal = models.count
            if models.isEmpty {
                testAllOutcomes.append(ModelTestOutcome(
                    modelID: "-",
                    success: false,
                    message: "未获取到模型列表"
                ))
                testAllCurrent = 0
                isTestingAll = false
                return
            }
            for (index, model) in models.enumerated() {
                modelTestResults[model.id] = .testing
                let outcome: ModelTestOutcome
                if let result = try? await provider.testModel(model.id, credential: credential) {
                    outcome = ModelTestOutcome(
                        modelID: model.id,
                        success: result.success,
                        message: result.message,
                        latencyMS: result.latencyMS
                    )
                } else {
                    outcome = ModelTestOutcome(
                        modelID: model.id,
                        success: false,
                        message: "测试抛出未预期错误"
                    )
                }
                testAllOutcomes.append(outcome)
                modelTestResults[model.id] = outcome.success ? .ok(outcome.message) : .failed(outcome.message)
                testAllCurrent = index + 1
            }
            // 动态模型与静态列表不一致时，补全模型行以便结果可见
            for outcome in testAllOutcomes where !models.contains(where: { $0.id == outcome.modelID }) {
                self.models.append(Model(id: outcome.modelID, name: outcome.modelID))
            }
            isTestingAll = false
        }
    }
}
