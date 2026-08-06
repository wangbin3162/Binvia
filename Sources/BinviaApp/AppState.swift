import AppKit
import Foundation
import Security
import BinviaCore

/// Provider 连通性测试状态（三态：idle / testing / ok / failed）。
enum ProviderTestState: Equatable {
    case idle
    case testing
    case ok(String)
    case failed(String)

    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

/// OAuth 登录过程状态。
enum OAuthFlowState: Equatable {
    case idle
    case requestingCode        // 正在请求授权码 / 打开浏览器
    case waitingForAuth        // 等待用户在浏览器完成授权
    case waitingForCodeInput   // Antigravity：等待用户粘贴授权码
    case connected
    case failed(String)
}

/// 全局 UI 状态：配置加载/保存、服务器生命周期、Provider 测试/登录、网关 Key、metrics。
///
/// 线程模型：全部 `@MainActor`，UI 状态只在主线程变更。
/// 网络/轮询通过 `Task` 在后台执行，结果回主线程写入 `@Published`。
@MainActor
final class AppState: ObservableObject {
    @Published var config: RouteConfig
    @Published var configPath: String

    @Published var isServerRunning = false
    @Published var serverError: String?

    @Published var usageSummary = UsageSummary(byProvider: [:])

    /// 最近请求记录（倒序，最近 10 条；随 2s metrics 轮询刷新）。token 在流结束后才回填，
    /// 故流式请求可能短暂显示「—」，下一轮刷新补上。
    @Published var recentEntries: [RequestLogEntry] = []

    /// 各 provider 的用量快照（Phase 16：余额 / 配额窗口 / 模型配额）。由 5min 轮询或手动刷新填充。
    @Published var usageSnapshots: [String: ProviderUsageSnapshot] = [:]

    /// 各 provider 的连通性测试结果。
    @Published var testStates: [String: ProviderTestState] = [:]
    /// 各 provider 的 OAuth 登录状态。
    @Published var oauthStates: [String: OAuthFlowState] = [:]

    /// OAuth 授权码输入（由 sheet 触发，PKCE 粘贴授权码；Antigravity）。
    @Published var isShowingCodeInput = false

    private var server: HTTPServer?
    private var refreshTimer: Timer?
    private var usageRefreshTimer: Timer?
    private var oauthRefreshTimer: Timer?
    private var codeContinuation: CheckedContinuation<String, Error>?
    /// 正在等待授权码的 provider id（cancel 时恢复其 oauth 状态）。
    private var codeInputProviderID: String?
    /// 配置读取失败时保留错误状态，禁止后续用空配置覆盖磁盘原配置。
    private let configLoadError: String?

