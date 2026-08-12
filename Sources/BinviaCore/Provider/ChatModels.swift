import Foundation

public enum ChatRole: String, Sendable, Codable {
    case system
    case user
    case assistant
    case tool
    /// OpenAI 新版 system 角色（o1/gpt-5 等推理模型、AI SDK 常用），与 `system` 语义等价。
    case developer
    /// 旧版 OpenAI 函数调用角色（legacy）。
    case function

    /// 宽容解码：未知 role 一律归入 `.user`，不因客户端扩展角色而 400
    /// （参考 OmniRoute：`content`/`role` 不做强校验，按原样透传）。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChatRole(rawValue: raw) ?? .user
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 消息内容块（OpenAI content part 的宽松子集）。
/// 只取类型与常见字段，未知字段由 Codable 忽略；仅供需要内容块结构的翻译器使用。
public struct ChatContentPart: Sendable, Codable, Equatable {
    public var type: String?
    public var text: String?
    public var imageURL: String?
    /// 图片 detail（`auto` / `low` / `high`）。
    public var detail: String?
    /// file part 字段（Responses `input_file` / Chat file part）。
    public var fileData: String?
    public var fileID: String?
    public var fileURL: String?
    public var filename: String?

    public init(
        type: String? = nil,
        text: String? = nil,
        imageURL: String? = nil,
        detail: String? = nil,
        fileData: String? = nil,
        fileID: String? = nil,
        fileURL: String? = nil,
        filename: String? = nil
    ) {
        self.type = type
        self.text = text
        self.imageURL = imageURL
        self.detail = detail
        self.fileData = fileData
        self.fileID = fileID
        self.fileURL = fileURL
        self.filename = filename
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
        case detail
        case fileData = "file_data"
        case fileID = "file_id"
        case fileURL = "file_url"
        case filename
    }

    /// 宽容解码：`image_url` 既可能是字符串（`"url"`）也可能是对象（`{"url": "...", "detail": ...}`，
    /// 真实多模态请求的形态），两种都接受，避免 content 数组整体解码失败。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        if let url = try? c.decodeIfPresent(String.self, forKey: .imageURL) {
            imageURL = url
        } else if let obj = try? c.decodeIfPresent([String: String].self, forKey: .imageURL) {
            imageURL = obj["url"]
        } else {
            imageURL = nil
        }
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        fileData = try c.decodeIfPresent(String.self, forKey: .fileData)
        fileID = try c.decodeIfPresent(String.self, forKey: .fileID)
        fileURL = try c.decodeIfPresent(String.self, forKey: .fileURL)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(fileData, forKey: .fileData)
        try c.encodeIfPresent(fileID, forKey: .fileID)
        try c.encodeIfPresent(fileURL, forKey: .fileURL)
        try c.encodeIfPresent(filename, forKey: .filename)
    }
}

/// 消息内容：既可以是纯文本字符串，也可以是内容块数组（多模态 / file part / 工具结果）。
///
/// 参考 OmniRoute 的宽松处理：网关对 `content` 不做类型强校验，字符串与数组都接受，
/// 未知结构（如对象）也不影响整个请求的解析。需要纯文本的翻译器用 `textValue` 提取。
public enum ChatContent: Sendable, Equatable {
    case text(String)
    case parts([ChatContentPart])

    /// 纯文本表示：`text` 原样返回；`parts` 拼接全部 `text` 块。
    /// 供 Anthropic / Gemini 等需要纯文本内容的翻译器使用（图片等非文本块被丢弃）。
    public var textValue: String {
        switch self {
        case .text(let value):
            return value
        case .parts(let parts):
            return parts.compactMap(\.text).joined()
        }
    }
}

extension ChatContent: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let parts = try? container.decode([ChatContentPart].self) {
            self = .parts(parts)
        } else {
            // 兜底：既非字符串也非内容块数组（如对象等未知结构），置空文本，避免整个请求 400。
            // 原始内容仍由 rawBody 透传，不受影响。
            self = .text("")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

extension ChatContent: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .text(value)
    }
}

/// OpenAI `tool_calls[].function` 的函数调用（`name` + 参数 JSON 字符串）。
public struct ToolCallFunction: Sendable, Codable, Equatable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

/// OpenAI `tool_calls[]` 条目（assistant 消息携带）。
public struct ToolCall: Sendable, Codable, Equatable {
    public var id: String?
    public var type: String?
    public var function: ToolCallFunction?

    public init(id: String? = nil, type: String? = nil, function: ToolCallFunction? = nil) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ChatMessage: Sendable, Codable, Equatable {
    public var role: ChatRole
    public var content: ChatContent?
    public var name: String?
    public var toolCallID: String?
    /// OpenAI `tool_calls`（assistant 消息声明函数调用）。Codable 合成，缺失时为 nil。
    public var toolCalls: [ToolCall]?
    /// 推理内容（DeepSeek 等 OpenAI 兼容上游的 `reasoning_content`）。
    /// Anthropic thinking / redacted_thinking 翻译成该字段，保证不丢占位。
    public var reasoningContent: String?

    /// `content` 接受字符串字面量（经 `ChatContent: ExpressibleByStringLiteral` 自动包装为 `.text`）。
    public init(
        role: ChatRole,
        content: ChatContent? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ToolCall]? = nil,
        reasoningContent: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.reasoningContent = reasoningContent
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
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
/// OAuth 型供应商额外携带 `email`（当前登录账号）与 `expiresAt`（access token 过期时间，
/// 供启动/定时刷新判断）；区域型供应商（z.ai）用 `region` 选择 API 区域。均为可选字段，
/// 自动合成 Codable 对 Optional 用 `decodeIfPresent`，旧配置向后兼容。
public struct ProviderCredential: Sendable, Codable, Equatable {
    public var apiKey: String?
    public var accessToken: String?
    public var refreshToken: String?
    /// OAuth 登录账号邮箱（userinfo）。
    public var email: String?
    /// access token 过期时间（OAuth 刷新用）。
    public var expiresAt: Date?
    /// API 区域（如 z.ai 的 `global` / `bigmodel-cn`）。
    public var region: String?
    /// 附加账号标识：CodeBuddy CN 企业 ID（积分查询 `x-enterprise-id`）。
    /// 缺省 nil，旧配置向后兼容。
    public var workspaceId: String?
    /// 浏览器会话 Cookie 头（OpenCode / OpenCode Go 用量查询用）。
    /// 从浏览器开发者工具复制 `Cookie` 请求头粘贴（仅保留 `auth` / `__Host-auth` 两项），
    /// 或直接粘贴 `auth` cookie 的值（自动包装，见 `OpenCodeCookieConfig.filteredHeader`）。
    /// 缺省 nil，旧配置向后兼容。
    public var cookieHeader: String?

    public init(
        apiKey: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        email: String? = nil,
        expiresAt: Date? = nil,
        region: String? = nil,
        workspaceId: String? = nil,
        cookieHeader: String? = nil
    ) {
        self.apiKey = apiKey
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.email = email
        self.expiresAt = expiresAt
        self.region = region
        self.workspaceId = workspaceId
        self.cookieHeader = cookieHeader
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
