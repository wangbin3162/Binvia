import Foundation

/// z.ai API 区域（参考 CodexBar `ZaiAPIRegion`）。
///
/// 默认 `.bigmodelCN`（中国区）——Phase 20 需求：默认 BigModel CN，可切 Global。
/// `ProviderCredential.region` 存原始值（`global` / `bigmodel-cn`），nil 视为默认区域。
public enum ZaiAPIRegion: String, CaseIterable, Sendable {
    case global
    case bigmodelCN = "bigmodel-cn"

    public var displayName: String {
        switch self {
        case .global: return "Global (api.z.ai)"
        case .bigmodelCN: return "BigModel CN (open.bigmodel.cn)"
        }
    }

    /// 区域 host（不含 `/api/anthropic/v1/messages` 路径）。
    public var baseHost: String {
        switch self {
        case .global: return "https://api.z.ai"
        case .bigmodelCN: return "https://open.bigmodel.cn"
        }
    }
}

public enum ZaiProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "zai",
            alias: "zai",
            displayName: "z.ai",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://open.bigmodel.cn/api/anthropic/v1/messages"),
        models: [
            Model(id: "glm-5.2", name: "GLM-5.2", supportsReasoning: true),
            Model(id: "glm-5.1", name: "GLM-5.1"),
            Model(id: "glm-5", name: "GLM-5"),
            Model(id: "glm-4.7-flash", name: "GLM-4.7-Flash"),
            Model(id: "glm-4.5-air", name: "GLM-4.5-Air"),
        ],
        supportsStreaming: true,
        // 首个区域为默认（BigModel CN）；设置面板按此顺序渲染 Picker。
        regions: [
            ProviderAPIRegion(id: ZaiAPIRegion.bigmodelCN.rawValue, displayName: ZaiAPIRegion.bigmodelCN.displayName),
            ProviderAPIRegion(id: ZaiAPIRegion.global.rawValue, displayName: ZaiAPIRegion.global.displayName),
        ],
        makeProvider: { ZaiProvider() }
    )
}

/// Z.ai / BigModel（GLM）供应商（API key 型，Anthropic 兼容 `/v1/messages`）。
///
/// 上游端点 `{region}/api/anthropic/v1/messages?beta=true`，认证 `x-api-key` +
/// `anthropic-version: 2023-06-01`（参考 OmniRoute `registry/zai`）。
/// 区域解析：`ZAI_BASE_URL` 环境变量 → `ProviderCredential.region` → 默认 BigModel CN。
/// 请求/响应格式转换走 `AnthropicEnvelopeTranslator`（OpenAI ↔ Anthropic Messages API）；
/// 上游恒 `stream: true`，非流式客户端用 `SSEJSONAggregator` 聚合（对齐 CodeBuddyCN 模式）。
/// `listModels` 走协议默认实现（无 modelsURL → 静态目录）。
public struct ZaiProvider: Provider {
    public let id = "zai"

    public init() {}

    /// 按区域解析 messages 端点基础 URL。
    private func resolveBaseURL(_ credential: ProviderCredential?) -> String {
        if let env = RouteConfig.envValue(["ZAI_BASE_URL"]), !env.isEmpty {
            return env
        }
        let region = credential?.region.flatMap(ZaiAPIRegion.init(rawValue:)) ?? .bigmodelCN
        return "\(region.baseHost)/api/anthropic/v1/messages"
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let executor = AnthropicCompatChatExecutor(
            providerID: "zai",
            defaultBaseURL: resolveBaseURL(credential),
            baseURLEnvKeys: ["ZAI_BASE_URL"],
            keyEnvNames: ["ZAI_API_KEY"]
        )
        return try await executor.chat(request: request, rawBody: rawBody, credential: credential)
    }
}
