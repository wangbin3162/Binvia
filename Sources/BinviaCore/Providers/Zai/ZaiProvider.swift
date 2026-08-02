import Foundation

public enum ZaiProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "zai",
            alias: "zai",
            displayName: "z.ai",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.z.ai/api/anthropic/v1/messages"),
        models: [
            Model(id: "glm-5.2", name: "GLM-5.2", supportsReasoning: true),
            Model(id: "glm-5.1", name: "GLM-5.1"),
            Model(id: "glm-5", name: "GLM-5"),
            Model(id: "glm-4.7-flash", name: "GLM-4.7-Flash"),
            Model(id: "glm-4.5-air", name: "GLM-4.5-Air"),
        ],
        supportsStreaming: true,
        makeProvider: { ZaiProvider() }
    )
}

/// Z.ai（GLM）供应商（API key 型，Anthropic 兼容 `/v1/messages`）。
///
/// 上游端点 `https://api.z.ai/api/anthropic/v1/messages?beta=true`，认证 `x-api-key` +
/// `anthropic-version: 2023-06-01`（参考 OmniRoute `registry/zai`）。
/// 请求/响应格式转换走 `AnthropicEnvelopeTranslator`（OpenAI ↔ Anthropic Messages API）；
/// 上游恒 `stream: true`，非流式客户端用 `SSEJSONAggregator` 聚合（对齐 CodeBuddyCN 模式）。
/// `listModels` 走协议默认实现（无 modelsURL → 静态目录）。
public struct ZaiProvider: Provider {
    public let id = "zai"

    private let executor = AnthropicCompatChatExecutor(
        providerID: "zai",
        defaultBaseURL: "https://api.z.ai/api/anthropic/v1/messages",
        baseURLEnvKeys: ["ZAI_BASE_URL"],
        keyEnvNames: ["ZAI_API_KEY"]
    )

    public init() {}

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        try await executor.chat(request: request, rawBody: rawBody, credential: credential)
    }
}
