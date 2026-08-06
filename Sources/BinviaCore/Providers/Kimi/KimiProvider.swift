import Foundation

public enum KimiProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "kimi",
            alias: "kimi",
            displayName: "Kimi",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.moonshot.cn/v1"),
        models: [
            Model(id: "kimi-k3", name: "Kimi K3", contextLength: 1_048_576, supportsReasoning: true),
            Model(id: "kimi-k2.7-code", name: "Kimi K2.7 Code", contextLength: 256_000, supportsReasoning: true),
            Model(id: "kimi-k2.6", name: "Kimi K2.6", contextLength: 256_000, supportsReasoning: true),
            Model(id: "kimi-k2.5", name: "Kimi K2.5", contextLength: 164_000, supportsReasoning: true),
        ],
        supportsStreaming: true,
        modelsURL: nil,
        forceStream: true,
        usageFetcherFactory: { KimiUsageFetcher() },
        makeProvider: { KimiProvider() }
    )
}

/// Kimi (Moonshot) 供应商（API key 型）。Phase 15 实现。
///
/// 默认国内站点 `api.moonshot.cn`（可用 `KIMI_BASE_URL` / `MOONSHOT_BASE_URL` 覆盖）。
/// 关键点：Moonshot 的 Kimi 路由**强制流式**（非流式请求会被拒），与 CodeBuddyCN 同型：
/// - 无论客户端 `stream` 标志，上游请求体恒带 `stream: true`；
/// - 客户端 `stream=false` 时，用 `SSEJSONAggregator` 把上游 SSE 聚合成单个 OpenAI JSON 返回；
/// - 客户端 `stream=true` 时，SSE 逐事件透传。
/// 单 key（无轮换）：credential.apiKey 或 `KIMI_API_KEY`（兼容 `MOONSHOT_API_KEY`）。
/// `listModels` 走协议默认实现（无 modelsURL → 直接返回静态目录）。
public struct KimiProvider: Provider {
    public let id = "kimi"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["KIMI_BASE_URL", "MOONSHOT_BASE_URL"]) ?? "https://api.moonshot.cn/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["KIMI_API_KEY", "MOONSHOT_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("KIMI_API_KEY or config providers.kimi.credential.apiKey")
    }

    /// 构建上游请求体：强制 `stream=true`（保留 rawBody 未知字段 / 其他字段名）。
    /// 角色归一化：Moonshot 上游不认 `developer` 角色（OpenAI 新版约定），收到会返回 400
    /// `Invalid request: role 'developer' is not allowed`（实测 pi 报错），与 DeepSeek/Generic/CodeBuddy
    /// 同型处理，转发前统一改写为 `system`（语义等价）。
    private func makeBody(request: ChatRequest, rawBody: Data?) throws -> Data {
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            json = RoleNormalizer.normalizeDeveloperRole(json, providerID: id)
            json["stream"] = true
            json["model"] = request.model
            return try JSONSerialization.data(withJSONObject: json)
        }
        var upstreamBody = request
        upstreamBody.messages = upstreamBody.messages.map { message in
            message.role == .developer
                ? ChatMessage(role: .system, content: message.content, name: message.name, toolCallID: message.toolCallID)
                : message
        }
        upstreamBody.stream = true
        return try JSONEncoder().encode(upstreamBody)
    }

    private static func makeUpstreamRequest(chat: URL, key: String, body: Data) -> URLRequest {
        var upstream = URLRequest(url: chat)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        upstream.httpBody = body
        return upstream
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let key = try resolveKey(credential)
        let body = try makeBody(request: request, rawBody: rawBody)

        // 客户端流式：SSE 透传（非 2xx 抛错，遵循 CodeBuddyCN 的 streamThrowing 语义）。
        if request.stream == true {
            return ProviderHTTPClient.shared.streamThrowing(for: Self.makeUpstreamRequest(chat: Endpoint.chat, key: key, body: body))
        }

        // 客户端非流式：强制流式上游 → SSEJSONAggregator 聚合成单个 JSON。
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let upstream = ProviderHTTPClient.shared.streamThrowing(for: Self.makeUpstreamRequest(chat: Endpoint.chat, key: key, body: body))
                    let json = try await SSEJSONAggregator.aggregateChatCompletion(upstream)
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
