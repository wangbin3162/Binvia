import Foundation

public enum OpenCodeGoProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "opencode-go",
            alias: "ocgo",
            displayName: "OpenCode Go",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://opencode.ai/zen/go/v1"),
        models: [
            Model(id: "glm-5.2", name: "GLM-5.2", supportsReasoning: true),
            Model(id: "kimi-k2.7-code", name: "Kimi-K2.7-Code"),
            Model(id: "qwen3.7-max", name: "Qwen3.7-Max"),
            Model(id: "mimo-v2.5-pro", name: "MiMo-V2.5-Pro", supportsReasoning: true),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://opencode.ai/zen/go/v1/models"),
        forceStream: false,
        usageFetcherFactory: { OpenCodeGoUsageFetcher() },
        makeProvider: { OpenCodeGoProvider() }
    )
}

/// OpenCode Go 供应商（API key 型）。标准 OpenAI 兼容 chat，与 OpenAIProvider 行为一致。
///
/// 单 key（无轮换）；不强制流式；客户端 `stream` 标志原样转发；非 2xx 错误 body 透传。
/// `listModels` 走协议默认实现，支持 `OPENCODE_GO_BASE_URL` 覆盖。
public struct OpenCodeGoProvider: Provider {
    public let id = "opencode-go"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["OPENCODE_GO_BASE_URL"]) ?? "https://opencode.ai/zen/go/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["OPENCODE_GO_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("OPENCODE_GO_API_KEY or config providers.opencode-go.credential.apiKey")
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
