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

/// 带标签的令牌（API Key / Access Token）。`label` 为展示名（用户自定义，
/// 仿 CodexBar 令牌账户），`value` 为实际密钥。
/// 旧配置 `apiKeys: [String]` 解码时自动生成掩码标签。
public struct KeyedToken: Codable, Sendable, Equatable {
    public var label: String
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public init(value: String) {
        self.value = value
        self.label = Self.defaultLabel(for: value)
    }

    /// 默认标签：密钥掩码（前 6 位 + •••• + 后 4 位），与用量展示的掩码一致。
    public static func defaultLabel(for value: String) -> String {
        guard value.count > 10 else { return String(value.prefix(3)) + "••••" }
        return "\(String(value.prefix(6)))••••\(String(value.suffix(4)))"
    }
}

public struct ProviderConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var credential: ProviderCredential
    /// 多令牌列表（label + value，key 轮换 / 多 token）。空数组表示未配置。
    /// 兼容旧格式 `[String]`：解码时自动转成 `KeyedToken`（标签为掩码）。
    public var apiKeys: [KeyedToken]
    /// API 区域（如 z.ai 的 `global` / `bigmodel-cn`）。nil = 供应商默认区域。
    public var region: String?
    /// 禁用模型列表（设置面板模型行的启用/禁用开关）：禁用模型视为不存在——
    /// `/v1/models` 不展示、网关白名单不可选、请求返回 404。原始模型名（不含 provider 前缀）。
    public var disabledModels: [String]

    public init(enabled: Bool = false, credential: ProviderCredential = ProviderCredential(), apiKeys: [KeyedToken] = [], region: String? = nil, disabledModels: [String] = []) {
        self.enabled = enabled
        self.credential = credential
        self.apiKeys = apiKeys
        self.region = region
        self.disabledModels = disabledModels
    }

    /// 全部令牌值（provider / 路由层用，忽略标签）。
    public var apiKeyValues: [String] {
        apiKeys.map(\.value)
    }

    /// 某模型是否被禁用（设置面板「禁用」开关）。
    public func isModelDisabled(_ modelID: String) -> Bool {
        disabledModels.contains(modelID)
    }

    // 兼容旧配置：`apiKeys`/`region` 是新增字段，缺失时回退默认值。
    private enum CodingKeys: String, CodingKey {
        case enabled
        case credential
        case apiKeys
        case region
        case disabledModels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.credential = try container.decodeIfPresent(ProviderCredential.self, forKey: .credential) ?? ProviderCredential()
        // 兼容旧格式 `[String]` 与新版 `[{label,value}]`（旧 key 自动生成掩码标签）
        if let legacy = try? container.decodeIfPresent([String].self, forKey: .apiKeys) {
            self.apiKeys = legacy.map { KeyedToken(value: $0) }
        } else {
            self.apiKeys = try container.decodeIfPresent([KeyedToken].self, forKey: .apiKeys) ?? []
        }
        self.region = try container.decodeIfPresent(String.self, forKey: .region)
        self.disabledModels = try container.decodeIfPresent([String].self, forKey: .disabledModels) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(credential, forKey: .credential)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(disabledModels.isEmpty ? nil : disabledModels, forKey: .disabledModels)
    }
}

