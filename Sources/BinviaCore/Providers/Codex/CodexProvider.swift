import Foundation

public enum CodexProviderDescriptor {
    /// 静态模型目录（参考 OmniRoute `registry/codex/index.ts`：ChatGPT 订阅账号的 Codex 模型）。
    /// 模型 id 可带 effort 后缀（-low/-medium/-high/-xhigh/-max/-ultra），请求翻译时剥离并写入
    /// `reasoning.effort`（见 `CodexResponsesTranslator.splitEffortSuffix`）。
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "codex",
            alias: "cx",
            displayName: "Codex (ChatGPT)",
            authType: .oauth
        ),
        baseURL: URL(string: "https://chatgpt.com"),
        models: [
            // GPT-5.6 Sol
            Model(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-sol-ultra", name: "GPT-5.6 Sol (Ultra)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-sol-max", name: "GPT-5.6 Sol (Max)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-sol-xhigh", name: "GPT-5.6 Sol (xHigh)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-sol-high", name: "GPT-5.6 Sol (High)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-sol-medium", name: "GPT-5.6 Sol (Medium)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-sol-low", name: "GPT-5.6 Sol (Low)", contextLength: 400_000, supportsReasoning: true),
            // GPT-5.6 Terra
            Model(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-terra-ultra", name: "GPT-5.6 Terra (Ultra)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-terra-max", name: "GPT-5.6 Terra (Max)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-terra-xhigh", name: "GPT-5.6 Terra (xHigh)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-terra-high", name: "GPT-5.6 Terra (High)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-terra-medium", name: "GPT-5.6 Terra (Medium)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-terra-low", name: "GPT-5.6 Terra (Low)", contextLength: 400_000, supportsReasoning: true),
            // GPT-5.6 Luna
            Model(id: "gpt-5.6-luna", name: "GPT-5.6 Luna", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-luna-max", name: "GPT-5.6 Luna (Max)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-luna-xhigh", name: "GPT-5.6 Luna (xHigh)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-luna-high", name: "GPT-5.6 Luna (High)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-luna-medium", name: "GPT-5.6 Luna (Medium)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.6-luna-low", name: "GPT-5.6 Luna (Low)", contextLength: 400_000, supportsReasoning: true),
            // GPT-5.5
            Model(id: "gpt-5.5", name: "GPT-5.5", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.5-xhigh", name: "GPT-5.5 (xHigh)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.5-high", name: "GPT-5.5 (High)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.5-medium", name: "GPT-5.5 (Medium)", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5.5-low", name: "GPT-5.5 (Low)", contextLength: 400_000, supportsReasoning: true),
            // GPT-5.3 Codex Spark
            Model(id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark", contextLength: 400_000, supportsReasoning: true),
        ],
        supportsStreaming: true,
        usageFetcherFactory: { CodexUsageFetcher() },
        makeProvider: { CodexProvider() }
    )
}

/// Codex（ChatGPT 订阅账号）供应商（OAuth + Responses API）。Phase 24 实现。
///
/// 依据 OmniRoute：
/// - `registry/codex` + `executors/codex.ts`：`POST {base}/backend-api/codex/responses`
///   （**Responses API 格式**，强制 stream=true）；401 时用 refreshToken 刷新后重试一次；
///   `chatgpt-account-id` 头带 OAuth 绑定的 workspaceId。
/// - `translator/request/openai-responses.ts` + `translator/response/openai-responses.ts`：
///   chat-completions ↔ Responses 双向翻译见 `CodexResponsesTranslator`；
///   客户端 `stream=false` 时用 `SSEJSONAggregator` 聚合为 JSON。
/// - OAuth PKCE + workspace 绑定见 `CodexOAuthClient`。
public struct CodexProvider: Provider {
    public let id = "codex"

    private let session: URLSession
    private let oauth: CodexOAuthClient

    public init(session: URLSession = .shared) {
        self.session = session
        self.oauth = CodexOAuthClient(config: .live())
    }

    // MARK: - 凭据

    private func resolveAccessToken(_ credential: ProviderCredential?) throws -> String {
        if let token = credential?.accessToken, !token.isEmpty {
            return token
        }
        if let token = RouteConfig.envValue(["CODEX_ACCESS_TOKEN"]), !token.isEmpty {
            return token
        }
        throw ProviderError.missingCredentials(
            "Codex 需要 OAuth 登录：运行 BinviaCLI oauth login codex，或配置 providers.codex.credential.accessToken（或环境变量 CODEX_ACCESS_TOKEN）"
        )
    }

    // MARK: - chat

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let config = CodexConfig.live()
        let token = try resolveAccessToken(credential)
        let body = try CodexResponsesTranslator.makeRequestBody(request: request, rawBody: rawBody)

        var upstream = URLRequest(url: config.responsesURL)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        upstream.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upstream.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        upstream.setValue(config.clientVersion, forHTTPHeaderField: "Version")
        upstream.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        upstream.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let workspaceID = credential?.workspaceId, !workspaceID.isEmpty {
            upstream.setValue(workspaceID, forHTTPHeaderField: "chatgpt-account-id")
        }
        upstream.httpBody = body

        let translated = makeTranslatedStream(
            request: upstream,
            accessToken: token,
            refreshToken: credential?.refreshToken,
            model: request.model
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
        guard let token = try? resolveAccessToken(credential) else {
            return ConnectionTestResult(
                success: false,
                message: "Codex 未登录。请运行 OAuth login（得到 accessToken/refreshToken/workspaceId）。"
            )
        }
        let start = Date()
        do {
            let effectiveCredential: ProviderCredential
            if let credential, !(credential.accessToken ?? "").isEmpty {
                effectiveCredential = credential
            } else {
                effectiveCredential = ProviderCredential(accessToken: token)
            }
            let snapshot = try await CodexUsageFetcher().fetchUsage(credential: effectiveCredential)
            let latency = Date().timeIntervalSince(start) * 1000
            let usageText = snapshot.quotaWindows
                .map { "\($0.label) \(Int($0.remainingPercentage))%" }
                .joined(separator: ", ")
            return ConnectionTestResult(
                success: true,
                message: "Connected to codex (usage: \(usageText))",
                latencyMS: latency
            )
        } catch {
            let latency = Date().timeIntervalSince(start) * 1000
            return ConnectionTestResult(success: false, message: error.localizedDescription, latencyMS: latency)
        }
    }

    // MARK: - 内部

    /// 始终流式请求上游（responses SSE），逐事件翻译为 OpenAI chat-completions SSE。
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

    /// 解析上游 Responses SSE → 逐事件翻译为 OpenAI chunk 并 yield；结束时 yield `[DONE]`。
    /// 中途错误（`response.failed`）在流结束时抛 `ProviderError.upstreamError`。
    private func translateUpstream(
        bytes: URLSession.AsyncBytes,
        model: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        var state = CodexResponsesTranslator.CodexResponseState(model: model)
        var parser = SSEParser()
        var line = Data()

        // AsyncBytes 逐字节产出，累积到整行（\n 结尾）再喂给 SSEParser（按 \n\n 切分事件）。
        for try await byte in bytes {
            if byte == 0x0A {
                line.append(0x0A)
                for event in parser.append(line) {
                    try yieldTranslated(event: event, state: &state, continuation: continuation)
                }
                line.removeAll()
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        if !line.isEmpty {
            line.append(0x0A)
            for event in parser.append(line) {
                try yieldTranslated(event: event, state: &state, continuation: continuation)
            }
        }
        for event in parser.finish() {
            try yieldTranslated(event: event, state: &state, continuation: continuation)
        }

        if let error = state.error {
            throw ProviderError.upstreamError(statusCode: 0, message: error)
        }
        if !state.terminal {
            continuation.yield(CodexResponsesTranslator.finalChunk(state: &state))
        }
        continuation.yield(CodexResponsesTranslator.doneEvent)
    }

    private func yieldTranslated(
        event: String,
        state: inout CodexResponsesTranslator.CodexResponseState,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) throws {
        if let chunk = CodexResponsesTranslator.translatedChunk(Data(event.utf8), state: &state) {
            continuation.yield(chunk)
        }
    }

    private static func collectBody(bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 把上游错误响应转成可读消息：优先提取 `{"error":{"message":...}}`，否则透传原始 body。
    private static func describeHTTPError(_ status: Int, _ raw: String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        return "HTTP \(status)\(raw.isEmpty ? "" : ": \(raw)")"
    }
}
