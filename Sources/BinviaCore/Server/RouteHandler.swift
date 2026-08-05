import Foundation

/// HTTP 路由分发器。借鉴 OmniRoute `server/authz/policies/clientApi.ts` + `src/sse/handlers/chat.ts`。
public struct RouteHandler: Sendable {
    private let config: RouteConfig
    private let authenticator: APIKeyAuthenticator
    private let router: Router
    private let registry: ProviderRegistry
    private let logger: RequestLogger
    private let state: ServerState?

    public init(config: RouteConfig, state: ServerState? = nil, registry: ProviderRegistry = .shared) {
        self.config = config
        self.state = state
        self.authenticator = APIKeyAuthenticator(configuredKeys: config.gatewayKeyStrings)
        self.router = Router(registry: registry)
        self.registry = registry
        self.logger = .shared
    }

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        // 面板开关：webPanelEnabled=false 时 / 与 /admin/* 返回 404
        let panelEnabled = state?.isWebPanelEnabled() ?? config.webPanelEnabled

        // 先匹配面道路由
        let normalized = normalizePath(request.path, panelEnabled: panelEnabled)
        if normalized == "/" {
            guard panelEnabled else { return HTTPResponse.text(404, "Not Found") }
            return webPanelResponse()
        }
        if normalized.hasPrefix("/admin") {
            return try await handleAdminRoute(request, panelEnabled: panelEnabled)
        }
        // /v1/* 路由
        return try await handleV1Route(request)
    }

    /// /v1/* 路由
    private func handleV1Route(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, normalizePathV1(request.path)) {
        case ("GET", "/v1/health"):
            return healthResponse()
        case ("GET", "/v1/models"):
            return await handleModels(request)
        case ("POST", "/v1/chat/completions"):
            return try await handleChat(request)
        case ("GET", "/v1/usage"):
            return handleUsage()
        default:
            return HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json")
        }
    }

    /// 路径归一化（admin 面板专用）：只放行 / 和 /admin 前缀，其余走 /v1 补全。
    private func normalizePath(_ path: String, panelEnabled: Bool) -> String {
        if path == "/" || path.hasPrefix("/admin") { return path }
        return normalizePathV1(path)
    }

    /// 路径归一化：兼容未带 `/v1` 前缀的客户端。
    /// 例如 opencode 配置 `baseURL` 漏写 `/v1` 时，AI SDK 会请求 `/chat/completions` 而非
    /// `/v1/chat/completions`，此处自动补前缀避免 404 Not Found。
    private func normalizePathV1(_ path: String) -> String {
        if path.hasPrefix("/v1") { return path }
        return "/v1" + path
    }

    // MARK: - 认证

    private func authorized(_ request: HTTPRequest) -> Bool {
        authenticatedKey(request) != nil
    }

    /// 返回命中的网关 Key 原文（未配置 key 时允许匿名，返回 nil 但视为已授权）。
    /// 调用方需用 `requiresAuthentication` 区分「匿名授权」与「认证失败」。
    private func authenticatedKey(_ request: HTTPRequest) -> String? {
        if !authenticator.requiresAuthentication {
            return nil // 未配置 key 时允许匿名（开发模式，同 OmniRoute REQUIRE_API_KEY=false）
        }
        return authenticator.matchedKey(request.authorizationToken)
    }

    /// 网关 key 级 enabledModels 白名单过滤：命中白名单且模型不在其中 → 403。
    private func enforceEnabledModels(_ key: String?, providerID: String, modelID: String) -> HTTPResponse? {
        guard let key, let gateway = config.gatewayKeyConfig(for: key),
              let enabled = gateway.enabledModels else {
            return nil
        }
        let normalized = normalizedModelID(providerID: providerID, modelID: modelID)
        if enabled.contains(normalized) { return nil }
        return HTTPResponse.text(
            403,
            "{\"error\":\"Model \(normalized) is not enabled for this gateway key\"}",
            contentType: "application/json"
        )
    }

    /// 归一化模型 ID：`"<alias>/<modelID>"`（无别名用 provider id），与 enabledModels 白名单格式一致。
    private func normalizedModelID(providerID: String, modelID: String) -> String {
        let alias = registry.descriptor(for: providerID)?.alias ?? providerID
        return "\(alias)/\(modelID)"
    }

    private func unauthorized() -> HTTPResponse {
        HTTPResponse.text(401, "{\"error\":\"Invalid API key\"}", contentType: "application/json")
    }

    // MARK: - 端点

    private func healthResponse() -> HTTPResponse {
        HTTPResponse.text(200, "{\"status\":\"ok\",\"version\":1}", contentType: "application/json")
    }

    private func handleModels(_ request: HTTPRequest) async -> HTTPResponse {
        guard authorized(request) else { return unauthorized() }

        struct ModelItem: Codable {
            let id: String
            let object: String
            let ownedBy: String
            private enum CodingKeys: String, CodingKey {
                case id
                case object
                case ownedBy = "owned_by"
            }
        }
        struct ListResponse: Codable {
            let object: String
            let data: [ModelItem]
        }

        var seen = Set<String>()
        var items: [ModelItem] = []
        // 模型 id 统一归一化为 `<alias>/<modelID>`（无别名用 provider id），
        // 与网关 key 白名单格式及 Router 的 `alias/model` 解析一致。
        // 这样同名模型（如 deepseek-v4-flash 同时存在于 codebuddy-cn 与 deepseek）可被区分。
        let appendModel = { (alias: String, modelID: String, providerID: String) in
            let normalized = "\(alias)/\(modelID)"
            guard seen.insert(normalized).inserted else { return }
            items.append(ModelItem(id: normalized, object: "model", ownedBy: providerID))
        }

        // 网关 key 级白名单过滤（Phase 12）：key.enabledModels 非 nil 时，只返回白名单内模型
        let allowedModels: Set<String>? = {
            guard let key = authenticatedKey(request), let gateway = config.gatewayKeyConfig(for: key),
                  let enabled = gateway.enabledModels else { return nil }
            return Set(enabled)
        }()
        let isModelAllowed = { (aliasOrID: String, modelID: String) in
            guard let allowedModels else { return true }
            return allowedModels.contains("\(aliasOrID)/\(modelID)")
        }

        // 供应商级模型禁用（设置面板「禁用」开关）：禁用模型视为不存在，不进 /v1/models
        let isModelDisabled = { (providerID: String, modelID: String) in
            config.providers[providerID]?.isModelDisabled(modelID) ?? false
        }

        for descriptor in registry.orderedDescriptors(config.providerOrder) {
            // 仅处理已注册且启用的 provider
            guard config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id) else { continue }

            let alias = descriptor.alias ?? descriptor.id

            // 尝试动态获取（失败静默回退静态目录）
            var dynamicModels: [Model]?
            if let provider = registry.provider(for: descriptor.id) {
                do {
                    dynamicModels = try await provider.listModels(credential: config.credential(for: descriptor.id))
                } catch {
                    dynamicModels = nil
                }
            }

            // 静态目录与动态结果合并，按归一化 id 去重
            for model in descriptor.models where isModelAllowed(alias, model.id) && !isModelDisabled(descriptor.id, model.id) {
                appendModel(alias, model.id, descriptor.id)
            }
            for model in dynamicModels ?? [] where isModelAllowed(alias, model.id) && !isModelDisabled(descriptor.id, model.id) {
                appendModel(alias, model.id, descriptor.id)
            }
        }

        let response = ListResponse(object: "list", data: items)
        return (try? HTTPResponse.json(200, object: response))
            ?? HTTPResponse.text(500, "{\"error\":\"encode failed\"}", contentType: "application/json")
    }

    private func handleChat(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard authorized(request) else { return unauthorized() }
        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse.text(400, "{\"error\":\"empty body\"}", contentType: "application/json")
        }

        let chatRequest: ChatRequest
        do {
            chatRequest = try JSONDecoder().decode(ChatRequest.self, from: body)
        } catch {
            return HTTPResponse.text(400, "{\"error\":\"invalid JSON: \(error.localizedDescription)\"}", contentType: "application/json")
        }

        guard let resolution = router.resolve(chatRequest.model) else {
            return HTTPResponse.text(404, "{\"error\":\"Unknown model: \(chatRequest.model)\"}", contentType: "application/json")
        }
        guard let provider = registry.provider(for: resolution.providerID) else {
            return HTTPResponse.text(404, "{\"error\":\"Unknown provider: \(resolution.providerID)\"}", contentType: "application/json")
        }

        // 供应商级模型禁用：禁用模型视为不存在（与 /v1/models 不展示保持一致）
        if config.providers[resolution.providerID]?.isModelDisabled(resolution.modelID) == true {
            return HTTPResponse.text(404, "{\"error\":\"Unknown model: \(chatRequest.model)\"}", contentType: "application/json")
        }

        // 网关 key 级白名单过滤（Phase 12）：key.enabledModels 非 nil 且模型不在其中 → 403
        if let forbidden = enforceEnabledModels(authenticatedKey(request), providerID: resolution.providerID, modelID: resolution.modelID) {
            logger.log(RequestLogEntry(
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: 403,
                durationMS: 0,
                error: "model not enabled for gateway key"))
            return forbidden
        }

        var forwarded = chatRequest
        forwarded.model = resolution.modelID
        forwarded.rawBody = body

        let credential = config.credential(for: resolution.providerID)
        let start = Date()

        do {
            let upstream = try await provider.chat(request: forwarded, rawBody: body, credential: credential)
            let isStreaming = chatRequest.stream == true

            // 先取首个 chunk：此阶段可检测上游连接/认证错误，避免在 200 后才发现失败。
            let firstChunkBox = try await Self.firstChunk(from: upstream)
            guard let firstChunk = firstChunkBox.chunk else {
                // 空流（无数据无错误）
                logger.log(RequestLogEntry(
                    timestamp: Date(),
                    method: request.method, path: request.path,
                    providerID: resolution.providerID, model: resolution.modelID,
                    statusCode: 200,
                    durationMS: Date().timeIntervalSince(start) * 1000))
                return HTTPResponse.text(200, "{}", contentType: "application/json")
            }

            let remaining = firstChunkBox.remaining
            // Phase 22：透传 + 旁路解析 token 用量。Extractor 为单任务内可变对象（仿 IteratorHandler），
            // 每个 chunk 原样透传，流结束时用累计的 usage 回填日志条目。
            let extractor = TokenUsageExtractor()
            let entryID = UUID()
            let responseStream = AsyncThrowingStream<Data, Error> { continuation in
                Task.detached {
                    defer {
                        // 流结束（含中途出错）：冲刷残余 buffer 并回填 token；保证 continuation 必被 finish
                        if let tokens = extractor.finish() {
                            logger.updateTokens(id: entryID, tokens: tokens)
                        }
                        continuation.finish()
                    }
                    continuation.yield(extractor.process(firstChunk))
                    for try await chunk in remaining {
                        continuation.yield(extractor.process(chunk))
                    }
                }
            }

            logger.log(RequestLogEntry(
                id: entryID,
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: 200,
                durationMS: Date().timeIntervalSince(start) * 1000))

            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": isStreaming ? "text/event-stream" : "application/json"],
                body: .stream(responseStream)
            )
        } catch {
            logger.log(RequestLogEntry(
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: 502,
                durationMS: Date().timeIntervalSince(start) * 1000,
                error: error.localizedDescription))
            let msg = error.localizedDescription
            return HTTPResponse.text(502, "{\"error\":\"upstream: \(msg)\"}", contentType: "application/json")
        }
    }

    /// 从上游流中取出首个 chunk（用于提前检测上游错误），同时把剩余部分包装为新流。
    /// 避免在 `Task` 闭包内捕获可变迭代器引发的 StrictConcurrency 数据竞争。
    private static func firstChunk(
        from stream: AsyncThrowingStream<Data, Error>
    ) async throws -> (chunk: Data?, remaining: AsyncThrowingStream<Data, Error>) {
        let iterator = stream.makeAsyncIterator()
        let handler = IteratorHandler(iterator: iterator)
        guard let first = try await handler.next() else {
            return (nil, AsyncThrowingStream { $0.finish() })
        }

        let remaining = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                while let chunk = try await handler.next() {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
        return (first, remaining)
    }

    /// 持有可变迭代器的类包装（非 actor，因为 actor 无法自调用 mutating async）。
    /// 迭代顺序由 `firstChunk` 的同步逻辑决定：先取首块、再订阅剩余，故无并发调用。
    private final class IteratorHandler: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator

        init(iterator: AsyncThrowingStream<Data, Error>.Iterator) {
            self.iterator = iterator
        }

        func next() async throws -> Data? {
            try await iterator.next()
        }
    }

    private func handleUsage() -> HTTPResponse {
        struct UsageResponse: Codable {
            let totalRequests: Int
            let entries: [RequestLogEntry]
            let summary: UsageSummary
        }
        let entries = logger.allEntries()
        let response = UsageResponse(
            totalRequests: entries.count,
            entries: entries.suffix(200).reversed(),
            summary: logger.summary()
        )
        return (try? HTTPResponse.json(200, object: response))
            ?? HTTPResponse.text(500, "{\"error\":\"encode failed\"}", contentType: "application/json")
    }

    // MARK: - Web 面板

    /// 返回内嵌 HTML（由 WebPanelAssets 提供，S5 构建时自动生成）。
    private func webPanelResponse() -> HTTPResponse {
        HTTPResponse.text(200, WebPanelAssets.html, contentType: "text/html; charset=utf-8")
    }

    /// admin API 认证检查：未启用面板或未授权时返回 401/404。
    private func authorizedAdmin(_ request: HTTPRequest) -> Bool {
        // 登录端点免认证
        if request.method == "POST" && request.path == "/admin/api/login" { return true }
        guard let state else { return true }
        return state.isAuthorized(request.authorizationToken)
    }

    /// admin API 包装器：统一认证 + 面板启用检查。
    private func handleAdminAPI(_ request: HTTPRequest, panelEnabled: Bool, handler: () async throws -> HTTPResponse) async throws -> HTTPResponse {
        guard panelEnabled else {
            return HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json")
        }
        guard authorizedAdmin(request) else {
            return HTTPResponse.text(401, "{\"error\":\"Unauthorized\"}", contentType: "application/json")
        }
        return try await handler()
    }

    // MARK: - admin API 路由

    /// 管理面板路由分发（含变量路径段提取）。
    private func handleAdminRoute(_ request: HTTPRequest, panelEnabled: Bool) async throws -> HTTPResponse {
        guard panelEnabled else {
            return HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json")
        }
        // 登录端点免认证
        if request.method == "POST" && request.path == "/admin/api/login" {
            return adminLogin(request)
        }
        guard state?.isAuthorized(request.authorizationToken) ?? true else {
            return HTTPResponse.text(401, "{\"error\":\"Unauthorized\"}", contentType: "application/json")
        }

        let path = request.path
        let method = request.method

        switch (method, path) {
        case ("GET", "/admin/api/overview"):
            return try await adminOverview()
        case ("GET", "/admin/api/entries"):
            return try await adminEntries(request)
        case ("GET", "/admin/api/providers"):
            return try await adminProviders()
        case ("GET", "/admin/api/snapshots"):
            return try await adminSnapshots()
        case ("GET", "/admin/api/config"):
            return adminGetConfig()
        case ("POST", "/admin/api/config"):
            return try await adminSaveConfig(request)
        case ("POST", "/admin/api/usage/refresh"):
            return try await adminRefreshUsage()
        case ("POST", "/admin/api/keys"):
            return try await adminCreateKey(request)
        case _ where method == "POST" && path.hasPrefix("/admin/api/providers/") && path.hasSuffix("/test"):
            let providerID = String(path.dropFirst("/admin/api/providers/".count).dropLast("/test".count))
            return try await adminTestProvider(providerID, request)
        case _ where method == "DELETE" && path.hasPrefix("/admin/api/keys/"):
            let key = String(path.dropFirst("/admin/api/keys/".count))
            return try await adminDeleteKey(key)
        default:
            return HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json")
        }
    }

    // MARK: - admin API 端点

    /// 概览：服务器信息 + 请求聚合 + Token 用量。
    private func adminOverview() async throws -> HTTPResponse {
        struct OverviewResponse: Codable {
            struct ServerInfo: Codable {
                let running: Bool
                let host: String
                let port: Int
            }
            struct Summary: Codable {
                let totalRequests: Int
                let totalErrors: Int
                let activeProviders: Int
                let promptTokens: Int
                let completionTokens: Int
                let totalTokens: Int
            }
            struct ProviderHealth: Codable {
                let id: String
                let displayName: String
                let configured: Bool
                let enabled: Bool
            }
            let server: ServerInfo
            let summary: Summary
            let providers: [ProviderHealth]
        }
        let cfg = state?.get() ?? config
        let summary = logger.summary()
        var totalRequests = 0
        var totalErrors = 0
        var totalPrompt = 0
        var totalCompletion = 0
        var totalTokens = 0
        for (_, usage) in summary.byProvider {
            totalRequests += usage.requestCount
            totalErrors += usage.errorCount
            totalPrompt += usage.totalPromptTokens
            totalCompletion += usage.totalCompletionTokens
            totalTokens += usage.totalTokens
        }
        let activeProviders = registry.allDescriptors().filter { desc in
            let pc = cfg.providers[desc.id]
            return (pc?.enabled ?? ProviderCatalog.isEnabledByDefault(desc.id))
                && cfg.credential(for: desc.id).hasAnyCredential
        }.count
        var providerHealths: [OverviewResponse.ProviderHealth] = []
        for desc in registry.orderedDescriptors(cfg.providerOrder) {
            let pc = cfg.providers[desc.id]
            let enabled = pc?.enabled ?? ProviderCatalog.isEnabledByDefault(desc.id)
            let configured = cfg.credential(for: desc.id).hasAnyCredential
            providerHealths.append(OverviewResponse.ProviderHealth(
                id: desc.id, displayName: desc.displayName,
                configured: configured, enabled: enabled
            ))
        }
        let response = OverviewResponse(
            server: OverviewResponse.ServerInfo(running: true, host: cfg.host, port: cfg.port),
            summary: OverviewResponse.Summary(
                totalRequests: totalRequests, totalErrors: totalErrors,
                activeProviders: activeProviders,
                promptTokens: totalPrompt, completionTokens: totalCompletion,
                totalTokens: totalTokens
            ),
            providers: providerHealths
        )
        return try HTTPResponse.json(200, object: response)
    }

    /// 请求日志（倒序，默认 50 条）。
    private func adminEntries(_ request: HTTPRequest) async throws -> HTTPResponse {
        struct EntriesResponse: Codable {
            let entries: [RequestLogEntry]
        }
        let limitStr = request.queryItems["limit"] ?? "50"
        let limit = max(1, min(Int(limitStr) ?? 50, 500))
        let all = logger.allEntries()
        let sliced = Array(all.reversed().prefix(limit))
        return try HTTPResponse.json(200, object: EntriesResponse(entries: sliced))
    }

    /// Provider 列表（含配置状态）。
    private func adminProviders() async throws -> HTTPResponse {
        struct ProviderItem: Codable {
            let id: String
            let alias: String?
            let displayName: String
            let authType: String
            let configured: Bool
            let enabled: Bool
            let region: String?
            let modelCount: Int
        }
        struct ProvidersResponse: Codable {
            let providers: [ProviderItem]
        }
        let cfg = state?.get() ?? config
        var items: [ProviderItem] = []
        for desc in registry.orderedDescriptors(cfg.providerOrder) {
            let pc = cfg.providers[desc.id]
            let enabled = pc?.enabled ?? ProviderCatalog.isEnabledByDefault(desc.id)
            let configured = cfg.credential(for: desc.id).hasAnyCredential
            items.append(ProviderItem(
                id: desc.id, alias: desc.alias, displayName: desc.displayName,
                authType: desc.metadata.authType.rawValue,
                configured: configured, enabled: enabled,
                region: pc?.region,
                modelCount: desc.models.count
            ))
        }
        return try HTTPResponse.json(200, object: ProvidersResponse(providers: items))
    }

    /// 用量快照（来自 UsageCache）。
    private func adminSnapshots() async throws -> HTTPResponse {
        struct SnapshotsResponse: Codable {
            let snapshots: [String: ProviderUsageSnapshot]
        }
        // 从 UsageCache 收集所有已缓存的快照
        var snapshots: [String: ProviderUsageSnapshot] = [:]
        for desc in registry.allDescriptors() {
            if let cached = await UsageCache.shared.get(desc.id) {
                snapshots[desc.id] = cached
            }
        }
        return try HTTPResponse.json(200, object: SnapshotsResponse(snapshots: snapshots))
    }

    /// 获取配置（凭据掩码）。
    private func adminGetConfig() -> HTTPResponse {
        let cfg = state?.get() ?? config
        // 深拷贝配置并掩码凭据
        var masked = cfg
        for (id, var pc) in masked.providers {
            var maskedCred = pc.credential
            maskedCred.apiKey = maskCredential(pc.credential.apiKey)
            maskedCred.accessToken = maskCredential(pc.credential.accessToken)
            maskedCred.refreshToken = maskCredential(pc.credential.refreshToken)
            pc.credential = maskedCred
            // 掩码 apiKeys 的值
            pc.apiKeys = pc.apiKeys.map { KeyedToken(label: $0.label, value: maskCredential($0.value)) }
            masked.providers[id] = pc
        }
        // 掩码网关密码
        if masked.adminPassword != nil {
            masked.adminPassword = "••••••••"
        }
        return (try? HTTPResponse.json(200, object: masked))
            ?? HTTPResponse.text(500, "{\"error\":\"encode failed\"}", contentType: "application/json")
    }

    /// 登录：验证密码，返回 token。
    private func adminLogin(_ request: HTTPRequest) -> HTTPResponse {
        guard let state else {
            return HTTPResponse.text(200, "{\"token\":\"\"}", contentType: "application/json")
        }
        struct LoginRequest: Decodable {
            let password: String
        }
        guard let body = request.body,
              let loginReq = try? JSONDecoder().decode(LoginRequest.self, from: body) else {
            return HTTPResponse.text(400, "{\"error\":\"invalid request\"}", contentType: "application/json")
        }
        guard let token = state.verifyPassword(loginReq.password) else {
            return HTTPResponse.text(401, "{\"error\":\"Unauthorized\"}", contentType: "application/json")
        }
        let response = "{\"token\":\"\(token)\"}"
        return HTTPResponse.text(200, response, contentType: "application/json")
    }

    /// 保存配置（热更新）。
    private func adminSaveConfig(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let body = request.body else {
            return HTTPResponse.text(400, "{\"error\":\"empty body\"}", contentType: "application/json")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let newConfig = try? decoder.decode(RouteConfig.self, from: body) else {
            return HTTPResponse.text(400, "{\"error\":\"invalid config\"}", contentType: "application/json")
        }
        if let state {
            state.update { config in
                config.webPanelEnabled = newConfig.webPanelEnabled
                config.adminPassword = newConfig.adminPassword
                config.host = newConfig.host
                config.port = newConfig.port
                config.providers = newConfig.providers
                config.providerOrder = newConfig.providerOrder
                config.apiKeys = newConfig.apiKeys
                config.customProviderDefs = newConfig.customProviderDefs
            }
            try state.saveAndReload()
        } else {
            try ConfigStore.save(newConfig)
        }
        return HTTPResponse.text(200, "{\"status\":\"ok\"}", contentType: "application/json")
    }

    /// 强制刷新全部用量。
    private func adminRefreshUsage() async throws -> HTTPResponse {
        struct SnapshotsResponse: Codable {
            let snapshots: [String: ProviderUsageSnapshot]
        }
        var snapshots: [String: ProviderUsageSnapshot] = [:]
        let cfg = state?.get() ?? config
        for desc in registry.allDescriptors() {
            guard let fetcher = desc.usageFetcherFactory() else { continue }
            let credential = cfg.credential(for: desc.id)
            do {
                let snapshot = try await fetcher.fetchUsage(credential: credential)
                await UsageCache.shared.set(snapshot)
                snapshots[desc.id] = snapshot
            } catch {
                snapshots[desc.id] = ProviderUsageSnapshot(
                    providerID: desc.id, fetchedAt: Date(), error: error.localizedDescription
                )
            }
        }
        return try HTTPResponse.json(200, object: SnapshotsResponse(snapshots: snapshots))
    }

    /// 测试 Provider 连通性。
    private func adminTestProvider(_ providerID: String, _ request: HTTPRequest) async throws -> HTTPResponse {
        struct TestResponse: Codable {
            let success: Bool
            let message: String
        }
        guard let provider = registry.provider(for: providerID) else {
            return try HTTPResponse.json(200, object: TestResponse(success: false, message: "未找到 Provider: \(providerID)"))
        }
        let cfg = state?.get() ?? config
        let credential = cfg.credential(for: providerID)
        do {
            let result = try await provider.testConnection(credential: credential)
            return try HTTPResponse.json(200, object: TestResponse(success: result.success, message: result.message))
        } catch {
            return try HTTPResponse.json(200, object: TestResponse(success: false, message: error.localizedDescription))
        }
    }

    /// 创建/更新网关 Key。
    private func adminCreateKey(_ request: HTTPRequest) async throws -> HTTPResponse {
        struct UpsertKeyRequest: Decodable {
            let key: String?
            let enabledModels: [String]?
        }
        guard let body = request.body,
              let keyReq = try? JSONDecoder().decode(UpsertKeyRequest.self, from: body) else {
            return HTTPResponse.text(400, "{\"error\":\"invalid request\"}", contentType: "application/json")
        }
        let newKey = keyReq.key ?? "sk-bv-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
        let gatewayKey = GatewayKeyConfig(key: newKey, enabledModels: keyReq.enabledModels)
        if let state {
            state.update { config in
                if let idx = config.apiKeys.firstIndex(where: { $0.key == gatewayKey.key }) {
                    config.apiKeys[idx] = gatewayKey
                } else {
                    config.apiKeys.append(gatewayKey)
                }
            }
            try state.saveAndReload()
        } else {
            var newConfig = config
            if let idx = newConfig.apiKeys.firstIndex(where: { $0.key == gatewayKey.key }) {
                newConfig.apiKeys[idx] = gatewayKey
            } else {
                newConfig.apiKeys.append(gatewayKey)
            }
            try ConfigStore.save(newConfig)
        }
        let response = try JSONEncoder().encode(gatewayKey)
        return HTTPResponse.text(200, String(data: response, encoding: .utf8) ?? "{}", contentType: "application/json")
    }

    /// 删除网关 Key。
    private func adminDeleteKey(_ key: String) async throws -> HTTPResponse {
        if let state {
            state.update { config in
                config.apiKeys.removeAll { $0.key == key }
            }
            try state.saveAndReload()
        } else {
            var newConfig = config
            newConfig.apiKeys.removeAll { $0.key == key }
            try ConfigStore.save(newConfig)
        }
        return HTTPResponse.text(200, "{\"status\":\"ok\"}", contentType: "application/json")
    }

    /// 凭据掩码：只保留前 6 后 4，中间变 ••••。
    private func maskCredential(_ value: String?) -> String? {
        guard let value, value.count > 10 else { return value }
        return "\(String(value.prefix(6)))••••\(String(value.suffix(4)))"
    }

    /// 非可选版本的凭据掩码。
    private func maskCredential(_ value: String) -> String {
        guard value.count > 10 else { return value }
        return "\(String(value.prefix(6)))••••\(String(value.suffix(4)))"
    }
}
