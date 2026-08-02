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

                usageSection
                connectionSection(descriptor)
                testResultSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                loadDrafts()
                loadModels()
            }
            .onChange(of: appState.config.providers[providerID]?.credential) { _, _ in
                // 凭据变更时刷新模型列表与令牌草稿（OAuth 登录后令牌列表即时反映新 token）
                modelTestResults.removeAll()
                loadModels()
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
                Divider()
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
            Text("API 令牌")
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
            OAuthLoginButton(providerID: providerID)

            if draftTokens.isEmpty {
                Text("暂无令牌")
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

            // refreshToken 与首 token 配套保存（仅首 token 专用）。
            APIKeyInputField(title: "Refresh Token（可选，用于刷新首 Token）", text: $manualRefreshToken)

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
            Text("Access Token")
        } footer: {
            Text("请求会通过 Authorization: Bearer <access_token> 转发到腾讯 CodeBuddy。多 token 轮换：首个 token 失败（401/403）时自动试用下一个。")
        }
    }

    /// Antigravity：OAuth PKCE 登录（需粘贴授权码）+ 手动 Access/Refresh Token。
    private var oauthConnectionSection: some View {
        Section {
            OAuthLoginButton(providerID: providerID)

            DisclosureGroup("手动配置 Token", isExpanded: $isManualTokenExpanded) {
                APIKeyInputField(title: "Access Token", text: $manualToken)
                APIKeyInputField(title: "Refresh Token", text: $manualRefreshToken)
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
            HStack {
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
        HStack(alignment: .top, spacing: 6) {
            Text(model.id)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 160, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)

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
            let configured = appState.isProviderConfigured(providerID)
            Text(configured ? "是" : "否")
                .foregroundStyle(configured ? .green : .secondary)
        }
    }

    private func authTypeLabel(_ type: ProviderAuthType) -> String {
        switch type {
        case .apiKey: "API Key"
        case .oauth: "OAuth (PKCE)"
        case .deviceFlow: "OAuth 设备码"
        case .localProbe: "本地探测"
        }
    }

    // MARK: - 用量 Section（Phase 16）

    /// 用量卡片：余额 / 配额窗口 / 模型配额。无快照时不展示（「有则展示无则隐藏」）；
    /// 供应商声明了 `usageDashboardURL` 且无公开用量 API 时，显示「在网页查看」入口。
    @ViewBuilder
    private var usageSection: some View {
        if let snapshot = appState.usageSnapshots[providerID] {
            Section {
                // 刷新按钮
                HStack {
                    Spacer()
                    Button("刷新用量") { refreshUsage() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointingHandCursor()
                }

                // 失败提示
                if let error = snapshot.error, !error.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(3)
                        Spacer()
                        Button("刷新") { refreshUsage() }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .pointingHandCursor()
                    }
                }

                // 余额（CodexBar ProviderMetricInlineRow 风格：标签左 semibold，余额右 footnote secondary）
                if !snapshot.balances.isEmpty {
                    // 多 Key 余额：逐行展示（DeepSeek 多 api-key）
                    ForEach(Array(snapshot.balances.indices), id: \.self) { index in
                        let entry = snapshot.balances[index]
                        usageMetricRow(label: entry.label, value: balanceText(entry.balance, currency: entry.currency))
                    }
                } else if let balance = snapshot.balance {
                    usageMetricRow(label: "余额", value: balanceText(balance, currency: snapshot.currency))
                }

                // 配额窗口
                if !snapshot.quotaWindows.isEmpty {
                    ForEach(Array(snapshot.quotaWindows.indices), id: \.self) { index in
                        quotaWindowRow(snapshot.quotaWindows[index])
                    }
                }

                // 模型配额
                if !snapshot.modelQuotas.isEmpty {
                    ForEach(Array(snapshot.modelQuotas.indices), id: \.self) { index in
                        modelQuotaRow(snapshot.modelQuotas[index])
                    }
                }
            } header: {
                Text("用量")
            }
        } else if let dashboard = ProviderRegistry.shared.descriptor(for: providerID)?.usageDashboardURL {
            // 无公开用量 API 的供应商（如 opencode）：提供网页看板入口。
            Section {
                HStack(spacing: 8) {
                    Label("上游暂未开放用量 API，可在网页查看余额。", systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("在网页查看") {
                        NSWorkspace.shared.open(dashboard)
                    }
                    .buttonStyle(.link)
                    .pointingHandCursor()
                }
            } header: {
                Text("用量")
            }
        }
    }

    /// 用量指标行（CodexBar ProviderMetricInlineRow 风格）：标签左 `.subheadline.weight(.semibold)`，
    /// 值右 `.footnote` `.secondary` `.monospacedDigit()`。
    private func usageMetricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }

    /// 单个配额窗口行：label + ProgressView + 百分比 + 重置时间。
    private func quotaWindowRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(String(format: "%.0f", window.remainingPercentage))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetAt = window.resetAt {
                    Text("重置 \(resetAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: window.remainingFraction)
                .tint(progressColor(for: window.remainingFraction))
        }
        .padding(.vertical, 2)
    }

    /// 单个模型配额行：modelID + ProgressView + 百分比。
    private func modelQuotaRow(_ quota: ModelQuota) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(quota.modelID)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(String(format: "%.0f", quota.remainingPercentage))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetAt = quota.resetAt {
                    Text("重置 \(resetAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: quota.remainingFraction)
                .tint(progressColor(for: quota.remainingFraction))
        }
        .padding(.vertical, 2)
    }

    /// 剩余比例 → 进度条颜色（健康绿 / 告警橙 / 危险红）。
    private func progressColor(for fraction: Double) -> Color {
        if fraction >= 0.5 { return .green }
        if fraction >= 0.2 { return .orange }
        return .red
    }

    private func refreshUsage() {
        Task { await appState.refreshUsageNow(for: providerID) }
    }

    /// 余额展示文本（先拼成 String 再交给 Text，避免 LocalizedStringKey 对 Decimal 插值告警）。
    private func balanceText(_ balance: Decimal, currency: String?) -> String {
        "\(balance) \(currency ?? "")"
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

        // deviceFlow (CodeBuddy)：主 token（credential.accessToken）+ 轮换 token（apiKeys）
        if draftTokens.isEmpty {
            var tokens: [KeyedToken] = []
            if let access = pc?.credential.accessToken, !access.isEmpty {
                tokens.append(KeyedToken(value: access))
            }
            if let rest = pc?.apiKeys, !rest.isEmpty {
                tokens.append(contentsOf: rest)
            }
            if !tokens.isEmpty {
                draftTokens = tokens
            }
        }

        if manualRefreshToken.isEmpty, let refresh = pc?.credential.refreshToken, !refresh.isEmpty {
            manualRefreshToken = refresh
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
            try appState.setAccessTokens(draftTokens, refreshToken: manualRefreshToken, for: providerID)
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

    private func startModelTest(_ modelID: String) {
        modelTestResults[modelID] = .testing
        Task {
            await appState.testModel(modelID, for: providerID)
            // appState.testModel 把结果写到 testStates，我们同步一份到本地
            if let state = appState.testStates[providerID] {
                switch state {
                case .ok(let msg): modelTestResults[modelID] = .ok(msg)
                case .failed(let msg): modelTestResults[modelID] = .failed(msg)
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
            let models = (try? await provider.listModels(credential: credential)) ?? []
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
