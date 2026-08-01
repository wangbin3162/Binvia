import Foundation

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
    public var apiKeys: [String]
    public var providers: [String: ProviderConfig]

    public init(
        version: Int = 1,
        host: String = "127.0.0.1",
        port: Int = 8231,
        apiKeys: [String] = [],
        providers: [String: ProviderConfig] = [:]
    ) {
        self.version = version
        self.host = host
        self.port = port
        self.apiKeys = apiKeys
        self.providers = providers
    }

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
