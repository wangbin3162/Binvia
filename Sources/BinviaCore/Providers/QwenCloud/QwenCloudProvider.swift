import Foundation

public enum QwenCloudProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "qwen-cloud",
            alias: "qwc",
            displayName: "Qwen Cloud",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        models: [
            Model(id: "qwen3.7-max", name: "Qwen3.7-Max", supportsReasoning: true),
            Model(id: "qwen3.7-plus", name: "Qwen3.7-Plus", supportsReasoning: true),
            Model(id: "qwen3.6-plus", name: "Qwen3.6-Plus", supportsReasoning: true),
            Model(id: "qwen3.5-397b-a17b", name: "Qwen3.5-397B-A17B", supportsReasoning: true),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models"),
        forceStream: false,
        makeProvider: { QwenCloudProvider() }
    )
}

/// Qwen Cloud（DashScope）供应商（API key 型）。标准 OpenAI 兼容 chat，与 OpenAIProvider 行为一致。
///
/// 单 key（无轮换）；不强制流式；客户端 `stream` 标志原样转发；非 2xx 错误 body 透传。
/// key 来源：credential.apiKey 或 `QWEN_CLOUD_API_KEY`（兼容 `DASHSCOPE_API_KEY`）。
/// `listModels` 走协议默认实现，支持 `QWEN_CLOUD_BASE_URL` 覆盖。
public struct QwenCloudProvider: Provider {
    public let id = "qwen-cloud"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["QWEN_CLOUD_BASE_URL"]) ?? "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["QWEN_CLOUD_API_KEY", "DASHSCOPE_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("QWEN_CLOUD_API_KEY or config providers.qwen-cloud.credential.apiKey")
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
