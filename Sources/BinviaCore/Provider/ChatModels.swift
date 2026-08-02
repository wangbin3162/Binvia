import Foundation

public enum ChatRole: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
}

public struct ChatMessage: Sendable, Codable, Equatable {
    public var role: ChatRole
    public var content: String?
    public var name: String?
    public var toolCallID: String?

    public init(role: ChatRole, content: String?, name: String? = nil, toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallID = "tool_call_id"
    }
}

/// OpenAI 兼容的聊天请求体（子集）。
/// `rawBody` 保存客户端原始 JSON（RouteHandler 设置），供应商可用它做透传以保留未知字段。
public struct ChatRequest: Sendable, Codable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool?
    public var temperature: Double?
    public var maxTokens: Int?
    public var topP: Double?

    /// 客户端原始 JSON body（不参与编解码），供 Provider 透传使用。
    public var rawBody: Data?

    public init(
        model: String,
        messages: [ChatMessage],
        stream: Bool? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        topP: Double? = nil,
        rawBody: Data? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.rawBody = rawBody
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
    }

    // MARK: Codable（rawBody 不参与编解码）

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        rawBody = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(stream, forKey: .stream)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try container.encodeIfPresent(topP, forKey: .topP)
    }
}

/// Provider 凭据。不同 authType 的供应商使用不同字段。
///
/// OAuth 型（Antigravity）额外携带 `email`（当前登录账号）与 `expiresAt`（access token 过期时间，
/// 供启动/定时刷新判断）；区域型供应商（z.ai）用 `region` 选择 API 区域。均为可选字段，
/// 自动合成 Codable 对 Optional 用 `decodeIfPresent`，旧配置向后兼容。
public struct ProviderCredential: Sendable, Codable, Equatable {
    public var apiKey: String?
    public var accessToken: String?
    public var refreshToken: String?
    /// OAuth 登录账号邮箱（Antigravity userinfo）。
    public var email: String?
    /// access token 过期时间（OAuth 刷新用）。
    public var expiresAt: Date?
    /// API 区域（如 z.ai 的 `global` / `bigmodel-cn`）。
    public var region: String?

    public init(
        apiKey: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        email: String? = nil,
        expiresAt: Date? = nil,
        region: String? = nil
    ) {
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.email = email
        self.expiresAt = expiresAt
        self.region = region
    }
}

/// 供应商连接测试结果。
public struct ConnectionTestResult: Sendable, Equatable {
    public let success: Bool
    public let message: String
    public let latencyMS: Double?

    public init(success: Bool, message: String, latencyMS: Double? = nil) {
        self.success = success
        self.message = message
        self.latencyMS = latencyMS
    }
}

public enum ProviderError: Error, Sendable {
    case missingCredentials(String)
    case invalidResponse(String)
    case notImplemented(String)
    case upstreamError(statusCode: Int, message: String)
}

extension ProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let hint):
            return "Missing credentials: \(hint)"
        case .invalidResponse(let reason):
            return "Invalid response: \(reason)"
        case .notImplemented(let feature):
            return "Not implemented yet: \(feature)"
        case .upstreamError(let statusCode, let message):
            return "Upstream error \(statusCode): \(message)"
        }
    }
}