    private enum ConfigurationError: Error, LocalizedError {
        case loadFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let message): return message
            }
        }
    }

    // MARK: - 初始化

    init(initialConfig: RouteConfig? = nil, configPath: String? = nil) {
        let resolvedPath = configPath ?? ConfigStore.defaultPath()
        self.configPath = resolvedPath

        let loaded: RouteConfig
        let loadError: String?
        if let initialConfig {
            loaded = initialConfig
            loadError = nil
        } else {
            do {
                loaded = try ConfigStore.load(path: resolvedPath)
                loadError = nil
            } catch {
                // 不再静默吞掉错误后使用空配置：空配置一旦保存，会覆盖用户原有模型/凭据。
                loaded = RouteConfig()
                loadError = error.localizedDescription
                print("[Binvia] 配置加载失败，已阻止保存空配置：\(error.localizedDescription)")
            }
        }
        self.config = loaded
        self.configLoadError = loadError
        if let loadError {
            self.serverError = "配置加载失败，未覆盖原配置：\(loadError)"
        }
        ProviderCatalog.registerAll()
        ProviderCatalog.registerCustomProviders(from: loaded)

        // 恢复 OAuth/设备码登录状态：有 accessToken 且带登录账号标识的 provider 标为已连接，
        // 使「已连接 · 账号」在重启后仍然展示（否则按钮退回「登录」，造成未登录假象）。
        for id in ["codebuddy-cn", "antigravity"] {
            if let pc = loaded.providers[id],
               !(pc.credential.accessToken ?? "").isEmpty,
               !(pc.credential.email ?? "").isEmpty {
                oauthStates[id] = .connected
            }
        }
    }

    // MARK: - 服务器生命周期

    func startServer() throws {
        guard server == nil else { return }
        try ensureConfigurationLoaded()
        ProviderCatalog.registerAll()
        ProviderCatalog.registerCustomProviders(from: config)
        do {
            let handler = RouteHandler(config: config)
            let newServer = HTTPServer { request in
                try await handler.handle(request)
            }
            try newServer.start(host: config.host, port: config.port)
            server = newServer
            isServerRunning = true
            serverError = nil
        } catch {
            serverError = error.localizedDescription
            throw error
        }
    }

    func stopServer() {
        guard let s = server else { return }
        s.stop()
        server = nil
        isServerRunning = false
        serverError = nil
    }

    func toggleServer() {
        if isServerRunning {
            stopServer()
        } else {
            do {
                try startServer()
            } catch {
                serverError = error.localizedDescription
            }
        }
    }

    /// 重启服务器（端口等监听参数变更后调用）。
    func restartServer() {
        guard isServerRunning else { return }
        stopServer()
        do {
            try startServer()
        } catch {
            serverError = error.localizedDescription
        }
    }

    // MARK: - 配置保存与热更新

    /// 保存配置到磁盘，并在服务器运行中即时替换 handler（无需重启）。
    /// 配置初始加载失败时禁止保存，避免空配置覆盖用户原文件。
    func saveConfig() throws {
        try ensureConfigurationLoaded()
        try ConfigStore.save(config, to: configPath)
        applyConfigHotReload()
    }

    private func ensureConfigurationLoaded() throws {
        guard let configLoadError else { return }
        throw ConfigurationError.loadFailed(
            "配置文件加载失败，已阻止覆盖原配置：\(configLoadError)"
        )
    }

    func applyConfigHotReload() {
        guard let s = server else { return }
        let handler = RouteHandler(config: config)
        s.setHandler { request in
            try await handler.handle(request)
        }
    }

    /// 保存某 provider 的凭据并持久化（OAuth 登录成功 / API Key 编辑后调用）。
    func saveCredential(_ credential: ProviderCredential, for providerID: String) throws {
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        providerConfig.credential = credential
        config.providers[providerID] = providerConfig
        try saveConfig()
    }

    /// 设置某 provider 的带标签令牌列表（DeepSeek 多 key 轮换；API 令牌 / Access Token 通用）。
    func setTokens(_ tokens: [KeyedToken], for providerID: String) throws {
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        providerConfig.apiKeys = tokens
        config.providers[providerID] = providerConfig
        try saveConfig()
    }

    /// 设置某 provider 的 API 区域（z.ai 等；nil = 供应商默认区域）。
    func setProviderRegion(_ region: String?, for providerID: String) {
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        providerConfig.region = region
        config.providers[providerID] = providerConfig
        try? saveConfig()
    }

    /// 设置某 provider 的企业 ID（CodeBuddy CN 积分查询用，存 `credential.workspaceId`）。
    func setEnterpriseID(_ id: String, for providerID: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        var credential = providerConfig.credential
        credential.workspaceId = trimmed.isEmpty ? nil : trimmed
        providerConfig.credential = credential
        config.providers[providerID] = providerConfig
        try? saveConfig()
    }

    /// 设置 deviceFlow 类型 provider 的模型调用 token 列表（只写 `apiKeys`）。
    /// OAuth 登录 token 单独存于 `credential.accessToken`，**仅用于积分查询，不参与模型调用**
    /// （CodeBuddy 登录 token 调用模型会报「体验版尚未激活」）。
    func setModelTokens(_ tokens: [KeyedToken], for providerID: String) throws {
        let cleaned = tokens
            .map { KeyedToken(label: $0.label, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.value.isEmpty }
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        providerConfig.apiKeys = cleaned
        config.providers[providerID] = providerConfig
        try saveConfig()
    }

    /// 仅更新 provider 的 refreshToken（登录响应已自动保存；手动修改可选）。
    func setRefreshToken(_ token: String?, for providerID: String) throws {
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        var credential = providerConfig.credential
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        credential.refreshToken = (trimmed?.isEmpty == false) ? trimmed : nil
        providerConfig.credential = credential
        config.providers[providerID] = providerConfig
        try saveConfig()
    }

    /// 读取 deviceFlow provider 的全部 access token（主 token + 轮换 token）。
    func accessTokens(for providerID: String) -> [String] {
        guard let pc = config.providers[providerID] else { return [] }
        var result: [String] = []
        if let access = pc.credential.accessToken, !access.isEmpty {
            result.append(access)
        }
        result.append(contentsOf: pc.apiKeyValues)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    // MARK: - Cursor 多账号（token + machineId）

    /// Cursor 账号 = (label, accessToken, machineId)。主账号来自 `credential`，
    /// 其余来自 `apiKeys[]`（machineId 存于标签，格式 `mid:<machineId>`）。
    struct CursorAccount: Equatable {
        var label: String
        var accessToken: String
        var machineId: String?
    }

    /// 读取全部 Cursor 账号（主 + 轮换）。无账号返回空数组。
    func cursorAccounts(for providerID: String = "cursor") -> [CursorAccount] {
        guard let pc = config.providers[providerID] else { return [] }
        var result: [CursorAccount] = []
        if let access = pc.credential.accessToken, !access.isEmpty {
            result.append(CursorAccount(
                label: "主账号",
                accessToken: access,
                machineId: pc.credential.machineId
            ))
        }
        for token in pc.apiKeys {
            guard !token.value.isEmpty else { continue }
            // machineId 编码在标签前缀 `mid:` 中（KeyedToken 只有 label+value 两字段）。
            var machineId: String?
            var label = token.label
            if label.hasPrefix("mid:") {
                machineId = String(label.dropFirst(4))
                label = "账号"
            }
            result.append(CursorAccount(label: label, accessToken: token.value, machineId: machineId))
        }
        return result
    }

    /// 保存全部 Cursor 账号：首账号 → `credential.accessToken/machineId`，其余 → `apiKeys[]`。
    func setCursorAccounts(_ accounts: [CursorAccount], for providerID: String = "cursor") throws {
        let cleaned = accounts
            .map { CursorAccount(label: $0.label, accessToken: $0.accessToken.trimmingCharacters(in: .whitespacesAndNewlines), machineId: $0.machineId) }
            .filter { !$0.accessToken.isEmpty }
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        var credential = providerConfig.credential
        if let primary = cleaned.first {
            credential.accessToken = primary.accessToken
            credential.machineId = primary.machineId
        } else {
            credential.accessToken = nil
            credential.machineId = nil
        }
        // 其余账号：machineId 编码进标签前缀 `mid:`。
        providerConfig.credential = credential
        providerConfig.apiKeys = Array(cleaned.dropFirst()).map {
            let label = $0.machineId.map { "mid:\($0)" } ?? $0.label
            return KeyedToken(label: label, value: $0.accessToken)
        }
        config.providers[providerID] = providerConfig
        try saveConfig()
    }

    /// 保存手动粘贴的 token 凭据（CodeBuddy / Antigravity 的“手动配置 Token”）。
    func saveManualToken(accessToken: String, refreshToken: String?, for providerID: String) throws {
        let trimmedAccess = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRefresh = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        var credential = providerConfig.credential
        if !trimmedAccess.isEmpty {
            credential.accessToken = trimmedAccess
        }
        credential.refreshToken = trimmedRefresh.isEmpty ? credential.refreshToken : trimmedRefresh
        providerConfig.credential = credential
        config.providers[providerID] = providerConfig
        try saveConfig()
    }

    /// 开关某 provider 的启用状态（路由层会跳过禁用的 provider）。
    func setProviderEnabled(_ enabled: Bool, for providerID: String) {
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = enabled
        config.providers[providerID] = providerConfig
        try? saveConfig()
    }

    /// 某模型是否被禁用（设置面板模型行「启用/禁用」开关）。
    func isModelDisabled(_ modelID: String, for providerID: String) -> Bool {
        config.providers[providerID]?.isModelDisabled(modelID) ?? false
    }

    /// 设置某模型启用/禁用（禁用模型视为不存在：/v1/models 不展示、网关白名单不可选、请求 404）。
    func setModelDisabled(_ disabled: Bool, modelID: String, for providerID: String) {
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        var disabledSet = Set(providerConfig.disabledModels)
        if disabled {
            disabledSet.insert(modelID)
        } else {
            disabledSet.remove(modelID)
        }
        providerConfig.disabledModels = disabledSet.sorted()
        config.providers[providerID] = providerConfig
        try? saveConfig()
    }

    /// 批量设置该供应商多个模型的启用/禁用（一次持久化，避免逐模型保存/热更新）。
    func setModelsDisabled(_ disabled: Bool, modelIDs: [String], for providerID: String) {
        guard !modelIDs.isEmpty else { return }
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        var disabledSet = Set(providerConfig.disabledModels)
        for id in modelIDs {
            if disabled {
                disabledSet.insert(id)
            } else {
                disabledSet.remove(id)
            }
        }
        providerConfig.disabledModels = disabledSet.sorted()
        config.providers[providerID] = providerConfig
        try? saveConfig()
    }

    // MARK: - 供应商排序（拖拽）

    /// 按当前 config.providerOrder 返回有序描述符列表（侧栏 / 菜单 / /v1/models 共用）。
    func orderedProviderDescriptors() -> [ProviderDescriptor] {
        ProviderRegistry.shared.orderedDescriptors(config.providerOrder)
    }

    /// 直接设置供应商排序并持久化（侧栏拖拽排序用，自定义供应商分栏后按内置子集重排）。
    func setProviderOrder(_ order: [String]) {
        config.providerOrder = order
        try? saveConfig()
    }

    // MARK: - 自定义兼容 Provider 管理

    /// 查询某个自定义 provider 的定义。
    func customProviderDef(for id: String) -> CustomProviderDef? {
        config.customProviderDef(for: id)
    }

    /// 新增一个自定义 OpenAI 兼容 Provider。
    /// - 生成唯一 slug id（避免与已注册 provider 冲突）
    /// - 写入 `customProviderDefs` + `providers[id]`（启用态、空凭据）
    /// - 注册到 `ProviderRegistry`，保存配置并热更新
    /// - 返回新建的 def；校验失败（名称空 / URL 非法）返回 nil
    @discardableResult
    func addCustomProvider(name: String, baseURL: String) throws -> CustomProviderDef? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, Self.isValidHTTPURL(trimmedURL) else { return nil }
        let existingIds = Set(ProviderRegistry.shared.allDescriptors().map(\.id))
        let id = CustomProviderDef.uniqueSlug(for: trimmedName, excluding: existingIds)
        let def = CustomProviderDef(id: id, displayName: trimmedName, baseURL: trimmedURL, models: [])
        config.customProviderDefs.append(def)
        config.providers[id] = ProviderConfig(enabled: true, credential: ProviderCredential(), apiKeys: [])
        reregisterCustomProvider(def)
        try saveConfig()
        return def
    }

    /// 编辑自定义 provider 的展示名 / BaseURL（传 nil 表示不修改）。
    func updateCustomProvider(id: String, displayName: String?, baseURL: String?) throws {
        guard let idx = config.customProviderDefs.firstIndex(where: { $0.id == id }) else { return }
        var def = config.customProviderDefs[idx]
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            def.displayName = name
        }
        if let url = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty, Self.isValidHTTPURL(url) {
            def.baseURL = url
        }
        config.customProviderDefs[idx] = def
        reregisterCustomProvider(def)
        try saveConfig()
    }

    /// 删除自定义 provider：移除定义、凭据、注册表条目。
    func deleteCustomProvider(id: String) throws {
        config.customProviderDefs.removeAll { $0.id == id }
        config.providers.removeValue(forKey: id)
        ProviderRegistry.shared.unregister(id)
        try saveConfig()
    }

    /// 为自定义 provider 追加一个模型。
    /// 输入可带 `<providerID>/` 前缀（用户可能从 `/v1/models` 复制），内部剥前缀后存原始模型名。
    func addCustomModel(providerID: String, model: String) throws {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(providerID)/"
        var clean = trimmed
        while clean.hasPrefix(prefix) {
            clean = String(clean.dropFirst(prefix.count))
        }
        guard !clean.isEmpty,
              let idx = config.customProviderDefs.firstIndex(where: { $0.id == providerID }) else { return }
        guard !config.customProviderDefs[idx].models.contains(clean) else { return }
        config.customProviderDefs[idx].models.append(clean)
        reregisterCustomProvider(config.customProviderDefs[idx])
        try saveConfig()
    }

    /// 从自定义 provider 删除一个模型（`model` 参数可带前缀，内部剥掉全部前缀后比较）。
    func removeCustomModel(providerID: String, model: String) throws {
        guard let idx = config.customProviderDefs.firstIndex(where: { $0.id == providerID }) else { return }
        let prefix = "\(providerID)/"
        var stripped = model
        while stripped.hasPrefix(prefix) {
            stripped = String(stripped.dropFirst(prefix.count))
        }
        guard let modelIdx = config.customProviderDefs[idx].models.firstIndex(of: stripped) else { return }
        config.customProviderDefs[idx].models.remove(at: modelIdx)
        reregisterCustomProvider(config.customProviderDefs[idx])
        try saveConfig()
    }

    /// （重新）注册单个自定义 provider 到 ProviderRegistry：先 unregister 再 register 新版本。
    private func reregisterCustomProvider(_ def: CustomProviderDef) {
        ProviderRegistry.shared.unregister(def.id)
        guard let baseURL = URL(string: def.baseURL) else { return }
        let descriptor = ProviderDescriptor(
            metadata: ProviderMetadata(id: def.id, alias: def.id, displayName: def.displayName, authType: .apiKey),
            baseURL: baseURL,
            models: [],
            supportsStreaming: true,
            usageFetcherFactory: { nil },
            isUserDefined: true,
            makeProvider: { GenericOpenAIProvider(id: def.id, baseURL: baseURL, models: def.models) }
        )
        ProviderRegistry.shared.register(descriptor)
    }

    private static func isValidHTTPURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return true
    }

    // MARK: - Provider 状态摘要

    /// 某 provider 是否已配置凭据（按认证类型判断）。
    /// cursor 特判：IDE 检测成功（`CursorCredentialStore` 缓存命中）即视为已配置，无需 API Key。
    func isProviderConfigured(_ providerID: String) -> Bool {
        guard let descriptor = ProviderRegistry.shared.descriptor(for: providerID) else { return false }
        if providerID == "cursor" {
            // 缓存命中（IDE 登录令牌）→ 已配置；未探测过时返回 false（由 refresh 后重算）。
            if let identity = CursorCredentialStore.shared.peekCachedIdentity() {
                return !identity.accessToken.isEmpty
            }
            // 缓存未命中：若配置里显式存过 token（手动导入账号），也算已配置。
            if let pc = config.providers["cursor"] {
                let hasToken = !(pc.credential.accessToken ?? "").isEmpty
                    || !pc.apiKeys.isEmpty
                if hasToken { return true }
            }
            // 未探测过 → 异步刷新缓存后再判定（避免首次打开密钥面板看不到 cursor）。
            Task { @MainActor in
                if case .found = await CursorCredentialStore.shared.refresh() {
                    self.objectWillChange.send()
                }
            }
            return false
        }
        let pc = config.providers[providerID]
        switch descriptor.metadata.authType {
        case .apiKey, .localProbe:
            return !(pc?.credential.apiKey ?? "").isEmpty
                || !(pc?.apiKeys ?? []).isEmpty
        case .oauth, .deviceFlow:
            return !(pc?.credential.accessToken ?? "").isEmpty
        }
    }

    /// 设置面板中 provider 详情的副标题：认证类型 + 配置状态。
    func providerSubtitle(_ providerID: String) -> String {
        guard let descriptor = ProviderRegistry.shared.descriptor(for: providerID) else { return providerID }
        let authLabel: String
        switch descriptor.metadata.authType {
        case .apiKey, .localProbe: authLabel = "API Key"
        case .oauth: authLabel = "OAuth"
        case .deviceFlow: authLabel = "OAuth 设备码"
        }
        let stateLabel = isProviderConfigured(providerID) ? "已配置" : "未配置"
        return "\(authLabel) · \(stateLabel)"
    }

    // MARK: - Provider 连通性测试

    func testProvider(_ providerID: String) async {
        guard let provider = ProviderRegistry.shared.provider(for: providerID) else {
            testStates[providerID] = .failed("未注册的 provider: \(providerID)")
            return
        }
        testStates[providerID] = .testing
        let credential = config.credential(for: providerID)
        do {
            let result = try await provider.testConnection(credential: credential)
            testStates[providerID] = result.success ? .ok(result.message) : .failed(result.message)
        } catch {
            testStates[providerID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - 模型级连通性测试

    /// 测试指定 provider 下某个具体模型的连通性（发送最小 ping 请求）。
    /// 结果写入 testStates[providerID] 与当前选择的模型无关，统一复用 testResultSection 展示。
    func testModel(_ modelID: String, for providerID: String) async {
        guard let provider = ProviderRegistry.shared.provider(for: providerID) else {
            testStates[providerID] = .failed("未注册的 provider: \(providerID)")
            return
        }
        testStates[providerID] = .testing
        let credential = config.credential(for: providerID)
        do {
            let result = try await provider.testModel(modelID, credential: credential)
            testStates[providerID] = result.success ? .ok(result.message) : .failed(result.message)
        } catch {
            testStates[providerID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - OAuth 登录

    /// CodeBuddy CN 设备码流登录。自动打开浏览器，后台轮询直到拿到 token。
    func loginCodeBuddy() async {
        oauthStates["codebuddy-cn"] = .requestingCode
        do {
            let client = CodeBuddyOAuthClient()
            var credential = try await client.login { url in
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                    self.oauthStates["codebuddy-cn"] = .waitingForAuth
                }
            }
            // 保留企业 ID：登录响应不含 workspaceId，整体替换会清空用户已填的企业 ID
            credential.workspaceId = config.credential(for: "codebuddy-cn").workspaceId
            try saveCredential(credential, for: "codebuddy-cn")
            oauthStates["codebuddy-cn"] = .connected
        } catch {
            oauthStates["codebuddy-cn"] = .failed(error.localizedDescription)
        }
    }

    /// Antigravity PKCE 流登录。自动打开浏览器，等待用户在 GUI 粘贴授权码。
    func loginAntigravity() async {
        oauthStates["antigravity"] = .requestingCode
        do {
            let client = AntigravityOAuthClient(config: .live())
            let credentials = try await client.login(
                openURL: { url in
                    Task { @MainActor in
                        NSWorkspace.shared.open(url)
                        self.oauthStates["antigravity"] = .waitingForAuth
                    }
                },
                codeProvider: { _ in
                    try await self.waitForAuthCode(for: "antigravity")
                }
            )
            let credential = ProviderCredential(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                email: credentials.email,
                expiresAt: credentials.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
            )
            try saveCredential(credential, for: "antigravity")
            oauthStates["antigravity"] = .connected
        } catch {
            oauthStates["antigravity"] = .failed(error.localizedDescription)
        }
    }

    // MARK: - OAuth 状态引导 & token 刷新（Phase 20）

    /// 启动时恢复 OAuth 状态：已配置 accessToken 的 oauth provider 标记为已连接，
    /// 并主动刷新一次 Antigravity token（避免启动后仍用已过期 token）。
    func bootstrapOAuth() async {
        for (providerID, pc) in config.providers
        where ProviderRegistry.shared.descriptor(for: providerID)?.metadata.authType == .oauth {
            if !(pc.credential.accessToken ?? "").isEmpty {
                oauthStates[providerID] = .connected
            }
        }
        await refreshAntigravityToken()
    }

    /// 启动 OAuth token 周期刷新（每 25 分钟，token 约 1 小时过期）。
    /// 与 metrics/usage 轮询并行，随菜单面板出现而启动。
    func startOAuthRefresh() {
        guard oauthRefreshTimer == nil else { return }
        oauthRefreshTimer = Timer.scheduledTimer(withTimeInterval: 25 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAntigravityToken()
            }
        }
    }

    /// 用 refreshToken 主动刷新 Antigravity access token，并把新 token（含旋转后的
    /// refreshToken）、过期时间、邮箱（为空时补抓）持久化回 config。刷新失败不覆盖旧凭据。
    func refreshAntigravityToken() async {
        guard let pc = config.providers["antigravity"],
              !(pc.credential.accessToken ?? "").isEmpty,
              let refresh = pc.credential.refreshToken, !refresh.isEmpty else {
            return
        }
        let client = AntigravityOAuthClient(config: .live())
        do {
            let refreshed = try await client.refreshAccessToken(refreshToken: refresh)
            var credential = pc.credential
            credential.accessToken = refreshed.accessToken
            if let rt = refreshed.refreshToken, !rt.isEmpty {
                credential.refreshToken = rt
            }
            if let exp = refreshed.expiresIn {
                credential.expiresAt = Date().addingTimeInterval(TimeInterval(exp))
            }
            if (credential.email ?? "").isEmpty,
               let email = await client.fetchUserEmail(accessToken: refreshed.accessToken),
               !email.isEmpty {
                credential.email = email
            }
            try saveCredential(credential, for: "antigravity")
            oauthStates["antigravity"] = .connected
        } catch {
            // invalid_grant / 网络失败：保留旧凭据，状态标为失败以便用户重新登录。
            oauthStates["antigravity"] = .failed(error.localizedDescription)
        }
    }

    func resetOAuthState(_ providerID: String) {
        oauthStates[providerID] = .idle
    }

    // MARK: - OAuth 授权码输入（CheckedContinuation 桥接）

    private func waitForAuthCode(for providerID: String) async throws -> String {
        oauthStates[providerID] = .waitingForCodeInput
        codeInputProviderID = providerID
        isShowingCodeInput = true
        defer {
            isShowingCodeInput = false
            codeInputProviderID = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            codeContinuation = continuation
        }
    }

    func submitAuthCode(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let code = extractAuthorizationCode(from: trimmed)
        codeContinuation?.resume(returning: code)
        codeContinuation = nil
        isShowingCodeInput = false
    }

    func cancelAuthCode() {
        codeContinuation?.resume(throwing: CancellationError())
        codeContinuation = nil
        isShowingCodeInput = false
        if let providerID = codeInputProviderID {
            oauthStates[providerID] = .idle
        }
    }

    private func extractAuthorizationCode(from input: String) -> String {
        if let url = URL(string: input),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
           !code.isEmpty {
            return code
        }
        return input
    }

    // MARK: - 网关 API Key

    /// 生成 `sk-bv-` + 32 位随机 hex（SecRandomCopyBytes）。Phase 17：前缀从 `sk-tg-` 迁移到 `sk-bv-`。
    /// 旧 `sk-tg-` key 仍可在配置中鉴权（向后兼容），仅新生成的 key 使用新前缀。
    func generateAPIKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return "" }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "sk-bv-\(hex)"
    }

    /// 新增一个网关 Key 并持久化。
    @discardableResult
    func addGatewayKey() -> String {
        let key = generateAPIKey()
        config.apiKeys.append(GatewayKeyConfig(key: key))
        try? saveConfig()
        return key
    }

    /// 删除一个网关 Key 并持久化。
    func removeGatewayKey(_ key: String) {
        config.apiKeys.removeAll { $0.key == key }
        try? saveConfig()
    }

    /// 设置某网关 Key 的模型白名单（Phase 12）。`nil` = 全部启用；空数组 = 禁用全部模型。
    func setGatewayKeyEnabledModels(_ key: String, enabledModels: [String]?) {
        guard let idx = config.apiKeys.firstIndex(where: { $0.key == key }) else { return }
        config.apiKeys[idx].enabledModels = enabledModels
        try? saveConfig()
    }

    // MARK: - Metrics

    func startMetricsRefresh() {
        guard refreshTimer == nil else { return }
        usageSummary = RequestLogger.shared.summary()
        recentEntries = Self.recentEntries()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.usageSummary = RequestLogger.shared.summary()
                self?.recentEntries = Self.recentEntries()
            }
        }
    }

    /// 最近请求：内存日志倒序取最近 10 条。
    private static func recentEntries() -> [RequestLogEntry] {
        Array(RequestLogger.shared.allEntries().suffix(10).reversed())
    }

    func stopMetricsRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - 用量刷新（Phase 16）

    /// 启动用量轮询：立即刷新一次，随后每 5 分钟刷新全部带 `usageFetcherFactory` 的 provider。
    func startUsageRefresh() {
        guard usageRefreshTimer == nil else { return }
        Task { await refreshAllUsage() }
        usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: UsageCache.ttl, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllUsage()
            }
        }
    }

    func stopUsageRefresh() {
        usageRefreshTimer?.invalidate()
        usageRefreshTimer = nil
    }

    /// 全量刷新所有挂载了用量查询器的 provider。
    private func refreshAllUsage() async {
        for descriptor in ProviderRegistry.shared.allDescriptors() {
            guard descriptor.usageFetcherFactory() != nil else { continue }
            await refreshUsage(for: descriptor.id)
        }
    }

    /// 刷新单个 provider 的用量（GUI「刷新用量」按钮入口）。
    /// 强制绕过缓存打上游；失败时写入带 `error` 的快照，绝不崩溃。
    func refreshUsageNow(for providerID: String) async {
        await refreshUsage(for: providerID, force: true)
    }

    private func refreshUsage(for providerID: String, force: Bool = false) async {
        guard let descriptor = ProviderRegistry.shared.descriptor(for: providerID),
              let fetcher = descriptor.usageFetcherFactory() else { return }
        // 1. 缓存优先（仅轮询路径；手动刷新 force=true 跳过）
        if !force, let cached = await UsageCache.shared.get(providerID) {
            usageSnapshots[providerID] = cached
            return
        }
        // 2. 打上游，成功写缓存
        do {
            let credential = config.credential(for: providerID)
            let snapshot = try await fetcher.fetchUsage(credential: credential)
            await UsageCache.shared.set(snapshot)
            usageSnapshots[providerID] = snapshot
        } catch {
            // 3. 失败快照：展示错误，避免轮询 Timer 崩溃
            usageSnapshots[providerID] = ProviderUsageSnapshot(
                providerID: providerID,
                fetchedAt: Date(),
                error: error.localizedDescription
            )
        }
    }

    // MARK: - 概览派生属性（Phase 23.3）

    /// 总请求数（usageSummary 各 provider 累加）。
    var totalRequests: Int {
        usageSummary.byProvider.values.reduce(0) { $0 + $1.requestCount }
    }

    /// 总错误数。
    var totalErrors: Int {
        usageSummary.byProvider.values.reduce(0) { $0 + $1.errorCount }
    }

    /// 活跃（已配置凭据）的 provider 数。
    var activeProviderCount: Int {
        orderedProviderDescriptors().filter { isProviderConfigured($0.id) }.count
    }

    /// 总 prompt token（Phase 22 采集）。
    var totalPromptTokens: Int {
        usageSummary.byProvider.values.reduce(0) { $0 + $1.totalPromptTokens }
    }

    /// 总 completion token。
    var totalCompletionTokens: Int {
        usageSummary.byProvider.values.reduce(0) { $0 + $1.totalCompletionTokens }
    }

    /// 总 token。
    var totalTokens: Int {
        usageSummary.byProvider.values.reduce(0) { $0 + $1.totalTokens }
    }

    /// 已配置凭据的 provider 描述符（按 providerOrder 排序）。主面板 Tab 与健康度列表共用。
    var configuredProviders: [ProviderDescriptor] {
        orderedProviderDescriptors().filter { isProviderConfigured($0.id) }
    }

    // MARK: - 菜单栏图标

    var statusIconName: String {
        if isServerRunning { return "bolt.shield.fill" }
        return "bolt.shield"
    }
}