/// 用户自定义的「OpenAI 兼容 Provider」定义。
///
/// 与内置 provider 不同：id/displayName/baseURL/模型列表均由用户在 GUI 填写。
/// - `id`：ASCII slug，由 `displayName` 生成（`CustomProviderDef.uniqueSlug`），如 `unisound`。
/// - `models`：**不带前缀**的模型 id（如 `glm-5.2`）；路由与展示时由 provider 自动拼接 `<id>/<model>`。
///
/// 凭据与启用状态**不**存在这里，而是复用 `RouteConfig.providers[id]`（`ProviderConfig`），
/// 这样 `credential(for:)`、`apiKeys(for:)` 与设置面板的凭据 UI 全部沿用既有路径。
public struct CustomProviderDef: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var baseURL: String
    public var models: [String]

    public init(id: String, displayName: String, baseURL: String, models: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.models = models
    }

    /// `baseURL` 是 acronym 字段：Swift 的 convertFromSnakeCase 会把 `base_url`
    /// 转成 `baseUrl`，不能依赖默认 CodingKeys 的 `baseURL` 匹配。
    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case baseURL = "baseUrl"
        case legacyBaseURL = "baseURL"
        case models
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        if let value = try container.decodeIfPresent(String.self, forKey: .baseURL) {
            baseURL = value
        } else {
            baseURL = try container.decode(String.self, forKey: .legacyBaseURL)
        }
        models = try container.decodeIfPresent([String].self, forKey: .models) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(models, forKey: .models)
    }

    /// 由 displayName 生成 ASCII slug：小写 → 非 `[a-z0-9]` 替换为 `-` → 折叠连续 `-` → 去首尾 `-`。
    /// 全部为非 ASCII 字符时回退为 `custom`。
    public static func slug(for displayName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var result = ""
        for ch in displayName.lowercased() {
            if allowed.contains(ch) {
                result.append(ch)
            } else {
                result.append("-")
            }
        }
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "custom" : result
    }

    /// 在 `existingIds` 中生成不冲突的唯一 slug：`base` → `base-2` → `base-3` …
    public static func uniqueSlug(for displayName: String, excluding existingIds: Set<String>) -> String {
        let base = slug(for: displayName)
        if !existingIds.contains(base) { return base }
        var i = 2
        while existingIds.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }
}

