import Foundation

public enum CursorProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "cursor",
            alias: "cu",
            displayName: "Cursor",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.cursor.com/v1"),
        models: [
            Model(id: "claude-opus-4-6", name: "Claude Opus 4.6", contextLength: 200_000, supportsReasoning: true),
            Model(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", contextLength: 200_000, supportsReasoning: true),
            Model(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", contextLength: 200_000, supportsReasoning: true),
            Model(id: "gpt-5.1", name: "GPT-5.1", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-5", name: "GPT-5", contextLength: 400_000, supportsReasoning: true),
            Model(id: "gpt-4.1", name: "GPT-4.1", contextLength: 1_048_576, supportsReasoning: false),
            Model(id: "gemini-3-pro", name: "Gemini 3 Pro", contextLength: 1_000_000, supportsReasoning: true),
            Model(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", contextLength: 1_000_000, supportsReasoning: true),
            Model(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", contextLength: 1_000_000, supportsReasoning: false),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://api.cursor.com/v1/models"),
        forceStream: false,
        makeProvider: { CursorProvider() }
    )
}

/// Cursor 供应商（API key 型）。按 OpenAI 兼容 chat 实现。
///
/// 参考 OmniRoute `oauth/constants/oauth.ts` 的 CURSOR_CONFIG（api2.cursor.sh 为 gRPC 私有协议，
/// 官方公开 REST 为 api.cursor.com）。本实现按 OpenAI 兼容端点接入，默认 baseURL 指向
/// `https://api.cursor.com/v1`；若 Cursor 官方 API 形态与本实现不一致，可用 `CURSOR_BASE_URL`
/// 指向任意 OpenAI 兼容的 Cursor 中转端点。模型目录为 Cursor 常见可路由模型。
///
/// 与 OpenAIProvider 行为一致：单 key（无轮换）；不强制流式；客户端 `stream` 标志原样转发；
/// 非 2xx 错误 body 透传。key 来源：credential.apiKey 或 `CURSOR_API_KEY`。
/// `listModels` 走协议默认实现，支持 `CURSOR_BASE_URL` 覆盖。
public struct CursorProvider: Provider {
    public let id = "cursor"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["CURSOR_BASE_URL"]) ?? "https://api.cursor.com/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["CURSOR_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("CURSOR_API_KEY or config providers.cursor.credential.apiKey")
    }

    /// 构建上游请求体：优先透传 rawBody（保留未知字段与客户端 stream 标志），否则编码 ChatRequest。
    private func makeBody(request: ChatRequest, rawBody: Data?) throws -> Data {
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            json["model"] = request.model
            return try JSONSerialization.data(withJSONObject: json)
        }
        return try JSONEncoder().encode(request)
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let key = try resolveKey(credential)
        let body = try makeBody(request: request, rawBody: rawBody)

        var upstream = URLRequest(url: Endpoint.chat)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        upstream.httpBody = body

        // 透传流：客户端 stream=true/false 原样转发；上游非 2xx 错误 body 直接透传。
        return ProviderHTTPClient.shared.stream(for: upstream)
    }
}
