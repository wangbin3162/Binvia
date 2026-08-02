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

    /// 各 provider 的用量快照（Phase 16：余额 / 配额窗口 / 模型配额）。由 5min 轮询或手动刷新填充。
    @Published var usageSnapshots: [String: ProviderUsageSnapshot] = [:]

    /// 各 provider 的连通性测试结果。
    @Published var testStates: [String: ProviderTestState] = [:]
    /// 各 provider 的 OAuth 登录状态。
    @Published var oauthStates: [String: OAuthFlowState] = [:]

    /// Antigravity PKCE 授权码输入（由 sheet 触发）。
    @Published var isShowingCodeInput = false

    private var server: HTTPServer?
    private var refreshTimer: Timer?
    private var usageRefreshTimer: Timer?
    private var oauthRefreshTimer: Timer?
    private var codeContinuation: CheckedContinuation<String, Error>?

    // MARK: - 初始化

    init(initialConfig: RouteConfig? = nil, configPath: String? = nil) {
        let resolvedPath = configPath ?? ConfigStore.defaultPath()
        self.configPath = resolvedPath
        // 注意：`try?` 是 autoclosure，不能引用 self（config 尚未初始化），故先取局部变量
        let loaded = initialConfig ?? (try? ConfigStore.load(path: resolvedPath)) ?? RouteConfig()
        self.config = loaded
        ProviderCatalog.registerAll()
    }

    // MARK: - 服务器生命周期

    func startServer() throws {
        guard server == nil else { return }
        ProviderCatalog.registerAll()
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
    func saveConfig() throws {
        try ConfigStore.save(config, to: configPath)
        applyConfigHotReload()
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

    /// 设置 deviceFlow 类型 provider 的多 AccessToken（首 token → credential.accessToken，其余 → apiKeys[]）。
    /// 配套的 refreshToken 保留在 credential 中。令牌带标签（CodexBar 令牌账户风格）。
    func setAccessTokens(_ tokens: [KeyedToken], refreshToken: String?, for providerID: String) throws {
        let cleaned = tokens
            .map { KeyedToken(label: $0.label, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.value.isEmpty }
        var providerConfig = config.providers[providerID] ?? ProviderConfig()
        providerConfig.enabled = true
        var credential = providerConfig.credential
        if let primary = cleaned.first {
            credential.accessToken = primary.value
        } else {
            // 全部令牌被移除时清空主 token（避免残留已删除的凭据）
            credential.accessToken = nil
        }
        credential.refreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? refreshToken!.trimmingCharacters(in: .whitespacesAndNewlines)
            : credential.refreshToken
        // apiKeys[] 中存放除主 token 外的其他 token（轮换用）
        providerConfig.credential = credential
        providerConfig.apiKeys = Array(cleaned.dropFirst())
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

    // MARK: - 供应商排序（拖拽）

    /// 按当前 config.providerOrder 返回有序描述符列表（侧栏 / 菜单 / /v1/models 共用）。
    func orderedProviderDescriptors() -> [ProviderDescriptor] {
        ProviderRegistry.shared.orderedDescriptors(config.providerOrder)
    }

    /// 拖拽重排供应商顺序并持久化。
    func moveProvider(fromOffsets: IndexSet, toOffset: Int) {
        var order = config.providerOrder
        let allIDs = ProviderRegistry.shared.allDescriptors().map(\.id)
        // 合并尚未记录的 provider（保证 order 覆盖全部已知 id）
        for id in allIDs where !order.contains(id) {
            order.append(id)
        }
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        config.providerOrder = order
        try? saveConfig()
    }

    // MARK: - Provider 状态摘要

    /// 某 provider 是否已配置凭据（按认证类型判断）。
    func isProviderConfigured(_ providerID: String) -> Bool {
        guard let descriptor = ProviderRegistry.shared.descriptor(for: providerID) else { return false }
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
            let credential = try await client.login { url in
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                    self.oauthStates["codebuddy-cn"] = .waitingForAuth
                }
            }
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
                    try await self.waitForAuthCode()
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

    /// 启动 Antigravity token 周期刷新（每 25 分钟，token 约 1 小时过期）。
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

    // MARK: - Antigravity 授权码输入（CheckedContinuation 桥接）

    private func waitForAuthCode() async throws -> String {
        oauthStates["antigravity"] = .waitingForCodeInput
        isShowingCodeInput = true
        defer {
            isShowingCodeInput = false
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
        oauthStates["antigravity"] = .idle
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.usageSummary = RequestLogger.shared.summary()
            }
        }
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
        return 8231
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
