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
public struct ProviderDescriptor: Sendable {
    public let metadata: ProviderMetadata
    public let baseURL: URL?
    public let models: [Model]
    public let supportsStreaming: Bool
    public let makeProvider: @Sendable () -> any Provider

    public init(
        metadata: ProviderMetadata,
        baseURL: URL?,
        models: [Model],
        supportsStreaming: Bool = true,
        makeProvider: @escaping @Sendable () -> any Provider
    ) {
        self.metadata = metadata
        self.baseURL = baseURL
        self.models = models
        self.supportsStreaming = supportsStreaming
        self.makeProvider = makeProvider
    }

    public var id: String { metadata.id }
    public var alias: String? { metadata.alias }
    public var displayName: String { metadata.displayName }
}
