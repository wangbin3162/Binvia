import Foundation

public enum AntigravityProviderDescriptor {
    /// 静态模型目录（参考 OmniRoute `ANTIGRAVITY_PUBLIC_MODELS` 的子集；
    /// OAuth 后 `fetchAvailableModels` 可动态覆盖，best-effort）。
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "antigravity",
            alias: "agy",
            displayName: "Antigravity",
            authType: .oauth
        ),
        baseURL: URL(string: "https://cloudcode-pa.googleapis.com"),
        models: [
            Model(id: "gemini-3.6-flash-high", name: "Gemini 3.6 Flash (High)", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "gemini-3.6-flash-medium", name: "Gemini 3.6 Flash (Medium)", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "gemini-3.6-flash-low", name: "Gemini 3.6 Flash (Low)", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "gemini-pro-agent", name: "Gemini 3.1 Pro (High)", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6 (Thinking)", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "claude-opus-4-6-thinking", name: "Claude Opus 4.6 (Thinking)", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", contextLength: 1_048_576, supportsReasoning: true),
            Model(id: "gpt-oss-120b-medium", name: "GPT-OSS 120B (Medium)", contextLength: 131_072, supportsReasoning: true),
        ],
        supportsStreaming: true,
        usageFetcherFactory: { AntigravityUsageFetcher() },
        makeProvider: { AntigravityProvider() }
    )
}

/// Google Antigravity 供应商（OAuth + cloudcode 信封）。Phase 3 实现。
///
/// 依据：
/// - OmniRoute `registry/antigravity` + `executors/antigravity.ts`：
///   始终流式 `POST {base}/v1internal:streamGenerateContent?alt=sse`（cloudcode 信封），
///   401 时用 refreshToken 刷新后重试一次；`userAgent: "antigravity"`。
/// - cloudcode SSE → OpenAI SSE 翻译见 `AntigravityEnvelopeTranslator`；
///   客户端 `stream=false` 时用 `SSEJSONAggregator.aggregateChatCompletion` 聚合为 JSON。
/// - OAuth PKCE + projectId 引导见 `AntigravityOAuthClient`。
public struct AntigravityProvider: Provider {
    public let id = "antigravity"

    private let session: URLSession
    private let oauth: AntigravityOAuthClient

    public init(session: URLSession = .shared) {
        self.session = session
        self.oauth = AntigravityOAuthClient(config: .live())
    }

    // MARK: - 凭据

    private func resolveAccessToken(_ credential: ProviderCredential?) throws -> String {
        if let token = credential?.accessToken, !token.isEmpty {
            return token
        }
        if let token = RouteConfig.envValue(["ANTIGRAVITY_ACCESS_TOKEN"]), !token.isEmpty {
            return token
        }
        throw ProviderError.missingCredentials(
            "Antigravity 需要 OAuth 登录：运行 login() 或配置 providers.antigravity.credential.accessToken / 环境变量 ANTIGRAVITY_ACCESS_TOKEN"
        )
    }

