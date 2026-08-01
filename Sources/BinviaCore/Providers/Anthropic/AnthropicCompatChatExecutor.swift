import Foundation

/// Anthropic 兼容上游的共享 chat 执行器（zai / minimax 共用）。
///
/// 流程（对齐「强制流式上游」模式，参考 CodeBuddyCNProvider）：
/// 1. OpenAI `ChatRequest` → `AnthropicEnvelopeTranslator` 翻译为 Anthropic body，
///    上游恒带 `stream: true`（Anthropic 兼容端点按流式处理最稳，同时支持非流式聚合）；
/// 2. 客户端 `stream=true`：上游 Anthropic SSE → 翻译为 OpenAI SSE 逐事件透传；
/// 3. 客户端 `stream=false`：先翻译为 OpenAI SSE，再用 `SSEJSONAggregator`
///    聚合成单个 OpenAI `chat.completion` JSON。
///
/// 认证：`x-api-key` + `anthropic-version`（参考 OmniRoute `getAnthropicCompatHeaders`）。
public struct AnthropicCompatChatExecutor: Sendable {
    /// provider id（错误消息用）。
    public let providerID: String
    /// 上游 messages 端点默认值（如 `https://api.z.ai/api/anthropic/v1/messages`）。
    public let defaultBaseURL: String
    /// 覆盖基础 URL 的环境变量名（如 `ZAI_BASE_URL`，测试 mock 用）。
    public let baseURLEnvKeys: [String]
    /// API key 环境变量名（如 `ZAI_API_KEY`）。
    public let keyEnvNames: [String]

    public init(
        providerID: String,
        defaultBaseURL: String,
        baseURLEnvKeys: [String],
        keyEnvNames: [String]
    ) {
        self.providerID = providerID
        self.defaultBaseURL = defaultBaseURL
        self.baseURLEnvKeys = baseURLEnvKeys
        self.keyEnvNames = keyEnvNames
    }

    /// 上游端点：基础 URL + `?beta=true`（参考 OmniRoute `urlSuffix: "?beta=true"`）。
    public func endpointURL() -> URL {
        let base = RouteConfig.envValue(baseURLEnvKeys) ?? defaultBaseURL
        return URL(string: "\(base)?beta=true")!
    }

    /// 解析 API key：credential 优先，回退环境变量。
    public func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(keyEnvNames), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials(
            "\(keyEnvNames.joined(separator: " or ")) or config providers.\(providerID).credential.apiKey"
        )
    }

    /// 构建 Anthropic 上游请求体（恒 `stream: true`）。`rawBody` 为 OpenAI 格式，
    /// 与 Anthropic 信封不兼容，故一律从已解码的 `ChatRequest` 翻译。
    public func makeBody(request: ChatRequest) throws -> Data {
        let system = request.messages
            .filter { $0.role == .system }
            .compactMap { $0.content }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let json = AnthropicEnvelopeTranslator.makeAnthropicRequest(
            model: request.model,
            messages: request.messages,
            system: system.isEmpty ? nil : system,
            maxTokens: request.maxTokens,
            stream: true,
            temperature: request.temperature,
            topP: request.topP
        )
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// 上游 URLRequest（POST + `x-api-key` + `anthropic-version`）。
    public func makeRequest(request: ChatRequest, credential: ProviderCredential?) throws -> URLRequest {
        let key = try resolveKey(credential)
        var upstream = URLRequest(url: endpointURL())
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(key, forHTTPHeaderField: "x-api-key")
        upstream.setValue(AnthropicEnvelopeTranslator.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        upstream.httpBody = try makeBody(request: request)
        return upstream
    }

    /// Provider `chat` 主入口。
    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let upstream = try makeRequest(request: request, credential: credential)
        let model = request.model
        let created = Int(Date().timeIntervalSince1970)

        // 统一先把 Anthropic SSE 翻译为 OpenAI SSE；非流式客户端再走聚合。
        let translated = translatedStream(
            raw: ProviderHTTPClient.shared.streamThrowing(for: upstream),
            model: model,
            created: created
        )
        if request.stream == true {
            return translated
        }
        return aggregatedStream(translated: translated)
    }

    // MARK: - 内部

    /// 把 Anthropic SSE 流翻译为 OpenAI SSE 流（末尾附 `[DONE]`）。
    private func translatedStream(
        raw: AsyncThrowingStream<Data, Error>,
        model: String,
        created: Int
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = SSEParser()
                    var upstreamID = "chatcmpl-\(model)"
                    var hasEmittedRole = false
                    var lastStopReason: String?
                    for try await chunk in raw {
                        for event in parser.append(chunk) {
                            guard let value = SSEEvent.dataValue(from: event), !SSEEvent.isDone(value) else { continue }
                            guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { continue }
                            // 捕获上游 message id 作为 OpenAI chunk id
                            if json["type"] as? String == "message_start",
                               let message = json["message"] as? [String: Any],
                               let mid = message["id"] as? String {
                                upstreamID = mid
                            }
                            if let openAI = AnthropicEnvelopeTranslator.translateSSEPayload(
                                json,
                                model: model,
                                id: upstreamID,
                                created: created,
                                hasEmittedRole: &hasEmittedRole,
                                lastStopReason: &lastStopReason
                            ) {
                                continuation.yield(AnthropicEnvelopeTranslator.encodeSSEChunk(openAI))
                            }
                        }
                    }
                    // 冲刷末尾未完整事件（保险起见）
                    for event in parser.finish() {
                        guard let value = SSEEvent.dataValue(from: event), !SSEEvent.isDone(value) else { continue }
                        guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { continue }
                        if let openAI = AnthropicEnvelopeTranslator.translateSSEPayload(
                            json,
                            model: model,
                            id: upstreamID,
                            created: created,
                            hasEmittedRole: &hasEmittedRole,
                            lastStopReason: &lastStopReason
                        ) {
                            continuation.yield(AnthropicEnvelopeTranslator.encodeSSEChunk(openAI))
                        }
                    }
                    continuation.yield(AnthropicEnvelopeTranslator.doneEvent)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 非流式客户端：把翻译后的 OpenAI SSE 聚合为单个 JSON。
    private func aggregatedStream(translated: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let json = try await SSEJSONAggregator.aggregateChatCompletion(translated)
                    continuation.yield(json)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
