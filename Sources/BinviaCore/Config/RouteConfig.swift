import Foundation

/// 单个网关 API Key 的配置（Phase 12）。
/// - `enabledModels == nil`：全部模型可见（默认，与旧版行为一致）。
/// - `enabledModels == [String]`：白名单，仅列出的 `"<alias>/<modelID>"` 模型可被该 key 调用，
///   其余返回 403。
public struct GatewayKeyConfig: Codable, Sendable, Equatable {
    public var key: String
    public var enabledModels: [String]?

    public init(key: String, enabledModels: [String]? = nil) {
        self.key = key
        self.enabledModels = enabledModels
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case enabledModels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        self.enabledModels = try container.decodeIfPresent([String].self, forKey: .enabledModels)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(enabledModels, forKey: .enabledModels)
    }
}

public struct ProviderConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var credential: ProviderCredential
    /// 多 api-key 列表（key 轮换）。空数组表示未配置。
    public var apiKeys: [String]

    public init(enabled: Bool = true, credential: ProviderCredential = ProviderCredential(), apiKeys: [String] = []) {
        self.enabled = enabled
        self.credential = credential
        self.apiKeys = apiKeys
    }

    // 兼容旧配置：`apiKeys` 是新增字段，缺失时回退为空数组。
    private enum CodingKeys: String, CodingKey {
        case enabled
        case credential
        case apiKeys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.credential = try container.decodeIfPresent(ProviderCredential.self, forKey: .credential) ?? ProviderCredential()
        self.apiKeys = try container.decodeIfPresent([String].self, forKey: .apiKeys) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(credential, forKey: .credential)
        try container.encode(apiKeys, forKey: .apiKeys)
    }
}

public struct RouteConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var host: String
    public var port: Int
    /// 网关 API Key 列表（v2：对象数组，兼容旧版 `[String]`，加载时自动转换）。
    public var apiKeys: [GatewayKeyConfig]
    public var providers: [String: ProviderConfig]

    public init(
        version: Int = 2,
        host: String = "127.0.0.1",
        port: Int = 8231,
        apiKeys: [GatewayKeyConfig] = [],
        providers: [String: ProviderConfig] = [:]
    ) {
        self.version = version
        self.host = host
        self.port = port
        self.apiKeys = apiKeys
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case host
        case port
        case apiKeys
        case providers
    }

    /// v1 → v2 兼容解码：`apiKeys` 既可能是 `[String]`（v1），也可能是 `[{key, enabledModels}]`（v2）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8231
        self.providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
        if let legacyKeys = try? container.decodeIfPresent([String].self, forKey: .apiKeys) {
            self.apiKeys = legacyKeys.map { GatewayKeyConfig(key: $0) }
        } else {
            self.apiKeys = try container.decodeIfPresent([GatewayKeyConfig].self, forKey: .apiKeys) ?? []
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encode(providers, forKey: .providers)
    }

    /// 全部网关 Key 字符串（鉴权用）。
    public var gatewayKeyStrings: [String] {
        apiKeys.map(\.key)
    }

    /// 查询某个网关 Key 的配置（不存在返回 nil）。
    public func gatewayKeyConfig(for key: String) -> GatewayKeyConfig? {
        apiKeys.first { $0.key == key }
    }

    /// 某 provider 的模型白名单（v2 语义下的 gateway key 级过滤在 RouteHandler 中实现）。
    /// 返回全部已启用 provider 的凭据。

    /// 解析某 provider 的凭据：优先 config，回退到环境变量。
    public func credential(for providerID: String) -> ProviderCredential {
        if let pc = providers[providerID], pc.enabled {
            return pc.credential
        }
        return ProviderCredential(apiKey: Self.envValue(["\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"]))
    }

    /// 某 provider 的全部 api-key（用于轮换）：config 的 `apiKeys` 数组 + 环境变量 key
    /// （如 `DEEPSEEK_API_KEY`）。去重、过滤空值。
    public func apiKeys(for providerID: String) -> [String] {
        var keys: [String] = []
        if let pc = providers[providerID] {
            keys.append(contentsOf: pc.apiKeys)
        }
        let envName = "\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        if let env = Self.envValue([envName]), !env.isEmpty {
            keys.append(env)
        }
        var seen = Set<String>()
        return keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func envValue(_ names: [String]) -> String? {
        for name in names {
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
                return v
            }
        }
        return nil
    }
}
