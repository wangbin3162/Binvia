import Foundation

/// HTTP 路由分发器。借鉴 OmniRoute `server/authz/policies/clientApi.ts` + `src/sse/handlers/chat.ts`。
public struct RouteHandler: Sendable {
    private let config: RouteConfig
    private let authenticator: APIKeyAuthenticator
    private let router: Router
    private let registry: ProviderRegistry
    private let logger: RequestLogger
    private let sessionStore: any ResponsesSessionStoring

    public init(
        config: RouteConfig,
        registry: ProviderRegistry = .shared,
        sessionStore: any ResponsesSessionStoring = ResponsesSessionStore.shared
    ) {
        self.config = config
        self.authenticator = APIKeyAuthenticator(configuredKeys: config.gatewayKeyStrings)
        self.router = Router(registry: registry)
        self.registry = registry
        self.logger = .shared
        self.sessionStore = sessionStore
    }

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, normalizePath(request.path)) {
        case ("OPTIONS", _):
            return Self.optionsResponse()
        case ("GET", "/v1/health"):
            return healthResponse()
        case ("GET", "/v1/models"):
            return await handleModels(request)
        case ("POST", "/v1/chat/completions"):
            return try await handleChat(request)
        case ("POST", "/v1/responses"):
            guard FeatureFlags.enableResponses else {
                return Self.withCORS(HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json"))
            }
            return Self.withCORS(try await handleResponses(request))
        case ("POST", "/v1/messages"):
            guard FeatureFlags.enableMessages else {
                return Self.withCORS(HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json"))
            }
            return Self.withCORS(try await handleAnthropicMessages(request))
        case ("GET", "/v1/usage"):
            return handleUsage()
        default:
            return HTTPResponse.text(404, "{\"error\":\"Not Found\"}", contentType: "application/json")
        }
    }

    /// 端点开关（计划 §8，默认开启，环境变量可关闭）。
    private enum FeatureFlags {
        static var enableResponses: Bool {
            RouteConfig.envValue(["BINVIA_ENABLE_RESPONSES"]) != "0"
        }
        static var enableMessages: Bool {
            RouteConfig.envValue(["BINVIA_ENABLE_MESSAGES"]) != "0"
        }
        /// F4：provider 级高级工具透传开关，默认关闭（保持第一版跳过行为）。
        static var serverToolsEnabled: Bool {
            RouteConfig.envValue(["BINVIA_SERVER_TOOLS"]) == "1"
        }
    }

    /// 路径归一化：兼容未带 `/v1` 前缀的客户端。
    /// 例如 opencode 配置 `baseURL` 漏写 `/v1` 时，AI SDK 会请求 `/chat/completions` 而非
    /// `/v1/chat/completions`，此处自动补前缀避免 404 Not Found。
    private func normalizePath(_ path: String) -> String {
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
            let contextLength: Int
            private enum CodingKeys: String, CodingKey {
                case id
                case object
                case ownedBy = "owned_by"
                case contextLength = "context_length"
            }
        }
        struct ListResponse: Codable {
            let object: String
            let data: [ModelItem]
        }

        var seen = Set<String>()
        var items: [ModelItem] = []
        // 模型 id 统一归一化为 `<alias>/<displayName>`（无别名用 provider id），
        // 与网关 key 白名单格式及 Router 的 `alias/model` 解析一致。
        // 显示名称为空时回退到 modelName，避免显示空白。
        let appendModel = { (alias: String, displayID: String, providerID: String, contextLength: Int) in
            let normalized = "\(alias)/\(displayID)"
            guard seen.insert(normalized).inserted else { return }
            items.append(ModelItem(id: normalized, object: "model", ownedBy: providerID, contextLength: contextLength))
        }

        // 网关 key 级白名单过滤（Phase 12）：key.enabledModels 非 nil 时，只返回白名单内模型
        let allowedModels: Set<String>? = {
            guard let key = authenticatedKey(request), let gateway = config.gatewayKeyConfig(for: key),
                  let enabled = gateway.enabledModels else { return nil }
            return Set(enabled)
        }()
        let isModelAllowed = { (aliasOrID: String, displayID: String) in
            guard let allowedModels else { return true }
            return allowedModels.contains("\(aliasOrID)/\(displayID)")
        }

        // 只返回用户在设置面板配置的模型列表（userModels），不再动态拉取上游。
        for descriptor in registry.orderedDescriptors(config.providerOrder) {
            guard config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id) else { continue }

            let alias = descriptor.alias ?? descriptor.id
            let userModels = config.providers[descriptor.id]?.userModels ?? []
            for entry in userModels where isModelAllowed(alias, entry.effectiveDisplayName) {
                appendModel(alias, entry.effectiveDisplayName, descriptor.id, entry.contextLength)
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
        // resolution.modelID 现在是显示名称（/v1/models 返回 alias/displayName），
        // 转发上游前需映射回真实模型名。找不到映射时保持原值（兼容旧路由）。
        let userModels = config.providers[resolution.providerID]?.userModels ?? []
        let realModelName = userModels.first { $0.effectiveDisplayName == resolution.modelID }?.modelName
            ?? resolution.modelID
        forwarded.model = realModelName
        forwarded.rawBody = body

        let credential = config.credential(for: resolution.providerID)
        let start = Date()

        do {
            let isStreaming = chatRequest.stream == true
            // 先取首个 chunk：此阶段可检测上游连接/认证错误、执行 readiness 超时与
            // 首包前早断（empty stream）单次重试，避免在 200 后才发现失败。
            let firstChunkBox = try await Self.openStream(
                provider: provider,
                request: forwarded,
                rawBody: body,
                credential: credential,
                readinessTimeout: StreamConfig.readinessTimeout,
                earlyEOFRetryLimit: StreamConfig.earlyEOFRetryLimit
            )
            let firstChunk = firstChunkBox.chunk
            let remaining = firstChunkBox.remaining
            // Phase 22：透传 + 旁路解析 token 用量。Extractor 为单任务内可变对象（仿 IteratorHandler），
            // 每个 chunk 原样透传，流结束时用累计的 usage 回填日志条目。
            let extractor = TokenUsageExtractor()
            let entryID = UUID()
            let responseStream = AsyncThrowingStream<Data, Error> { continuation in
                let task = Task.detached {
                    defer {
                        // 流结束（含中途出错）：冲刷残余 buffer 并回填 token；保证 continuation 必被 finish
                        if let tokens = extractor.finish() {
                            logger.updateTokens(id: entryID, tokens: tokens)
                        }
                        continuation.finish()
                    }
                    do {
                        // 流式客户端走事件级 SSE 归一化（补 finish_reason / [DONE] / JSON 转 SSE）；
                        // 非流式客户端保持字节透传（上游返回完整 JSON，不做 SSE 改写）。
                        let normalizer = isStreaming ? SSEStreamNormalizer() : nil
                        let handler = IteratorHandler(iterator: remaining.makeAsyncIterator())
                        let idle = StreamIdleMonitor()
                        if let normalizer {
                            for data in normalizer.process(firstChunk) {
                                continuation.yield(data)
                            }
                        } else {
                            continuation.yield(extractor.process(firstChunk))
                        }
                        idle.touch()
                        while true {
                            let chunk = try await Self.nextChunkWithIdleWatchdog(
                                handler: handler,
                                idle: idle,
                                idleTimeout: StreamConfig.idleTimeout
                            )
                            guard let chunk else { break }
                            idle.touch()
                            if let normalizer {
                                for data in normalizer.process(chunk) {
                                    continuation.yield(data)
                                }
                            } else {
                                continuation.yield(extractor.process(chunk))
                            }
                        }
                        if let normalizer {
                            for data in normalizer.finish() {
                                continuation.yield(data)
                            }
                        }
                    } catch {
                        // 客户端断开时不再写错误体，由 onTermination 记录 client_disconnected。
                        guard !Task.isCancelled else { return }
                        let code = Self.streamErrorCode(for: error)
                        if let payload = Self.errorPayload(isStreaming: isStreaming, error: error, code: code) {
                            continuation.yield(payload)
                        }
                        logger.updateErrorCode(id: entryID, code: code.rawValue)
                    }
                }
                continuation.onTermination = { reason in
                    if case .cancelled = reason {
                        logger.updateErrorCode(id: entryID, code: StreamErrorCode.clientDisconnected.rawValue)
                    }
                    task.cancel()
                }
            }

            logger.log(RequestLogEntry(
                id: entryID,
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: 200,
                durationMS: Date().timeIntervalSince(start) * 1000,
                retries: firstChunkBox.earlyEOFRetries > 0 ? firstChunkBox.earlyEOFRetries : nil))

            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": isStreaming ? "text/event-stream" : "application/json"],
                body: .stream(responseStream)
            )
        } catch {
            let mapping = Self.errorMapping(for: error)
            logger.log(RequestLogEntry(
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: mapping.statusCode,
                durationMS: Date().timeIntervalSince(start) * 1000,
                error: mapping.message,
                errorCode: mapping.code.rawValue))
            return HTTPResponse.text(
                mapping.statusCode,
                "{\"error\":\"upstream: \(mapping.message)\",\"code\":\"\(mapping.code.rawValue)\"}",
                contentType: "application/json"
            )
        }
    }

    /// POST /v1/responses（阶段 B：非流式）。
    ///
    /// 客户端请求翻译成 ChatRequest 后复用完整上游链路；上游返回 Chat JSON 时
    /// 翻译成 Responses Response JSON。流式请求目前返回 501，阶段 C 补齐。
    private func handleResponses(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard authorized(request) else { return unauthorized() }
        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse.text(
                400,
                String(data: Self.openAIErrorJSON(message: "empty body", code: "invalid_request") ?? Data(),
                       encoding: .utf8) ?? "{\"error\":\"empty body\"}",
                contentType: "application/json"
            )
        }

        let translation: ResponsesTranslationResult
        do {
            let previousID = try ResponsesRequestReader.previousResponseID(body)
            let history: [ChatMessage]?
            if let previousID {
                guard let stored = sessionStore.history(for: previousID) else {
                    return HTTPResponse.text(
                        400,
                        "{\"error\":\"unknown previous_response_id\"}",
                        contentType: "application/json"
                    )
                }
                history = stored
            } else {
                history = nil
            }
            translation = try ResponsesRequestTranslator.translate(
                body: body,
                history: history ?? [],
                serverToolsEnabled: FeatureFlags.serverToolsEnabled
            )
        } catch {
            return HTTPResponse.text(
                400,
                String(data: Self.openAIErrorJSON(
                    message: error.localizedDescription,
                    code: "invalid_request"
                ) ?? Data(), encoding: .utf8) ?? "{\"error\":\"invalid request\"}",
                contentType: "application/json"
            )
        }
        let translated = translation.request

        guard let resolution = router.resolve(translated.model) else {
            return HTTPResponse.text(404, "{\"error\":\"Unknown model: \(translated.model)\"}", contentType: "application/json")
        }
        guard let provider = registry.provider(for: resolution.providerID) else {
            return HTTPResponse.text(404, "{\"error\":\"Unknown provider: \(resolution.providerID)\"}", contentType: "application/json")
        }
        if let forbidden = enforceEnabledModels(authenticatedKey(request), providerID: resolution.providerID, modelID: resolution.modelID) {
            return forbidden
        }

        var forwarded = translated
        let userModels = config.providers[resolution.providerID]?.userModels ?? []
        let realModelName = userModels.first { $0.effectiveDisplayName == resolution.modelID }?.modelName
            ?? resolution.modelID
        forwarded.model = realModelName
        forwarded.rawBody = translated.rawBody

        let credential = config.credential(for: resolution.providerID)
        let start = Date()
        let responseID = "resp_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        do {
            let isStreaming = translated.stream == true
            // 非流式统一按流处理：上游返回完整 JSON 时 firstChunk 拿到整段 body，
            // 后续 EOF；上游强制流式时由聚合层合成 JSON 后再交给这里翻译。
            let upstream = try await provider.chat(
                request: forwarded,
                rawBody: forwarded.rawBody,
                credential: credential
            )
            if !isStreaming {
                let aggregated = try await Self.aggregateChatResponse(upstream, timeout: StreamConfig.readinessTimeout)
                let translatedData = try ResponsesResponseTranslator.translate(
                    chatJSON: aggregated,
                    responseID: responseID,
                    toolIdentity: translation.toolIdentity
                )

                // 把当轮 Chat 消息加入会话表，供 previous_response_id 续接。
                let fullHistory = translated.messages + [ChatMessage(
                    role: .assistant,
                    content: .text(Self.assistantContent(from: aggregated)),
                    toolCalls: Self.assistantToolCalls(from: aggregated)
                )]
                sessionStore.store(responseID: responseID, messages: fullHistory)

                logger.log(RequestLogEntry(
                    timestamp: Date(),
                    method: request.method, path: request.path,
                    providerID: resolution.providerID, model: resolution.modelID,
                    statusCode: 200,
                    durationMS: Date().timeIntervalSince(start) * 1000
                ))
                return HTTPResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: .data(translatedData)
                )
            }

            // 流式：竞速取首个 chunk，超过心跳阈值先回 200 SSE 并持续心跳（J）。
            let heartbeat = try await Self.openStreamWithHeartbeat(
                provider: provider,
                request: forwarded,
                rawBody: forwarded.rawBody,
                credential: credential,
                readinessTimeout: StreamConfig.readinessTimeout,
                earlyEOFRetryLimit: StreamConfig.earlyEOFRetryLimit
            )
            let translator = ResponsesStreamTranslator(
                responseID: responseID,
                toolIdentity: translation.toolIdentity,
                emitStartEventsEnabled: heartbeat.box != nil
            )
            // 上游可能返回纯 JSON（忽略 stream=true）或缺 finish_reason；
            // 先用 Chat 格式 normalizer 归一化成 SSE 再翻译，保证 translator 只看到事件。
            let normalizer = SSEStreamNormalizer(format: .openaiChat)
            let entryID = UUID()
            let responseStream = Self.responsesTranslationStream(
                box: heartbeat.box,
                upstreamTask: heartbeat.upstreamTask,
                heartbeatFrame: heartbeat.box == nil ? Self.responsesHeartbeatFrame(responseID: responseID) : nil,
                translator: translator,
                normalizer: normalizer,
                historyMessages: translated.messages,
                responseID: responseID,
                sessionStore: sessionStore,
                entryID: entryID,
                logger: logger
            )
            let retries = heartbeat.box?.earlyEOFRetries ?? 0

            logger.log(RequestLogEntry(
                id: entryID,
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: 200,
                durationMS: Date().timeIntervalSince(start) * 1000,
                retries: retries > 0 ? retries : nil
            ))
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: .stream(responseStream)
            )
        } catch {
            let mapping = Self.errorMapping(for: error)
            logger.log(RequestLogEntry(
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: mapping.statusCode,
                durationMS: Date().timeIntervalSince(start) * 1000,
                error: mapping.message,
                errorCode: mapping.code.rawValue))
            return HTTPResponse.text(
                mapping.statusCode,
                String(data: Self.openAIErrorJSON(
                    message: "upstream: \(mapping.message)",
                    code: mapping.code.rawValue,
                    type: "upstream_error",
                    status: mapping.statusCode
                ) ?? Data(), encoding: .utf8) ?? "{\"error\":\"upstream error\"}",
                contentType: "application/json"
            )
        }
    }

    /// POST /v1/messages（阶段 D：Anthropic Messages API）。
    private func handleAnthropicMessages(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard authorized(request) else { return unauthorized() }
        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse.text(
                400,
                String(data: Self.anthropicErrorJSON(message: "empty body", code: "invalid_request") ?? Data(),
                       encoding: .utf8) ?? "{\"type\":\"error\"}",
                contentType: "application/json"
            )
        }

        let translated: ChatRequest
        do {
            translated = try AnthropicRequestTranslator.translate(
                body: body,
                serverToolsEnabled: FeatureFlags.serverToolsEnabled
            )
        } catch {
            return HTTPResponse.text(
                400,
                String(data: Self.anthropicErrorJSON(
                    message: error.localizedDescription,
                    code: "invalid_request"
                ) ?? Data(), encoding: .utf8) ?? "{\"type\":\"error\"}",
                contentType: "application/json"
            )
        }

        guard let resolution = router.resolve(translated.model) else {
            return HTTPResponse.text(404, "{\"error\":\"Unknown model: \(translated.model)\"}", contentType: "application/json")
        }
        guard let provider = registry.provider(for: resolution.providerID) else {
            return HTTPResponse.text(404, "{\"error\":\"Unknown provider: \(resolution.providerID)\"}", contentType: "application/json")
        }
        if let forbidden = enforceEnabledModels(authenticatedKey(request), providerID: resolution.providerID, modelID: resolution.modelID) {
            return forbidden
        }

        var forwarded = translated
        let userModels = config.providers[resolution.providerID]?.userModels ?? []
        let realModelName = userModels.first { $0.effectiveDisplayName == resolution.modelID }?.modelName
            ?? resolution.modelID
        forwarded.model = realModelName
        forwarded.rawBody = translated.rawBody

        let credential = config.credential(for: resolution.providerID)
        let start = Date()
        let messageID = "msg_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        do {
            let isStreaming = translated.stream == true
            let upstream = try await provider.chat(
                request: forwarded,
                rawBody: forwarded.rawBody,
                credential: credential
            )
            if !isStreaming {
                let aggregated = try await Self.aggregateChatResponse(upstream, timeout: StreamConfig.readinessTimeout)
                let translatedData = try AnthropicResponseTranslator.translate(chatJSON: aggregated, messageID: messageID)
                logger.log(RequestLogEntry(
                    timestamp: Date(),
                    method: request.method, path: request.path,
                    providerID: resolution.providerID, model: resolution.modelID,
                    statusCode: 200,
                    durationMS: Date().timeIntervalSince(start) * 1000
                ))
                return HTTPResponse(
                    status: 200,
                    headers: ["Content-Type": "application/json"],
                    body: .data(translatedData)
                )
            }

            // 流式：竞速取首个 chunk，超过心跳阈值先回 200 SSE 并持续 ping（J）。
            let heartbeat = try await Self.openStreamWithHeartbeat(
                provider: provider,
                request: forwarded,
                rawBody: forwarded.rawBody,
                credential: credential,
                readinessTimeout: StreamConfig.readinessTimeout,
                earlyEOFRetryLimit: StreamConfig.earlyEOFRetryLimit
            )
            let translator = AnthropicStreamTranslator(messageID: messageID)
            let normalizer = SSEStreamNormalizer(format: .openaiChat)
            let entryID = UUID()
            let responseStream = Self.anthropicTranslationStream(
                box: heartbeat.box,
                upstreamTask: heartbeat.upstreamTask,
                heartbeatFrame: heartbeat.box == nil ? Self.anthropicHeartbeatFrame : nil,
                translator: translator,
                normalizer: normalizer,
                entryID: entryID,
                logger: logger
            )
            let retries = heartbeat.box?.earlyEOFRetries ?? 0

            logger.log(RequestLogEntry(
                id: entryID,
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: 200,
                durationMS: Date().timeIntervalSince(start) * 1000,
                retries: retries > 0 ? retries : nil
            ))
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: .stream(responseStream)
            )
        } catch {
            let mapping = Self.errorMapping(for: error)
            logger.log(RequestLogEntry(
                timestamp: Date(),
                method: request.method, path: request.path,
                providerID: resolution.providerID, model: resolution.modelID,
                statusCode: mapping.statusCode,
                durationMS: Date().timeIntervalSince(start) * 1000,
                error: mapping.message,
                errorCode: mapping.code.rawValue))
            return HTTPResponse.text(
                mapping.statusCode,
                String(data: Self.anthropicErrorJSON(
                    message: "upstream: \(mapping.message)",
                    code: mapping.code.rawValue
                ) ?? Data(), encoding: .utf8) ?? "{\"type\":\"error\"}",
                contentType: "application/json"
            )
        }
    }

    /// 非流式 Responses 请求体读取器（保持翻译器纯函数）。
    private enum ResponsesRequestReader {
        static func previousResponseID(_ body: Data) throws -> String? {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw ResponsesTranslationError("invalid JSON")
            }
            return json["previous_response_id"] as? String
        }
    }

    /// 聚合上游流为单个 Chat JSON（强制流式 provider 由 Provider 层先聚合，
    /// 这里兜底处理上游忽略 stream=false 直接返回 SSE 的情况）。
    private static func aggregateChatResponse(
        _ stream: AsyncThrowingStream<Data, Error>,
        timeout: TimeInterval
    ) async throws -> Data {
        let handler = IteratorHandler(iterator: stream.makeAsyncIterator())
        // 完整缓冲上游字节：socket 可能把单个 JSON 拆成多个 chunk，
        // 不能只看首 chunk 就决定走 SSE 聚合。
        let buffered = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                let idle = StreamIdleMonitor()
                while true {
                    let chunk = try await Self.nextChunkWithIdleWatchdog(
                        handler: handler,
                        idle: idle,
                        idleTimeout: StreamConfig.idleTimeout
                    )
                    guard let chunk else { break }
                    idle.touch()
                    data.append(chunk)
                }
                guard !data.isEmpty else {
                    throw StreamError(
                        code: .streamEarlyEOF,
                        message: "上游在首个事件前结束（empty stream）",
                        statusCode: 502
                    )
                }
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw StreamError(
                    code: .streamReadinessTimeout,
                    message: "上游 \(Int(timeout))s 内未返回完整响应",
                    statusCode: 504
                )
            }
            do {
                guard let result = try await group.next() else {
                    throw StreamError(
                        code: .streamReadinessTimeout,
                        message: "上游 \(Int(timeout))s 内未返回完整响应",
                        statusCode: 504
                    )
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }

        // 纯 JSON 上游（忽略 stream=false 或直接返回 JSON）：原样返回。
        if isChatCompletionJSON(buffered) {
            return buffered
        }

        // SSE 上游：交给聚合器（把已缓冲字节作为一个 chunk 喂入）。
        let remaining = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(buffered)
            continuation.finish()
        }
        return try await SSEJSONAggregator.aggregateChatCompletion(remaining)
    }

    private static func isChatCompletionJSON(_ data: Data) -> Bool {
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.hasPrefix("{") else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["choices"] as? [[String: Any]])?.isEmpty == false
    }

    private static func assistantContent(from chatJSON: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: chatJSON) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return "" }
        return content
    }

    private static func assistantToolCalls(from chatJSON: Data) -> [ToolCall]? {
        guard let json = try? JSONSerialization.jsonObject(with: chatJSON) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let calls = message["tool_calls"] as? [[String: Any]] else { return nil }
        return calls.map { call in
            let function = (call["function"] as? [String: Any]) ?? [:]
            return ToolCall(
                id: call["id"] as? String,
                type: call["type"] as? String,
                function: ToolCallFunction(
                    name: function["name"] as? String,
                    arguments: function["arguments"] as? String
                )
            )
        }
    }

    /// 打开上游流：readiness 超时内取首个 chunk；首包前空流按配置最多重试一次。
    private static func openStream(
        provider: Provider,
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?,
        readinessTimeout: TimeInterval,
        earlyEOFRetryLimit: Int
    ) async throws -> FirstChunkBox {
        var retries = 0
        while true {
            let upstream = try await provider.chat(request: request, rawBody: rawBody, credential: credential)
            let first = try await firstChunk(from: upstream, readinessTimeout: readinessTimeout)
            if let chunk = first.chunk {
                return FirstChunkBox(chunk: chunk, remaining: first.remaining, earlyEOFRetries: retries)
            }
            guard retries < earlyEOFRetryLimit else {
                throw StreamError(
                    code: .streamEarlyEOF,
                    message: "上游在首个事件前结束（empty stream）",
                    statusCode: 502
                )
            }
            retries += 1
        }
    }

    /// 从上游流中取出首个 chunk（readiness 超时内；超时抛 `stream_readiness_timeout`），
    /// 同时把剩余部分包装为新流。超时后取消读取任务，避免上游连接泄漏。
    private static func firstChunk(
        from stream: AsyncThrowingStream<Data, Error>,
        readinessTimeout: TimeInterval
    ) async throws -> (chunk: Data?, remaining: AsyncThrowingStream<Data, Error>) {
        try await withThrowingTaskGroup(of: FirstChunkResult.self) { group in
            group.addTask {
                let iterator = stream.makeAsyncIterator()
                let handler = IteratorHandler(iterator: iterator)
                guard let first = try await handler.next() else {
                    return FirstChunkResult(chunk: nil, remaining: AsyncThrowingStream { $0.finish() })
                }
                let remaining = AsyncThrowingStream<Data, Error> { continuation in
                    Task {
                        do {
                            while let chunk = try await handler.next() {
                                continuation.yield(chunk)
                            }
                            continuation.finish()
                        } catch {
                            // 首个 chunk 之后的上游错误必须继续传播，否则本地连接会一直挂起或静默 EOF。
                            continuation.finish(throwing: error)
                        }
                    }
                }
                return FirstChunkResult(chunk: first, remaining: remaining)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(readinessTimeout))
                throw StreamError(
                    code: .streamReadinessTimeout,
                    message: "上游 \(Int(readinessTimeout))s 内未返回首个事件",
                    statusCode: 504
                )
            }
            do {
                guard let result = try await group.next() else {
                    throw StreamError(
                        code: .streamReadinessTimeout,
                        message: "上游 \(Int(readinessTimeout))s 内未返回首个事件",
                        statusCode: 504
                    )
                }
                group.cancelAll()
                return (result.chunk, result.remaining)
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// 首个 chunk 竞速结果：快路径直接拿到 box；慢路径持有仍在等待的上游任务。
    private struct HeartbeatOpenResult: Sendable {
        let box: FirstChunkBox?
        let upstreamTask: Task<FirstChunkBox, Error>?
    }

    /// 打开上游流并竞速心跳阈值：阈值内拿到首包走快路径（保留真实 HTTP 错误码），
    /// 超时后提前提交 200 SSE，由流内部持续心跳直到上游就绪（J）。
    private static func openStreamWithHeartbeat(
        provider: Provider,
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?,
        readinessTimeout: TimeInterval,
        earlyEOFRetryLimit: Int
    ) async throws -> HeartbeatOpenResult {
        let upstream = Task {
            try await Self.openStream(
                provider: provider,
                request: request,
                rawBody: rawBody,
                credential: credential,
                readinessTimeout: readinessTimeout,
                earlyEOFRetryLimit: earlyEOFRetryLimit
            )
        }
        do {
            let outcome = try await withThrowingTaskGroup(of: HeartbeatRace.self) { group in
                group.addTask { .box(try await upstream.value) }
                group.addTask {
                    try await Task.sleep(for: .seconds(StreamConfig.heartbeatThreshold))
                    return .threshold
                }
                if let result = try await group.next() {
                    return result
                }
                return .threshold
            }
            switch outcome {
            case .box(let box):
                return HeartbeatOpenResult(box: box, upstreamTask: nil)
            case .threshold:
                return HeartbeatOpenResult(box: nil, upstreamTask: upstream)
            }
        } catch {
            upstream.cancel()
            throw error
        }
    }

    private enum HeartbeatRace: Sendable {
        case box(FirstChunkBox)
        case threshold
    }

    /// Responses 流式响应体：可选的早期心跳 + Chat SSE 翻译。
    private static func responsesTranslationStream(
        box: FirstChunkBox?,
        upstreamTask: Task<FirstChunkBox, Error>?,
        heartbeatFrame: Data?,
        translator: ResponsesStreamTranslator,
        normalizer: SSEStreamNormalizer,
        historyMessages: [ChatMessage],
        responseID: String,
        sessionStore: any ResponsesSessionStoring,
        entryID: UUID,
        logger: RequestLogger
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                defer { continuation.finish() }
                // 首个心跳帧直接由流任务体发出，避免嵌套任务 yield 时序不确定。
                if let heartbeatFrame {
                    continuation.yield(heartbeatFrame)
                }
                let heartbeatTask = Task {
                    guard let heartbeatFrame else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(StreamConfig.heartbeatInterval))
                        if Task.isCancelled { break }
                        continuation.yield(heartbeatFrame)
                    }
                }
                do {
                    let firstChunkBox: FirstChunkBox
                    if let box {
                        firstChunkBox = box
                    } else if let upstreamTask {
                        firstChunkBox = try await upstreamTask.value
                        heartbeatTask.cancel()
                    } else {
                        return
                    }
                    let firstChunk = firstChunkBox.chunk
                    let remaining = firstChunkBox.remaining
                    let handler = IteratorHandler(iterator: remaining.makeAsyncIterator())
                    let idle = StreamIdleMonitor()
                    for data in normalizer.process(firstChunk) {
                        for translated in translator.process(data) {
                            continuation.yield(translated)
                        }
                    }
                    idle.touch()
                    while true {
                        let chunk = try await Self.nextChunkWithIdleWatchdog(
                            handler: handler,
                            idle: idle,
                            idleTimeout: StreamConfig.idleTimeout
                        )
                        guard let chunk else { break }
                        idle.touch()
                        for data in normalizer.process(chunk) {
                            for translated in translator.process(data) {
                                continuation.yield(translated)
                            }
                        }
                    }
                    for data in normalizer.finish() {
                        for translated in translator.process(data) {
                            continuation.yield(translated)
                        }
                    }
                    for data in translator.finish() {
                        continuation.yield(data)
                    }
                    // 流结束回填会话表（含 assistant 内容 / 工具调用）
                    let fullHistory = historyMessages + [ChatMessage(
                        role: .assistant,
                        content: .text(translator.assistantText),
                        toolCalls: translator.toolCalls.isEmpty ? nil : translator.toolCalls
                    )]
                    sessionStore.store(responseID: responseID, messages: fullHistory)
                } catch {
                    heartbeatTask.cancel()
                    guard !Task.isCancelled else { return }
                    let code = Self.streamErrorCode(for: error)
                    if let payload = Self.responsesErrorPayload(error: error, code: code) {
                        continuation.yield(payload)
                    }
                    logger.updateErrorCode(id: entryID, code: code.rawValue)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    logger.updateErrorCode(id: entryID, code: StreamErrorCode.clientDisconnected.rawValue)
                }
                task.cancel()
                upstreamTask?.cancel()
            }
        }
    }

    /// Anthropic 流式响应体：可选的 ping 心跳 + Chat SSE 翻译。
    private static func anthropicTranslationStream(
        box: FirstChunkBox?,
        upstreamTask: Task<FirstChunkBox, Error>?,
        heartbeatFrame: Data?,
        translator: AnthropicStreamTranslator,
        normalizer: SSEStreamNormalizer,
        entryID: UUID,
        logger: RequestLogger
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                defer { continuation.finish() }
                if let heartbeatFrame {
                    continuation.yield(heartbeatFrame)
                }
                let heartbeatTask = Task {
                    guard let heartbeatFrame else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(StreamConfig.heartbeatInterval))
                        if Task.isCancelled { break }
                        continuation.yield(heartbeatFrame)
                    }
                }
                do {
                    let firstChunkBox: FirstChunkBox
                    if let box {
                        firstChunkBox = box
                    } else if let upstreamTask {
                        firstChunkBox = try await upstreamTask.value
                        heartbeatTask.cancel()
                    } else {
                        return
                    }
                    let firstChunk = firstChunkBox.chunk
                    let remaining = firstChunkBox.remaining
                    let handler = IteratorHandler(iterator: remaining.makeAsyncIterator())
                    let idle = StreamIdleMonitor()
                    for data in normalizer.process(firstChunk) {
                        for translated in translator.process(data) {
                            continuation.yield(translated)
                        }
                    }
                    idle.touch()
                    while true {
                        let chunk = try await Self.nextChunkWithIdleWatchdog(
                            handler: handler,
                            idle: idle,
                            idleTimeout: StreamConfig.idleTimeout
                        )
                        guard let chunk else { break }
                        idle.touch()
                        for data in normalizer.process(chunk) {
                            for translated in translator.process(data) {
                                continuation.yield(translated)
                            }
                        }
                    }
                    for data in normalizer.finish() {
                        for translated in translator.process(data) {
                            continuation.yield(translated)
                        }
                    }
                    for data in translator.finish() {
                        continuation.yield(data)
                    }
                } catch {
                    heartbeatTask.cancel()
                    guard !Task.isCancelled else { return }
                    let code = Self.streamErrorCode(for: error)
                    if let payload = Self.anthropicErrorPayload(error: error, code: code) {
                        continuation.yield(payload)
                    }
                    logger.updateErrorCode(id: entryID, code: code.rawValue)
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason {
                    logger.updateErrorCode(id: entryID, code: StreamErrorCode.clientDisconnected.rawValue)
                }
                task.cancel()
                upstreamTask?.cancel()
            }
        }
    }

    /// Responses 心跳帧：先 response.created 再 response.in_progress，
    /// 翻译器在慢路径下跳过自己的 start 事件避免重复。
    private static func responsesHeartbeatFrame(responseID: String) -> Data {
        let created: [String: Any] = [
            "type": "response.created",
            "response": baseHeartbeatResponse(id: responseID),
        ]
        let inProgress: [String: Any] = [
            "type": "response.in_progress",
            "response": baseHeartbeatResponse(id: responseID),
        ]
        guard let createdData = try? JSONSerialization.data(withJSONObject: created),
              let inProgressData = try? JSONSerialization.data(withJSONObject: inProgress) else {
            return Data()
        }
        let frame = "event: response.created\ndata: \(String(decoding: createdData, as: UTF8.self))\n\n"
            + "event: response.in_progress\ndata: \(String(decoding: inProgressData, as: UTF8.self))\n\n"
        return Data(frame.utf8)
    }

    private static func baseHeartbeatResponse(id: String) -> [String: Any] {
        [
            "id": id,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "in_progress",
        ]
    }

    /// Anthropic 心跳帧：真实 `event: ping`（Claude Code 忽略 SSE 注释，只认真事件）。
    private static let anthropicHeartbeatFrame = Data("event: ping\ndata: {\"type\":\"ping\"}\n\n".utf8)

    /// 读取下一个上游 chunk；等待期间由看门狗按 `StreamConfig.watchdogInterval` 检查空闲时间，
    /// 超过 `idleTimeout` 抛 `stream_idle_timeout`。
    private static func nextChunkWithIdleWatchdog(
        handler: IteratorHandler,
        idle: StreamIdleMonitor,
        idleTimeout: TimeInterval
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Optional<Data>.self) { group in
            group.addTask {
                try await handler.next()
            }
            group.addTask {
                var waited: TimeInterval = 0
                while waited < idleTimeout {
                    let step = min(StreamConfig.watchdogInterval, idleTimeout - waited)
                    try await Task.sleep(for: .seconds(step))
                    waited += step
                    if idle.elapsed > idleTimeout {
                        throw StreamError(
                            code: .streamIdleTimeout,
                            message: "上游空闲超过 \(Int(idleTimeout))s 未返回数据",
                            statusCode: 502
                        )
                    }
                }
                throw StreamError(
                    code: .streamIdleTimeout,
                    message: "上游空闲超过 \(Int(idleTimeout))s 未返回数据",
                    statusCode: 502
                )
            }
            do {
                guard let result = try await group.next() else { return nil }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// 响应头已发出后的上游错误体：流式客户端收到 `data: {"error":...}`，
    /// 非流式客户端收到 OpenAI 兼容的 JSON error；两者都带错误码。
    private static func errorPayload(isStreaming: Bool, error: Error, code: StreamErrorCode) -> Data? {
        var errorInfo: [String: Any] = [
            "message": "upstream: \(error.localizedDescription)",
            "type": code.rawValue,
            "code": code.rawValue,
        ]
        if case ProviderError.upstreamError(let statusCode, _) = error {
            errorInfo["status"] = statusCode
        }
        let root: [String: Any] = ["error": errorInfo]
        guard let json = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        if isStreaming {
            return Data("data: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
        }
        return json
    }

    /// Responses 流式错误帧：`event: response.failed` + Response 状态 failed，
    /// 错误信息放 `response.error`，保持 Responses 协议的事件终止语义。
    private static func responsesErrorPayload(error: Error, code: StreamErrorCode) -> Data? {
        var errorInfo: [String: Any] = [
            "message": "upstream: \(error.localizedDescription)",
            "code": code.rawValue,
            "type": code.rawValue,
        ]
        if case ProviderError.upstreamError(let statusCode, _) = error {
            errorInfo["status"] = statusCode
        }
        let payload: [String: Any] = [
            "type": "response.failed",
            "response": [
                "id": "resp_error",
                "object": "response",
                "created_at": Int(Date().timeIntervalSince1970),
                "status": "failed",
                "error": errorInfo,
            ],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return Data("event: response.failed\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
    }

    /// Anthropic 流式错误帧：`event: error` + Anthropic error 结构。
    private static func anthropicErrorPayload(error: Error, code: StreamErrorCode) -> Data? {
        var errorInfo: [String: Any] = [
            "type": "api_error",
            "message": "upstream: \(error.localizedDescription)",
            "code": code.rawValue,
        ]
        if case ProviderError.upstreamError(let statusCode, _) = error {
            errorInfo["status"] = statusCode
        }
        let payload: [String: Any] = [
            "type": "error",
            "error": errorInfo,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return Data("event: error\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
    }

    /// OpenAI 官方 error 对象结构（非流式 Responses / Chat 错误体）。
    private static func openAIErrorJSON(
        message: String,
        code: String,
        type: String = "invalid_request_error",
        status: Int? = nil
    ) -> Data? {
        var error: [String: Any] = [
            "message": message,
            "type": type,
            "code": code,
            "param": NSNull(),
        ]
        if let status { error["status"] = status }
        return try? JSONSerialization.data(withJSONObject: ["error": error])
    }

    /// Anthropic 官方 error 对象结构（非流式 /v1/messages 错误体）。
    private static func anthropicErrorJSON(message: String, code: String) -> Data? {
        let payload: [String: Any] = [
            "type": "error",
            "error": [
                "type": "api_error",
                "message": message,
                "code": code,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// OPTIONS 预检（J）：本地网关对浏览器客户端补 CORS 头。
    private static func optionsResponse() -> HTTPResponse {
        HTTPResponse(
            status: 204,
            headers: Self.corsHeaders,
            body: .data(Data())
        )
    }

    private static var corsHeaders: [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "authorization, content-type, x-api-key, anthropic-version, anthropic-beta",
            "Access-Control-Expose-Headers": "content-type",
            "Access-Control-Max-Age": "86400",
        ]
    }

    private static func withCORS(_ response: HTTPResponse) -> HTTPResponse {
        HTTPResponse(status: response.status, headers: response.headers.merging(corsHeaders) { _, new in new }, body: response.body)
    }

    /// 把握手期错误映射为客户端可见的 HTTP 状态码 + 错误码：
    /// 上游 4xx/5xx 保留原状态码（401/403/429 供客户端重试），其余统一 502。
    private static func errorMapping(for error: Error) -> ErrorMapping {
        if let streamError = error as? StreamError {
            return ErrorMapping(statusCode: streamError.statusCode, code: streamError.code, message: streamError.message)
        }
        if let providerError = error as? ProviderError {
            if case .upstreamError(let statusCode, let message) = providerError {
                let status = (400 ..< 600).contains(statusCode) ? statusCode : 502
                return ErrorMapping(statusCode: status, code: .upstreamError, message: message)
            }
            return ErrorMapping(statusCode: 502, code: .upstreamError, message: providerError.localizedDescription)
        }
        return ErrorMapping(statusCode: 502, code: .upstreamError, message: error.localizedDescription)
    }

    private static func streamErrorCode(for error: Error) -> StreamErrorCode {
        if let streamError = error as? StreamError {
            return streamError.code
        }
        if error is CancellationError {
            return .clientDisconnected
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return .streamIdleTimeout
        }
        return .upstreamError
    }

    private struct ErrorMapping: Sendable {
        let statusCode: Int
        let code: StreamErrorCode
        let message: String
    }

    private struct FirstChunkResult: Sendable {
        let chunk: Data?
        let remaining: AsyncThrowingStream<Data, Error>
    }

    private struct FirstChunkBox: Sendable {
        let chunk: Data
        let remaining: AsyncThrowingStream<Data, Error>
        let earlyEOFRetries: Int
    }

    /// 记录最后一次上游事件时间（锁保护；仅被响应流任务与其看门狗访问）。
    private final class StreamIdleMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()

        func touch() {
            lock.lock()
            defer { lock.unlock() }
            lastActivity = Date()
        }

        var elapsed: TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(lastActivity)
        }
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
