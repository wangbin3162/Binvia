import Foundation

public enum MiniMaxProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "minimax",
            alias: "mm",
            displayName: "MiniMax",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.minimax.io/anthropic/v1/messages"),
        models: [
            Model(id: "MiniMax-M3", name: "MiniMax-M3", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "MiniMax-M2.7", name: "MiniMax-M2.7"),
            Model(id: "MiniMax-M2.5", name: "MiniMax-M2.5"),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://api.minimax.io/v1/models"),
        makeProvider: { MiniMaxProvider() }
    )
}

/// MiniMax 供应商（API key 型，Anthropic 兼容 `/v1/messages`）。
///
/// 上游端点 `https://api.minimax.io/anthropic/v1/messages?beta=true`，认证 `x-api-key` +
/// `anthropic-version: 2023-06-01`（参考 OmniRoute `registry/minimax`）。
/// 格式转换 / 强制流式 / 非流式聚合逻辑与 zai 完全一致（`AnthropicCompatChatExecutor`）。
/// `listModels` 走协议默认实现（modelsURL → 动态获取，失败回退静态目录）。
public struct MiniMaxProvider: Provider {
    public let id = "minimax"

    private let executor = AnthropicCompatChatExecutor(
        providerID: "minimax",
        defaultBaseURL: "https://api.minimax.io/anthropic/v1/messages",
        baseURLEnvKeys: ["MINIMAX_BASE_URL"],
        keyEnvNames: ["MINIMAX_API_KEY"]
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
