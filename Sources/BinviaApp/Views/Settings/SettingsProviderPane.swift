import SwiftUI
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

    /// DeepSeek 多 Key 草稿。
    @State private var draftKeys: [String] = [""]
    /// CodeBuddy 多 Token 草稿（首 token = 主 token，其余为轮换用）。
    @State private var draftTokens: [String] = [""]
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
                Section {
                    headerRow(descriptor)
                }

                connectionSection(descriptor)
                testResultSection
                infoSection(descriptor)
                usageSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                loadDrafts()
                loadModels()
            }
            .onChange(of: appState.config.providers[providerID]?.credential) { _, _ in
                // 凭据变更时刷新模型列表
                modelTestResults.removeAll()
                loadModels()
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
            ProviderBrandIcon(providerID: descriptor.id, size: 20)

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
                .controlSize(.small)
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

    /// DeepSeek：API Key 多行输入 + 添加/移除 + 测试/保存。
    private var apiKeyConnectionSection: some View {
        Section {
            ForEach(Array(draftKeys.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    APIKeyInputField(
                        title: draftKeys.count > 1 ? "API Key \(index + 1)" : "API Key",
                        text: $draftKeys[index])
                    if draftKeys.count > 1 {
                        Button {
                            draftKeys.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 4)
                        .help("移除该 Key")
                    }
                }
            }

            Button {
                draftKeys.append("")
            } label: {
                Label("添加 Key（用于轮换）", systemImage: "plus")
            }

            HStack {
                Spacer()
                Button("测试连接") { startTest() }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                Button("保存") { saveKeys() }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
            }
        } header: {
            Text("连接")
        } footer: {
            Text("请求会通过 Authorization: Bearer <key> 转发到 DeepSeek。保存后立即热更新。")
        }
    }

    /// CodeBuddy：OAuth 设备码登录 + 手动 Access Token（支持多 token 轮换）。
    /// 手动 Token 区域始终展开（不折叠），样式对齐 DeepSeek 的 API Key 列表。
    private var deviceFlowConnectionSection: some View {
        Section {
            OAuthLoginButton(providerID: providerID)

            ForEach(Array(draftTokens.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    APIKeyInputField(
                        title: draftTokens.count > 1 ? "Access Token \(index + 1)" : "Access Token",
                        text: $draftTokens[index])
                    if draftTokens.count > 1 {
                        Button {
                            draftTokens.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight(cornerRadius: 4)
                        .help("移除该 Token")
                    }
                }
            }

            Button {
                draftTokens.append("")
            } label: {
                Label("添加 Token", systemImage: "plus")
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
                Button("保存 Tokens") { saveTokens() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draftTokens.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }

            HStack {
                Spacer()
                Button("测试连接") { startTest() }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
            }
        } header: {
            Text("连接")
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
            Text("连接")
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

    // MARK: - 信息 Section

    private func infoSection(_ descriptor: ProviderDescriptor) -> some View {
        Section {
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
        } header: {
            Text("信息")
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

    /// 用量卡片：余额 / 配额窗口 / 模型配额。无快照时不展示（「有则展示无则隐藏」）。
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

                // 余额卡
                if !snapshot.balances.isEmpty {
                    // 多 Key 余额：逐行展示（DeepSeek 多 api-key）
                    ForEach(Array(snapshot.balances.indices), id: \.self) { index in
                        let entry = snapshot.balances[index]
                        LabeledContent(entry.label) {
                            Text(balanceText(entry.balance, currency: entry.currency))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let balance = snapshot.balance {
                    LabeledContent("余额") {
                        Text(balanceText(balance, currency: snapshot.currency))
                            .foregroundStyle(.secondary)
                    }
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
        }
    }

    /// 单个配额窗口行：label + ProgressView + 百分比 + 重置时间。
    private func quotaWindowRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.callout)
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
                    .font(.callout)
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

    /// 首次显示时加载已有配置：DeepSeek 的 Key 列表、deviceFlow 多 Token、oauth 的 Token 草稿。
    private func loadDrafts() {
        let pc = appState.config.providers[providerID]

        if draftKeys.count == 1, draftKeys[0].isEmpty {
            if let keys = pc?.apiKeys, !keys.isEmpty {
                draftKeys = keys
            } else if let key = pc?.credential.apiKey, !key.isEmpty {
                draftKeys = [key]
            }
        }

        // deviceFlow (CodeBuddy)：多 token 草稿
        if draftTokens.count == 1, draftTokens[0].isEmpty {
            let existing = appState.accessTokens(for: providerID)
            if !existing.isEmpty {
                draftTokens = existing
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

    private func saveKeys() {
        let keys = draftKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        try? appState.setAPIKeys(keys, for: providerID)
    }

    private func saveTokens() {
        let tokens = draftTokens.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if tokens.isEmpty {
            tokenSaveMessage = "请至少填写一个 Token"
            return
        }
        do {
            try appState.setAccessTokens(tokens, refreshToken: manualRefreshToken, for: providerID)
            tokenSaveMessage = "已保存 \(tokens.count) 个 Token"
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
