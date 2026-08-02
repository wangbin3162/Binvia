import Foundation

/// HTTP 路由分发器。借鉴 OmniRoute `server/authz/policies/clientApi.ts` + `src/sse/handlers/chat.ts`。
public struct RouteHandler: Sendable {
    private let config: RouteConfig
    private let authenticator: APIKeyAuthenticator
    private let router: Router
    private let registry: ProviderRegistry
    private let logger: RequestLogger

    public init(config: RouteConfig, registry: ProviderRegistry = .shared) {
        self.config = config
        self.authenticator = APIKeyAuthenticator(configuredKeys: config.gatewayKeyStrings)
        self.router = Router(registry: registry)
        self.registry = registry
        self.logger = .shared
    }

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, request.path) {
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
        let appendModel = { (id: String, providerID: String) in
            let key = "\(providerID)|\(id)"
            guard seen.insert(key).inserted else { return }
            items.append(ModelItem(id: id, object: "model", ownedBy: providerID))
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

        for descriptor in registry.allDescriptors() {
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

            // 静态目录与动态结果合并，按 (provider, model id) 去重
            for model in descriptor.models where isModelAllowed(alias, model.id) {
                appendModel(model.id, descriptor.id)
            }
            for model in dynamicModels ?? [] where isModelAllowed(alias, model.id) {
                appendModel(model.id, descriptor.id)
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
            let responseStream = AsyncThrowingStream<Data, Error> { continuation in
                Task.detached {
                    continuation.yield(firstChunk)
                    for try await chunk in remaining {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                }
            }

            logger.log(RequestLogEntry(
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
}