    // MARK: - listModels

    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        // Phase 13：统一走 ModelCache（300s TTL），避免每次 /v1/models 都打上游
        if let cached = await ModelCache.shared.get(id) {
            return cached
        }
        let config = AntigravityConfig.live()
        guard let token = try? resolveAccessToken(credential) else {
            return AntigravityProviderDescriptor.descriptor.models
        }
        do {
            let models = try await fetchAvailableModels(
                accessToken: token,
                refreshToken: credential?.refreshToken,
                config: config
            )
            let result = models.isEmpty ? AntigravityProviderDescriptor.descriptor.models : models
            if !result.isEmpty {
                await ModelCache.shared.set(id, models: result)
            }
            return result
        } catch {
            // best-effort：动态获取失败回退静态目录，并写缓存（300s TTL）避免每次 /v1/models
            // 都重复打上游等待超时（上游不可达时实测每次卡 12s）。上游恢复后 TTL 过期自动重试。
            let fallback = AntigravityProviderDescriptor.descriptor.models
            await ModelCache.shared.set(id, models: fallback)
            return fallback
        }
    }

    // MARK: - chat

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let config = AntigravityConfig.live()
        let token = try resolveAccessToken(credential)
        let projectID = try await resolveProjectID(
            accessToken: token,
            refreshToken: credential?.refreshToken,
            config: config
        )
        let envelope = AntigravityEnvelopeTranslator.makeEnvelope(
            request: request,
            project: projectID,
            rawBody: rawBody
        )
        let body = try JSONEncoder().encode(envelope)

        var upstream = URLRequest(url: config.streamGenerateContentURL)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upstream.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        upstream.httpBody = body

        let model = AntigravityEnvelopeTranslator.resolveModelID(request.model)
        let translated = makeTranslatedStream(
            request: upstream,
            accessToken: token,
            refreshToken: credential?.refreshToken,
            model: model
        )

        guard request.stream == true else {
            // 非流式客户端：用共享聚合器把 OpenAI 格式 SSE 聚合成单个 JSON。
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let json = try await SSEJSONAggregator.aggregateChatCompletion(translated)
                        continuation.yield(json)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        return translated
    }

    // MARK: - testConnection

    public func testConnection(credential: ProviderCredential?) async throws -> ConnectionTestResult {
        let config = AntigravityConfig.live()
        guard let token = try? resolveAccessToken(credential) else {
            return ConnectionTestResult(
                success: false,
                message: "Antigravity 未登录。请运行 OAuth login（得到 accessToken/refreshToken/projectId），或设置 ANTIGRAVITY_ACCESS_TOKEN + ANTIGRAVITY_PROJECT_ID。"
            )
        }
        let start = Date()
        do {
            let models = try await fetchAvailableModels(
                accessToken: token,
                refreshToken: credential?.refreshToken,
                config: config
            )
            let latency = Date().timeIntervalSince(start) * 1000
            return ConnectionTestResult(success: true, message: "Connected to antigravity (\(models.count) models)", latencyMS: latency)
        } catch {
            let latency = Date().timeIntervalSince(start) * 1000
            return ConnectionTestResult(success: false, message: error.localizedDescription, latencyMS: latency)
        }
    }

    // MARK: - 内部

    static let userAgent = "antigravity/ide/2.1.1 darwin/arm64"

    /// 解析 projectId：环境变量 → 记忆缓存 → loadCodeAssist 发现（401 时先 refresh 重试）。
    private func resolveProjectID(
        accessToken: String,
        refreshToken: String?,
        config: AntigravityConfig
    ) async throws -> String {
        if let project = RouteConfig.envValue(["ANTIGRAVITY_PROJECT_ID"]), !project.isEmpty {
            return project
        }
        if let cached = AntigravityProjectCache.shared.value(for: accessToken), !cached.isEmpty {
            return cached
        }

        var token = accessToken
        var info: AntigravityProjectInfo?
        do {
            info = try await oauth.onboardProject(accessToken: token)
        } catch {
            if let rt = refreshToken, !rt.isEmpty,
               let refreshed = try? await oauth.refreshAccessToken(refreshToken: rt) {
                token = refreshed.accessToken
                info = try? await oauth.onboardProject(accessToken: token)
            }
        }
        if let projectID = info?.projectId, !projectID.isEmpty {
            AntigravityProjectCache.shared.set(projectID, for: accessToken)
            return projectID
        }
        throw ProviderError.missingCredentials(
            "Antigravity projectId 未找到（loadCodeAssist 未返回 Cloud Code project）。请重新执行 OAuth 登录，并确保 Google 账号已完成 Gemini Code Assist 开通。"
        )
    }

    /// `:fetchAvailableModels` 动态模型列表。
    ///
    /// 依序尝试 discovery base URL（daily 优先，参考 OmniRoute `getAntigravityFetchAvailableModelsUrls`）：
    /// - 2xx → 返回模型；
    /// - 401：有 refreshToken 则刷新后重试一次；仍失败或 403 直接抛错（认证问题，无谓尝试其它 URL）；
    /// - 其余状态（400/404/429/5xx）：记录错误并尝试下一个 base URL。
    private func fetchAvailableModels(
        accessToken: String,
        refreshToken: String?,
        config: AntigravityConfig
    ) async throws -> [Model] {
        var lastError: Error?
        for url in config.fetchAvailableModelsURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            // 注意：`:fetchAvailableModels` 接受空 body（`{}`），不需要 metadata / projectId——
            // `metadata: {ideType:"ANTIGRAVITY"}` 是 `loadCodeAssist` 的字段，误加到此处会被
            // 上游 protobuf JSON 解析拒绝并返回 400（参考 OmniRoute `fetcher.ts` 发 `{}`）。
            request.httpBody = Data("{}".utf8)

            let (data, response) = try await ProviderHTTPClient.shared.data(for: request)

            if (200 ..< 300).contains(response.statusCode) {
                return AntigravityEnvelopeTranslator.parseModels(from: data)
            }

            if response.statusCode == 401, let rt = refreshToken, !rt.isEmpty {
                let refreshed = try await oauth.refreshAccessToken(refreshToken: rt)
                request.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
                let (retryData, retryResponse) = try await ProviderHTTPClient.shared.data(for: request)
                if (200 ..< 300).contains(retryResponse.statusCode) {
                    return AntigravityEnvelopeTranslator.parseModels(from: retryData)
                }
                throw ProviderError.upstreamError(
                    statusCode: retryResponse.statusCode,
                    message: Self.describeHTTPError(retryResponse.statusCode, String(data: retryData, encoding: .utf8) ?? "")
                )
            }

            if response.statusCode == 401 || response.statusCode == 403 {
                // 无 refresh token 或刷新失败：认证失败，直接抛，不继续尝试其它 URL
                throw ProviderError.upstreamError(
                    statusCode: response.statusCode,
                    message: Self.describeHTTPError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
                )
            }

            // 其它状态：记录错误，尝试下一个 discovery base URL
            lastError = ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: Self.describeHTTPError(response.statusCode, String(data: data, encoding: .utf8) ?? "")
            )
        }
        throw lastError ?? ProviderError.upstreamError(
            statusCode: 0,
            message: "Antigravity API unavailable"
        )
    }

    /// 始终流式请求上游，把 cloudcode SSE 翻译为 OpenAI SSE 逐事件 yield。
    /// - 401：refreshToken 刷新后重试一次；
    /// - 其他非 2xx：抛 `ProviderError.upstreamError`。
    private func makeTranslatedStream(
        request: URLRequest,
        accessToken: String,
        refreshToken: String?,
        model: String
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request
                    let (bytes, response) = try await session.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                    if status == 401, let rt = refreshToken, !rt.isEmpty {
                        let refreshed = try await oauth.refreshAccessToken(refreshToken: rt)
                        req.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
                        let (retryBytes, retryResponse) = try await session.bytes(for: req)
                        let retryStatus = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                        if (200 ..< 300).contains(retryStatus) {
                            try await translateUpstream(bytes: retryBytes, model: model, continuation: continuation)
                        } else {
                            let errorBody = try await Self.collectBody(bytes: retryBytes)
                            throw ProviderError.upstreamError(statusCode: retryStatus, message: Self.describeHTTPError(retryStatus, errorBody))
                        }
                    } else if (200 ..< 300).contains(status) {
                        try await translateUpstream(bytes: bytes, model: model, continuation: continuation)
                    } else {
                        let errorBody = try await Self.collectBody(bytes: bytes)
                        throw ProviderError.upstreamError(statusCode: status, message: Self.describeHTTPError(status, errorBody))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 解析上游 SSE → 逐事件翻译为 OpenAI chunk → yield（结束时 yield `[DONE]`）。
    /// 对 `\r\n` 做归一化（SSEParser 只按 `\n\n` 切分事件）。
    private func translateUpstream(
        bytes: URLSession.AsyncBytes,
        model: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let id = "chatcmpl-\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var parser = SSEParser()
        var hasEmittedContent = false
        var toolCallIndex = 0
        var line = Data()

        for try await byte in bytes {
            if byte == 0x0A {
                line.append(0x0A)
                for event in parser.append(line) {
                    yieldTranslated(
                        event: event, model: model, id: id, created: created,
                        hasEmittedContent: &hasEmittedContent,
                        toolCallIndex: &toolCallIndex,
                        continuation: continuation
                    )
                }
                line.removeAll()
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        if !line.isEmpty {
            line.append(0x0A)
            for event in parser.append(line) {
                yieldTranslated(
                    event: event, model: model, id: id, created: created,
                    hasEmittedContent: &hasEmittedContent,
                    toolCallIndex: &toolCallIndex,
                    continuation: continuation
                )
            }
        }
        for event in parser.finish() {
            yieldTranslated(
                event: event, model: model, id: id, created: created,
                hasEmittedContent: &hasEmittedContent,
                toolCallIndex: &toolCallIndex,
                continuation: continuation
            )
        }
        continuation.yield(AntigravityEnvelopeTranslator.doneEvent)
    }

    private func yieldTranslated(
        event: String,
        model: String,
        id: String,
        created: Int,
        hasEmittedContent: inout Bool,
        toolCallIndex: inout Int,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
        guard let value = SSEEvent.dataValue(from: event) else { return }
        if SSEEvent.isDone(value) { return }
        guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return }
        let chunk = AntigravityEnvelopeTranslator.openAIChunk(
            fromGeminiPayload: json,
            model: model,
            id: id,
            created: created,
            emitRole: !hasEmittedContent,
            toolCallIndex: toolCallIndex
        )
        guard let chunk else { return }
        continuation.yield(AntigravityEnvelopeTranslator.encodeSSEChunk(chunk))
        if let choices = chunk["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                hasEmittedContent = true
            }
            // 累计已发出的 tool_call 数量，保证流式多工具调用的 index 全局递增不重复
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                toolCallIndex += calls.count
            }
        }
    }

    private static func collectBody(bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 把上游错误响应转成可读消息：优先提取 Google 风格 `{"error":{"message":...}}`，
    /// 否则透传原始 body。便于 GUI/CLI 直接展示 400 等错误的根因。
    private static func describeHTTPError(_ status: Int, _ raw: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return "HTTP \(status)\(raw.isEmpty ? "" : ": \(raw)")"
    }
}

/// 线程安全的 projectId 记忆缓存（按 accessToken）。
private final class AntigravityProjectCache: @unchecked Sendable {
    static let shared = AntigravityProjectCache()
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}
