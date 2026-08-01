import Foundation

public enum ProviderAuthType: String, Sendable, Codable {
    case apiKey
    case oauth
    case deviceFlow
    case localProbe
}

public struct ProviderMetadata: Sendable, Codable, Equatable {
    public let id: String
    public let alias: String?
    public let displayName: String
    public let authType: ProviderAuthType

    public init(id: String, alias: String? = nil, displayName: String, authType: ProviderAuthType) {
        self.id = id
        self.alias = alias
        self.displayName = displayName
        self.authType = authType
    }
}

/// 供应商描述符。借鉴 CodexBar `ProviderDescriptor`，携带注册信息与工厂闭包。
///
/// 二期扩展字段（Phase 12）：
/// - `modelsURL`：动态模型列表端点（null = 仅静态目录）；`Provider.listModels` 默认实现
///   「`ModelCache` 优先 → 上游 `modelsURL` → 静态兜底」。
/// - `forceStream`：上游是否强制 `stream=true`（如 CodeBuddyCN / Kimi），非流式客户端
///   由 provider 内部用 `SSEJSONAggregator` 聚合。
/// - `usageFetcherFactory`：用量查询器工厂（null 表示该供应商无用量卡片）。
public struct ProviderDescriptor: Sendable {
    public let metadata: ProviderMetadata
    public let baseURL: URL?
    public let models: [Model]
    public let supportsStreaming: Bool
    public let makeProvider: @Sendable () -> any Provider

    // 二期新增
    public let modelsURL: URL?
    public let forceStream: Bool
    public let usageFetcherFactory: @Sendable () -> (any ProviderUsageFetcher)?

    public init(
        metadata: ProviderMetadata,
        baseURL: URL?,
        models: [Model],
        supportsStreaming: Bool = true,
        modelsURL: URL? = nil,
        forceStream: Bool = false,
        usageFetcherFactory: @escaping @Sendable () -> (any ProviderUsageFetcher)? = { nil },
        makeProvider: @escaping @Sendable () -> any Provider
    ) {
        self.metadata = metadata
        self.baseURL = baseURL
        self.models = models
        self.supportsStreaming = supportsStreaming
        self.modelsURL = modelsURL
        self.forceStream = forceStream
        self.usageFetcherFactory = usageFetcherFactory
        self.makeProvider = makeProvider
    }

    public var id: String { metadata.id }
    public var alias: String? { metadata.alias }
    public var displayName: String { metadata.displayName }
}