public struct RouteConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var host: String
    public var port: Int
    /// 网关 API Key 列表（v2：对象数组，兼容旧版 `[String]`，加载时自动转换）。
    public var apiKeys: [GatewayKeyConfig]
    public var providers: [String: ProviderConfig]
    /// 供应商侧栏排序（拖拽自定义）。未列出或为空的 provider 追加在末尾（按 id 字母序）。
    public var providerOrder: [String]
    /// 用户自定义的 OpenAI 兼容 Provider 定义列表（运行时注册到 ProviderRegistry）。
    public var customProviderDefs: [CustomProviderDef]

    public init(
        version: Int = 2,
        host: String = "localhost",
        port: Int = 20427,
        apiKeys: [GatewayKeyConfig] = [],
        providers: [String: ProviderConfig] = [:],
        providerOrder: [String] = [],
        customProviderDefs: [CustomProviderDef] = []
    ) {
        self.version = version
        self.host = host
        self.port = port
        self.apiKeys = apiKeys
        self.providers = providers
        self.providerOrder = providerOrder
        self.customProviderDefs = customProviderDefs
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case host
        case port
        case apiKeys
        case providers
        case providerOrder
        case customProviderDefs
    }

    /// v1 → v2 兼容解码：`apiKeys` 既可能是 `[String]`（v1），也可能是 `[{key, enabledModels}]`（v2）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? "localhost"
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 20427
        self.providers = try container.decodeIfPresent([String: ProviderConfig].self, forKey: .providers) ?? [:]
        if let legacyKeys = try? container.decodeIfPresent([String].self, forKey: .apiKeys) {
            self.apiKeys = legacyKeys.map { GatewayKeyConfig(key: $0) }
        } else {
            self.apiKeys = try container.decodeIfPresent([GatewayKeyConfig].self, forKey: .apiKeys) ?? []
        }
        self.providerOrder = try container.decodeIfPresent([String].self, forKey: .providerOrder) ?? []
        self.customProviderDefs = try container.decodeIfPresent([CustomProviderDef].self, forKey: .customProviderDefs) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(apiKeys, forKey: .apiKeys)
        try container.encode(providers, forKey: .providers)
        try container.encodeIfPresent(providerOrder.isEmpty ? nil : providerOrder, forKey: .providerOrder)
        try container.encodeIfPresent(customProviderDefs.isEmpty ? nil : customProviderDefs, forKey: .customProviderDefs)
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
    ///
    /// 聚合语义（Phase 20）：
    /// - `credential.apiKey` 为空但 `apiKeys[]` 非空时，用首个 key 填充（GUI 保存把单 key 存进
    ///   `apiKeys[]`，OpenCode 等只读 `credential.apiKey` 的供应商由此获得凭据）；
    /// - 灌入 `ProviderConfig.region`（z.ai 区域选择透传给 provider）；
    /// - **不依赖 `enabled`**：enabled 只控制路由与模型可见性，设置面板的模型测试等场景
    ///   即使供应商处于禁用态也应能取到已保存的凭据（修复 opencode 禁用后测试报 Missing credentials）。
    public func credential(for providerID: String) -> ProviderCredential {
        if let pc = providers[providerID] {
            var cred = pc.credential
            if (cred.apiKey ?? "").isEmpty,
               let first = pc.apiKeys.first(where: { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                cred.apiKey = first.value
            }
            cred.region = pc.region
            // 配置条目存在且带凭据 → 直接返回；完全空的条目回退环境变量（保持旧行为）。
            let hasCredential = !(cred.apiKey ?? "").isEmpty
                || !(cred.accessToken ?? "").isEmpty
                || !(cred.refreshToken ?? "").isEmpty
            if hasCredential {
                return cred
            }
        }
        return ProviderCredential(apiKey: Self.envValue(["\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"]))
    }

    /// 某 provider 是否已配置凭据（apiKey / accessToken / refreshToken / apiKeys[] 任一非空）。
    /// 用于 `/v1/models` 跳过无凭据 provider 的动态模型获取——避免无谓打上游拖慢列表响应
    /// （AI 客户端每次启动都会拉模型列表）。CodeBuddy 模型调用 token 存 `apiKeys[]`，也已覆盖。
    public func hasCredential(for providerID: String) -> Bool {
        let cred = credential(for: providerID)
        if !(cred.apiKey ?? "").isEmpty
            || !(cred.accessToken ?? "").isEmpty
            || !(cred.refreshToken ?? "").isEmpty {
            return true
        }
        return !apiKeys(for: providerID).isEmpty
    }

    /// 某 provider 的全部 api-key（用于轮换）：config 的 `apiKeys` 数组 + 环境变量 key
    /// （如 `DEEPSEEK_API_KEY`）。去重、过滤空值。
    public func apiKeys(for providerID: String) -> [String] {
        keyedTokens(for: providerID).map(\.value)
    }

    /// 某 provider 的全部带标签令牌（用于用量展示）：config 的 `apiKeys`（优先用户标签）+
    /// 环境变量 key（无标签 → 掩码标签）。按值去重、过滤空值。
    /// DeepSeek 用量卡按此展示令牌标签（无自定义标签时回退掩码）。
    public func keyedTokens(for providerID: String) -> [KeyedToken] {
        var tokens: [KeyedToken] = []
        if let pc = providers[providerID] {
            tokens.append(contentsOf: pc.apiKeys)
        }
        let envName = "\(providerID.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        if let env = Self.envValue([envName]), !env.isEmpty {
            tokens.append(KeyedToken(value: env))
        }
        var seen = Set<String>()
        return tokens
            .map { token in
                let value = token.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = token.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return KeyedToken(
                    label: label.isEmpty ? KeyedToken.defaultLabel(for: value) : label,
                    value: value
                )
            }
            .filter { !$0.value.isEmpty && seen.insert($0.value).inserted }
    }

    public static func envValue(_ names: [String]) -> String? {
        for name in names {
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
                return v
            }
        }
        return nil
    }

    /// 查询某个自定义 provider 的定义。不存在返回 nil。
    public func customProviderDef(for id: String) -> CustomProviderDef? {
        customProviderDefs.first { $0.id == id }
    }
}
