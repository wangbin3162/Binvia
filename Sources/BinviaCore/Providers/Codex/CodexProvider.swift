import Foundation

public enum CodexProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "codex",
            alias: "cx",
            displayName: "Codex (OpenAI)",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.openai.com/v1"),
        models: [
            Model(id: "gpt-5.1-codex", name: "GPT-5.1-Codex", supportsReasoning: true),
            Model(id: "gpt-5.1-codex-mini", name: "GPT-5.1-Codex-Mini", supportsReasoning: true),
            Model(id: "gpt-5.1-codex-max", name: "GPT-5.1-Codex-Max", supportsReasoning: true),
            Model(id: "gpt-5-codex", name: "GPT-5-Codex", supportsReasoning: true),
            Model(id: "gpt-5-codex-mini", name: "GPT-5-Codex-Mini", supportsReasoning: true),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://api.openai.com/v1/models"),
        forceStream: false,
        makeProvider: { CodexProvider() }
    )
}

/// Codex（OpenAI）供应商（API key 型）。OpenAI Codex 走标准 OpenAI 兼容 chat。
///
/// 与 OpenAIProvider 行为一致：单 key（无轮换）；不强制流式；客户端 `stream` 标志原样转发；
/// 非 2xx 错误 body 透传。模型目录参考 OmniRoute `oauth-subscriptions.ts` 的 codex 定价表。
/// key 来源：credential.apiKey 或 `CODEX_API_KEY`。
/// `listModels` 走协议默认实现，支持 `CODEX_BASE_URL` 覆盖（默认 api.openai.com/v1）。
public struct CodexProvider: Provider {
    public let id = "codex"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["CODEX_BASE_URL"]) ?? "https://api.openai.com/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["CODEX_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("CODEX_API_KEY or config providers.codex.credential.apiKey")
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
