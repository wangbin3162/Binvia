import Foundation

public enum OpenAIProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "openai",
            alias: "openai",
            displayName: "OpenAI",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.openai.com/v1"),
        models: [
            Model(id: "gpt-5.6", name: "GPT-5.6", contextLength: 1_048_576, supportsReasoning: true),
            Model(id: "gpt-5.5", name: "GPT-5.5", contextLength: 1_048_576, supportsReasoning: true),
            Model(id: "gpt-5.4", name: "GPT-5.4", contextLength: 1_048_576, supportsReasoning: true),
            Model(id: "gpt-4.1", name: "GPT-4.1", contextLength: 1_048_576, supportsReasoning: false),
            Model(id: "gpt-4o", name: "GPT-4o", contextLength: 128_000, supportsReasoning: false),
            Model(id: "o3", name: "o3", contextLength: 200_000, supportsReasoning: true),
            Model(id: "o4-mini", name: "o4-mini", contextLength: 200_000, supportsReasoning: true),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://api.openai.com/v1/models"),
        forceStream: false,
        makeProvider: { OpenAIProvider() }
    )
}

/// OpenAI 供应商（API key 型）。标准 OpenAI 兼容 chat。
///
/// 与 DeepSeek 的差异：单 key（无轮换）；不强制流式（OpenAI 原生支持非流式），
/// 客户端 `stream` 标志原样转发。使用 `stream(for:)` 使上游非 2xx 错误 body 透传（反向代理语义）。
/// `listModels` 走协议默认实现（ModelCache → modelsURL → 静态兜底），支持 `OPENAI_BASE_URL` 覆盖。
public struct OpenAIProvider: Provider {
    public let id = "openai"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["OPENAI_BASE_URL"]) ?? "https://api.openai.com/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["OPENAI_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("OPENAI_API_KEY or config providers.openai.credential.apiKey")
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