// MARK: - Smoke Test（无界面自检，供 `--smoke-test` 与 CI 使用）

extension AppState {
    /// 探测一个空闲的本地端口（bind 端口 0 后关闭，测试用）。
    static func findFreePort() -> Int {
        for _ in 0 ..< 50 {
            let candidate = Int.random(in: 20_000 ... 40_000)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(candidate).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(fd)
            if ok { return candidate }
        }
        return 20427
    }

    /// 无界面自检：验证配置读写、网关 Key 生成、服务器启停、热更新。
    /// 用法：`swift run BinviaApp --smoke-test`。
    static func runSmokeTest() async {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("[PASS] \(name)")
            } else {
                print("[FAIL] \(name)")
                failures += 1
            }
        }

        // 临时配置文件
        let tmpDir = NSTemporaryDirectory() + "binvia-smoke-\(UUID().uuidString)"
        let configPath = tmpDir + "/config.json"

        // 绑定端口 0 时 HTTPServer 不回报实际端口，这里先探测一个空闲端口
        let port = findFreePort()

        let state = AppState(initialConfig: RouteConfig(port: port), configPath: configPath)
        check("初始配置为空且未运行", !state.isServerRunning)

        // 网关 Key 生成
        let key = state.generateAPIKey()
        check("API Key 前缀正确", key.hasPrefix("sk-bv-"))
        check("API Key 长度正确", key.count == 6 + 32)

        // 配置持久化
        state.config.apiKeys = [GatewayKeyConfig(key: key)]
        try? state.saveConfig()
        let reloaded = (try? ConfigStore.load(path: configPath)) ?? RouteConfig()
        check("配置持久化成功", reloaded.gatewayKeyStrings == [key])

        // 服务器启停（用探测到的空闲端口）
        do {
            try state.startServer()
        } catch {
            print("[FAIL] startServer: \(error.localizedDescription)")
            failures += 1
        }
        check("服务器已运行", state.isServerRunning)

        // 健康检查
        var healthOK = false
        if let url = URL(string: "http://127.0.0.1:\(port)/v1/health") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                healthOK = String(data: data, encoding: .utf8)?.contains("ok") == true
            }
        }
        check("健康检查返回 200 ok", healthOK)

        // 网关 Key 认证：配置了 key 后，未携带 Key 应 401，携带 Key 应 200（Phase 8 验证）
        func statusCode(_ url: URL, authorization: String? = nil) async -> Int {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let auth = authorization {
                request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
            }
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return -1 }
            return http.statusCode
        }
        guard let modelsURL = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            failures += 1
            return
        }
        check("未携带 Key 请求 /v1/models → 401", await statusCode(modelsURL) == 401)
        check("携带网关 Key 请求 /v1/models → 200", await statusCode(modelsURL, authorization: key) == 200)

        // 配置热更新：替换 handler 后仍能服务（验证 setHandler）
        state.applyConfigHotReload()
        var hotReloadOK = false
        if let url = URL(string: "http://127.0.0.1:\(port)/v1/health") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse {
                hotReloadOK = http.statusCode == 200
            }
        }
        check("热更新后服务仍可用", hotReloadOK)

        // 停止服务器
        state.stopServer()
        check("服务器已停止", !state.isServerRunning)

        var stoppedOK = true
        if let url = URL(string: "http://127.0.0.1:\(port)/v1/health") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            do {
                _ = try await URLSession.shared.data(for: request)
                stoppedOK = false // 仍能连通说明未真正停止
            } catch {
                stoppedOK = true
            }
        }
        check("停止后端口已释放", stoppedOK)

        // 清理临时目录
        try? FileManager.default.removeItem(atPath: tmpDir)

        print(failures == 0 ? "\nSmoke Test: ALL PASSED" : "\nSmoke Test: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
