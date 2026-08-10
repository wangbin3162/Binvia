import Foundation

public enum OpenCodeProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "opencode",
            alias: "oc",
            displayName: "OpenCode",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://opencode.ai/zen/v1"),
        // 静态目录与线上 `GET https://opencode.ai/zen/v1/models` 对齐（Phase 20 实测 20 个模型，
        // 2026-08-02 快照），动态 `/v1/models` 失败时兜底。id 即 name，与动态拉取结果一致。
        models: [
            Model(id: "claude-fable-5", name: "claude-fable-5"),
            Model(id: "claude-opus-4-6", name: "claude-opus-4-6"),
            Model(id: "claude-opus-4-7", name: "claude-opus-4-7"),
            Model(id: "claude-opus-4-8", name: "claude-opus-4-8"),
            Model(id: "deepseek-v4-flash", name: "deepseek-v4-flash", supportsReasoning: true),
            Model(id: "deepseek-v4-flash-free", name: "deepseek-v4-flash-free", supportsReasoning: true),
            Model(id: "deepseek-v4-pro", name: "deepseek-v4-pro", supportsReasoning: true),
            Model(id: "glm-5.2", name: "glm-5.2", supportsReasoning: true),
            Model(id: "gpt-5.3-codex", name: "gpt-5.3-codex"),
            Model(id: "gpt-5.6-luna", name: "gpt-5.6-luna"),
            Model(id: "gpt-5.6-sol", name: "gpt-5.6-sol"),
            Model(id: "gpt-5.6-terra", name: "gpt-5.6-terra"),
            Model(id: "grok-4.5", name: "grok-4.5", supportsReasoning: true),
            Model(id: "grok-build-0.1", name: "grok-build-0.1"),
            Model(id: "kimi-k2.7-code", name: "kimi-k2.7-code", supportsReasoning: true),
            Model(id: "kimi-k3", name: "kimi-k3"),
            Model(id: "laguna-s-2.1-free", name: "laguna-s-2.1-free"),
            Model(id: "ling-3.0-flash-free", name: "ling-3.0-flash-free"),
            Model(id: "mimo-v2.5-free", name: "mimo-v2.5-free"),
            Model(id: "minimax-m3", name: "minimax-m3", contextLength: 1_048_576, supportsVision: true),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://opencode.ai/zen/v1/models"),
        forceStream: false,
        // opencode 用量：Cookie web 链路（_server RPC，见 OpenCodeUsageFetcher）；
        // 无 Cookie 时展示网页看板入口：登录后在 opencode.ai/zh/zen 查看用量/余额。
        usageFetcherFactory: { OpenCodeUsageFetcher() },
        usageDashboardURL: URL(string: "https://opencode.ai/zh/zen"),
        makeProvider: { OpenCodeProvider() }
    )
}

/// opencode 供应商（API key 型）。标准 OpenAI 兼容 chat，与 OpenAIProvider 行为一致。
///
/// 单 key（无轮换）；不强制流式；客户端 `stream` 标志原样转发；非 2xx 错误 body 透传。
/// `listModels` 走协议默认实现，支持 `OPENCODE_BASE_URL` 覆盖。
public struct OpenCodeProvider: Provider {
    public let id = "opencode"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["OPENCODE_BASE_URL"]) ?? "https://opencode.ai/zen/v1"
        }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["OPENCODE_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("OPENCODE_API_KEY or config providers.opencode.credential.apiKey")
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
