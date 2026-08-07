import Foundation

/// cloudcode 请求信封（参考 OmniRoute `executors/antigravity.ts` `transformRequest()`
/// 构建的 `AntigravityRequestEnvelope`：`project` / `requestId` / `userAgent: "antigravity"`
/// / `requestType` / `model` + Gemini 格式 `request`）。
public struct AntigravityEnvelope: Sendable, Codable, Equatable {
    public var project: String
    public var requestId: String
    public var userAgent: String
    public var requestType: String
    public var model: String?
    public var request: AntigravityGeminiRequest

    public init(
        project: String,
        requestId: String,
        userAgent: String,
        requestType: String,
        model: String?,
        request: AntigravityGeminiRequest
    ) {
        self.project = project
        self.requestId = requestId
        self.userAgent = userAgent
        self.requestType = requestType
        self.model = model
        self.request = request
    }
}

/// Gemini 请求体（信封的 `request` 字段）。
/// 相比 OpenAI 侧多了 `tools` / `toolConfig`（工具调用支持，参考 OmniRoute
/// `sanitizeAntigravityGeminiRequest`）。
public struct AntigravityGeminiRequest: Sendable, Codable, Equatable {
    public var contents: [AntigravityContent]
    public var systemInstruction: AntigravitySystemInstruction?
    public var generationConfig: AntigravityGenerationConfig?
    public var sessionId: String?
    /// Gemini functionDeclarations 工具声明（`{functionDeclarations:[...]}`）。
    public var tools: [AntigravityTool]?
    /// 工具调用模式：`{functionCallingConfig:{mode:"VALIDATED"}}`（OmniRoute 同款）。
    public var toolConfig: AntigravityToolConfig?

    public init(
        contents: [AntigravityContent],
        systemInstruction: AntigravitySystemInstruction? = nil,
        generationConfig: AntigravityGenerationConfig? = nil,
        sessionId: String? = nil,
        tools: [AntigravityTool]? = nil,
        toolConfig: AntigravityToolConfig? = nil
    ) {
        self.contents = contents
        self.systemInstruction = systemInstruction
        self.generationConfig = generationConfig
        self.sessionId = sessionId
        self.tools = tools
        self.toolConfig = toolConfig
    }
}

/// Gemini 工具声明容器。
public struct AntigravityTool: Sendable, Codable, Equatable {
    public var functionDeclarations: [AntigravityFunctionDeclaration]

    public init(functionDeclarations: [AntigravityFunctionDeclaration]) {
        self.functionDeclarations = functionDeclarations
    }
}

/// Gemini function declaration（`name` / `description` / `parameters`）。
/// `parameters` 是 JSON Schema（任意字典），需经 `cleanJSONSchemaForAntigravity` 清洗。
public struct AntigravityFunctionDeclaration: Sendable, Codable, Equatable {
    public var name: String
    public var description: String
    public var parameters: [String: AnyCodable]?

    public init(name: String, description: String, parameters: [String: AnyCodable]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, parameters
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        parameters = try c.decodeIfPresent([String: AnyCodable].self, forKey: .parameters)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        if let parameters {
            try c.encode(parameters, forKey: .parameters)
        }
    }
}

/// Gemini `toolConfig`：`{functionCallingConfig: { mode: "VALIDATED" }}`。
public struct AntigravityToolConfig: Sendable, Codable, Equatable {
    public var functionCallingConfig: AntigravityFunctionCallingConfig

    public init(mode: String = "VALIDATED") {
        self.functionCallingConfig = AntigravityFunctionCallingConfig(mode: mode)
    }

    private enum CodingKeys: String, CodingKey {
        case functionCallingConfig = "functionCallingConfig"
    }
}

public struct AntigravityFunctionCallingConfig: Sendable, Codable, Equatable {
    public var mode: String

    public init(mode: String) {
        self.mode = mode
    }
}

/// 宽松 JSON 值（工具参数 schema 里任意嵌套结构）。
public enum AnyCodable: Sendable, Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodable])
    case array([AnyCodable])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let arr = try? container.decode([AnyCodable].self) { self = .array(arr) }
        else if let obj = try? container.decode([String: AnyCodable].self) { self = .object(obj) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

/// 带纯文本工具调用的内容块（`AntigravityPart` 的 JSON 形态，保留原始任意字段）。
/// 实际编码为字典（`text` / `functionCall` / `functionResponse` 等）。
public struct AntigravityPart: Sendable, Codable, Equatable {
    public var text: String?
    public var functionCall: AntigravityFunctionCall?
    public var functionResponse: AntigravityFunctionResponse?

    public init(text: String? = nil, functionCall: AntigravityFunctionCall? = nil, functionResponse: AntigravityFunctionResponse? = nil) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
    }

    private enum CodingKeys: String, CodingKey {
        case text, functionCall, functionResponse
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        functionCall = try c.decodeIfPresent(AntigravityFunctionCall.self, forKey: .functionCall)
        functionResponse = try c.decodeIfPresent(AntigravityFunctionResponse.self, forKey: .functionResponse)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(functionCall, forKey: .functionCall)
        try c.encodeIfPresent(functionResponse, forKey: .functionResponse)
    }
}

/// Gemini `functionCall` part：`{name, args}`。
public struct AntigravityFunctionCall: Sendable, Codable, Equatable {
    public var name: String?
    public var args: [String: AnyCodable]?

    public init(name: String? = nil, args: [String: AnyCodable]? = nil) {
        self.name = name
        self.args = args
    }
}

/// Gemini `functionResponse` part：`{name, response: {name, content}}`。
public struct AntigravityFunctionResponse: Sendable, Codable, Equatable {
    public var name: String?
    public var response: AntigravityFunctionResponseBody?

    public init(name: String? = nil, response: AntigravityFunctionResponseBody? = nil) {
        self.name = name
        self.response = response
    }
}

public struct AntigravityFunctionResponseBody: Sendable, Codable, Equatable {
    public var name: String?
    public var content: String?

    public init(name: String? = nil, content: String? = nil) {
        self.name = name
        self.content = content
    }
}

public struct AntigravityContent: Sendable, Codable, Equatable {
    public var role: String
    public var parts: [AntigravityPart]

    public init(role: String, parts: [AntigravityPart]) {
        self.role = role
        self.parts = parts
    }
}

/// Gemini `systemInstruction` 只含 `parts`（不含 role）。
public struct AntigravitySystemInstruction: Sendable, Codable, Equatable {
    public var parts: [AntigravityPart]

    public init(parts: [AntigravityPart]) {
        self.parts = parts
    }
}

public struct AntigravityGenerationConfig: Sendable, Codable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    public var maxOutputTokens: Int?

    public init(temperature: Double? = nil, topP: Double? = nil, maxOutputTokens: Int? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.maxOutputTokens = maxOutputTokens
    }
}

/// cloudcode 信封翻译器（纯函数/纯结构体，便于单测）。
///
/// - 请求方向：OpenAI `ChatRequest`（messages）→ Gemini `contents` + cloudcode 信封。
/// - 响应方向：cloudcode `streamGenerateContent` SSE（Gemini 候选格式）
///   → OpenAI `chat.completion.chunk` SSE（`choices[0].delta.content`）。
///
/// 响应 payload 格式参考 OmniRoute `sseCollect.ts`：
/// `{ "markdown"?, "response": { "candidates": [ { "content": { "parts": [{ "text" }] },
///   "finishReason" } ], "usageMetadata": { promptTokenCount, candidatesTokenCount, totalTokenCount } },
///   "remainingCredits"? }`。
public enum AntigravityEnvelopeTranslator {
    /// 上游接受的 maxOutputTokens 上限（参考 OmniRoute `MAX_ANTIGRAVITY_OUTPUT_TOKENS`）。
    public static let maxOutputTokensCap = 16_384

    /// 模型名映射（参考 `open-sse/config/antigravityModelAliases.ts`）。
    public static let modelAliases: [String: String] = [
        "gemini-claude-sonnet-4-5": "claude-sonnet-4-6",
        "gemini-claude-sonnet-4-5-thinking": "claude-sonnet-4-6",
        "gemini-claude-opus-4-5-thinking": "claude-opus-4-6-thinking",
    ]

    /// 剥离 provider 前缀并应用静态别名。
    public static func resolveModelID(_ model: String) -> String {
        let stripped = model.contains("/") ? String(model.split(separator: "/").last!) : model
        return modelAliases[stripped] ?? stripped
    }

    // MARK: - 请求翻译（OpenAI → cloudcode）

    /// 把 `ChatRequest` 翻译为 cloudcode 信封（Gemini `contents`）。
    ///
    /// 规则（参考 OmniRoute `transformRequest()` + `sseCollect.ts` + `geminiToolsSanitizer.ts`）：
    /// - `system` 消息 → 首个 systemInstruction；`user`/`tool` → role `user`；`assistant` → role `model`；
    /// - **工具调用历史**：assistant 的 `tool_calls` → Gemini `functionCall` part（role 保持 `model`）；
    ///   `tool` 结果消息 → Gemini `functionResponse` part，**role 必须是 `user`**（Gemini 规范，否则 400）；
    /// - 连续同 role 的 contents 合并；空文本 part 丢弃；
    /// - 客户端 `tools`（OpenAI 格式）→ 清洗后转 Gemini `functionDeclarations` + `toolConfig`；
    /// - Claude 模型（Vertex 后端拒绝以 model 结尾的对话）剥离尾部 `model` turn；
    /// - maxOutputTokens 收敛到上游上限。
    public static func makeEnvelope(
        request: ChatRequest,
        project: String,
        rawBody: Data? = nil,
        requestID: String? = nil,
        sessionID: String? = nil
    ) -> AntigravityEnvelope {
        let upstreamModel = resolveModelID(request.model)
        var contents: [AntigravityContent] = []
        var systemInstruction: AntigravitySystemInstruction?

        for message in request.messages {
            switch message.role {
            case .system, .developer:
                if systemInstruction == nil,
                   let text = message.content?.textValue.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    systemInstruction = AntigravitySystemInstruction(parts: [AntigravityPart(text: text)])
                }
            case .assistant:
                // assistant 消息：文本 +（若有）tool_calls → functionCall part。
                // 有 functionCall 时 role 保持 `model`（Gemini 规范：functionCall 必须在 model turn 内）。
                appendAssistant(message: message, to: &contents)
            case .tool:
                // 工具结果 → functionResponse part；Gemini 要求 role 为 `user`。
                appendFunctionResponse(message: message, to: &contents)
            case .user, .function:
                append(role: "user", text: message.content?.textValue, to: &contents)
            }
        }

        if contents.isEmpty {
            contents.append(AntigravityContent(role: "user", parts: [AntigravityPart(text: "")]))
        }
        if upstreamModel.lowercased().contains("claude") {
            while contents.count > 1, contents.last?.role == "model" {
                contents.removeLast()
            }
        }

        var generationConfig: AntigravityGenerationConfig?
        if request.temperature != nil || request.topP != nil || request.maxTokens != nil {
            var config = AntigravityGenerationConfig()
            config.temperature = request.temperature
            config.topP = request.topP
            if let maxTokens = request.maxTokens {
                config.maxOutputTokens = min(maxTokens, maxOutputTokensCap)
            }
            generationConfig = config
        }

        // 客户端 tools（OpenAI 格式）→ Gemini functionDeclarations。
        let geminiTools = buildGeminiTools(from: rawBody)
        var toolConfig: AntigravityToolConfig?
        if geminiTools != nil {
            toolConfig = AntigravityToolConfig(mode: "VALIDATED")
        }

        return AntigravityEnvelope(
            project: project,
            requestId: requestID ?? defaultRequestID(),
            userAgent: "antigravity",
            requestType: "agent",
            model: upstreamModel,
            request: AntigravityGeminiRequest(
                contents: contents,
                systemInstruction: systemInstruction,
                generationConfig: generationConfig,
                sessionId: sessionID ?? defaultSessionID(),
                tools: geminiTools,
                toolConfig: toolConfig
            )
        )
    }

    // MARK: - 请求方向：工具声明（OpenAI tools → Gemini functionDeclarations）

    /// 从客户端原始 JSON body 中的 `tools`（OpenAI 格式）构建 Gemini `tools`。
    /// 三种 OpenAI 形态都接受：
    ///   1. `{"type":"function","function":{"name","description","parameters"}}`
    ///   2. `{"type":"function","name","description","parameters"}`（部分客户端扁平形态）
    ///   3. 裸 `{"name","description","input_schema"}`（Claude 风格）
    /// 每个 tool 的 parameters 都过 `cleanJSONSchemaForAntigravity`（删除 Gemini 不支持的
    /// JSON Schema 关键字，见 geminiHelper.ts），工具名做净化（≤64 字符、非字母数字转 `_`）。
    /// 返回 nil 表示无工具。
    public static func buildGeminiTools(from rawBody: Data?) -> [AntigravityTool]? {
        guard let rawBody,
              let json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any],
              let rawTools = json["tools"] as? [[String: Any]],
              !rawTools.isEmpty else {
            return nil
        }

        var declarations: [AntigravityFunctionDeclaration] = []
        var seenNames = Set<String>()
        for tool in rawTools {
            // 形态 1：{type:function, function:{...}}
            if let fn = tool["function"] as? [String: Any],
               let name = fn["name"] as? String, !name.isEmpty {
                let sanitized = sanitizeToolName(name)
                if seenNames.contains(sanitized) { continue }
                seenNames.insert(sanitized)
                let params = cleanJSONSchemaForAntigravity(fn["parameters"] as? [String: Any])
                declarations.append(AntigravityFunctionDeclaration(
                    name: sanitized,
                    description: (fn["description"] as? String) ?? "",
                    parameters: params.map(anyCodableDictionary)
                ))
                continue
            }
            // 形态 2：{type:function, name, description, parameters}
            if let name = tool["name"] as? String, !name.isEmpty {
                let sanitized = sanitizeToolName(name)
                if seenNames.contains(sanitized) { continue }
                seenNames.insert(sanitized)
                let params = cleanJSONSchemaForAntigravity(tool["parameters"] as? [String: Any])
                declarations.append(AntigravityFunctionDeclaration(
                    name: sanitized,
                    description: (tool["description"] as? String) ?? "",
                    parameters: params.map(anyCodableDictionary)
                ))
                continue
            }
            // 形态 3：Claude 风格 {name, description, input_schema}
            if let name = tool["name"] as? String, !name.isEmpty {
                let sanitized = sanitizeToolName(name)
                if seenNames.contains(sanitized) { continue }
                seenNames.insert(sanitized)
                let params = cleanJSONSchemaForAntigravity(tool["input_schema"] as? [String: Any])
                declarations.append(AntigravityFunctionDeclaration(
                    name: sanitized,
                    description: (tool["description"] as? String) ?? "",
                    parameters: params.map(anyCodableDictionary)
                ))
            }
        }
        guard !declarations.isEmpty else { return nil }
        return [AntigravityTool(functionDeclarations: declarations)]
    }

    /// 清洗 Gemini 不支持的 JSON Schema 关键字（参考 OmniRoute `geminiHelper.ts`
    /// `cleanJSONSchemaForAntigravity`）。递归删除：strict / multipleOf / minLength / maxLength /
    /// exclusiveMinimum / exclusiveMaximum / format / default / examples / $ref / $defs /
    /// additionalProperties / anyOf / oneOf / allOf / const 等；空 object schema 补
    /// `properties:{reason:{type:"string"}}` placeholder（上游硬性要求，否则 400）。
    public static func cleanJSONSchemaForAntigravity(_ schema: [String: Any]?) -> [String: Any]? {
        guard let schema else { return nil }
        var cleaned = cleanSchemaValue(schema)
        // 顶层必须是 object 类型（Gemini 硬性要求，否则 400）
        if (cleaned["type"] as? String) != "object" {
            var withType = cleaned
            withType["type"] = "object"
            if withType["properties"] == nil { withType["properties"] = [:] }
            cleaned = withType
        }
        return cleaned
    }

    /// 递归清洗单个 schema 节点。
    private static func cleanSchemaValue(_ value: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, raw) in value {
            if unsupportedSchemaKeys.contains(key) || key.hasPrefix("x-") { continue }
            if key == "properties", let props = raw as? [String: Any] {
                // properties 的键是用户自定义属性名，不能删除；只递归清洗每个子 schema
                var cleanedProps: [String: Any] = [:]
                for (propName, propSchema) in props {
                    if let dict = propSchema as? [String: Any] {
                        cleanedProps[propName] = cleanSchemaValue(dict)
                    } else {
                        cleanedProps[propName] = propSchema
                    }
                }
                out[key] = cleanedProps
            } else if let dict = raw as? [String: Any] {
                out[key] = cleanSchemaValue(dict)
            } else if let array = raw as? [[String: Any]] {
                out[key] = array.map { cleanSchemaValue($0) }
            } else {
                out[key] = raw
            }
        }
        // 空 object schema 补 placeholder（Gemini 硬性要求）
        if out["type"] as? String == "object" {
            if let props = out["properties"] as? [String: Any], props.isEmpty {
                out["properties"] = [
                    "reason": [
                        "type": "string",
                        "description": "Brief explanation of why you are calling this tool",
                    ]
                ]
                out["required"] = ["reason"]
            }
        }
        return out
    }

    /// Gemini 不支持的 JSON Schema 关键字（参考 OmniRoute `GEMINI_UNSUPPORTED_SCHEMA_KEYS`）。
    private static let unsupportedSchemaKeys: Set<String> = [
        "minLength", "maxLength", "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
        "strict", "minItems", "maxItems", "format", "default", "examples",
        "$schema", "$id", "$anchor", "$dynamicRef", "$dynamicAnchor", "$vocabulary",
        "$comment", "$defs", "definitions", "const", "$ref", "ref",
        "propertyNames", "patternProperties", "unevaluatedProperties", "unevaluatedItems",
        "contains", "minContains", "maxContains", "anyOf", "oneOf", "allOf", "not",
        "dependencies", "dependentSchemas", "dependentRequired", "title", "if", "then",
        "else", "contentMediaType", "contentEncoding", "contentSchema", "readOnly",
        "writeOnly", "deprecated", "optional", "enumDescriptions", "markdownDescription",
        "markdownEnumDescriptions", "enumItemLabels", "tags", "cornerRadius", "fillColor",
        "fontFamily", "fontSize", "fontWeight", "gap", "padding", "strokeColor",
        "strokeThickness", "textColor", "additionalProperties",
    ]

    /// 工具名净化：≤64 字符，非 `[a-zA-Z0-9_]` 转 `_`，连续 `_` 合并，首尾去除。
    static func sanitizeToolName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = ""
        var lastUnderscore = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                out.unicodeScalars.append(scalar)
                lastUnderscore = false
            } else {
                if !lastUnderscore {
                    out.append("_")
                    lastUnderscore = true
                }
            }
        }
        let collapsed = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let result = collapsed.isEmpty ? "tool" : String(collapsed.prefix(64))
        return result
    }

    /// `[String: Any]` → `[String: AnyCodable]`（工具参数 schema 的 Codable 载体）。
    private static func anyCodableDictionary(_ dict: [String: Any]) -> [String: AnyCodable] {
        dict.reduce(into: [:]) { result, entry in
            result[entry.key] = anyCodable(entry.value)
        }
    }

    private static func anyCodable(_ value: Any) -> AnyCodable {
        switch value {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let b as Bool: return .bool(b)
        case let arr as [Any]: return .array(arr.map { anyCodable($0) })
        case let dict as [String: Any]: return .object(dict.reduce(into: [:]) { $0[$1.key] = anyCodable($1.value) })
        case is NSNull: return .null
        default: return .string(String(describing: value))
        }
    }

    // MARK: - 请求方向：工具调用历史消息

    /// assistant 消息 → Gemini model turn：文本 part +（若有）tool_calls 的 functionCall part。
    private static func appendAssistant(message: ChatMessage, to contents: inout [AntigravityContent]) {
        let text = message.content?.textValue
        let calls = message.toolCalls ?? []

        var parts: [AntigravityPart] = []
        if let text, !text.isEmpty {
            parts.append(AntigravityPart(text: text))
        }
        for call in calls {
            guard let name = call.function?.name, !name.isEmpty else { continue }
            var args: [String: AnyCodable]?
            if let argsString = call.function?.arguments, !argsString.isEmpty,
               let argsData = argsString.data(using: .utf8),
               let argsJSON = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                args = anyCodableDictionary(argsJSON)
            }
            parts.append(AntigravityPart(functionCall: AntigravityFunctionCall(
                name: name,
                args: args ?? [:]
            )))
        }
        guard !parts.isEmpty else { return }

        if var last = contents.last, last.role == "model" {
            last.parts.append(contentsOf: parts)
            contents[contents.count - 1] = last
        } else {
            contents.append(AntigravityContent(role: "model", parts: parts))
        }
    }

    /// tool 结果消息 → Gemini functionResponse part；**role 必须是 `user`**（Gemini 规范）。
    private static func appendFunctionResponse(message: ChatMessage, to contents: inout [AntigravityContent]) {
        guard let toolCallID = message.toolCallID, !toolCallID.isEmpty else {
            // 无 tool_call_id：退化为普通 user 文本
            append(role: "user", text: message.content?.textValue, to: &contents)
            return
        }
        let text = message.content?.textValue ?? ""
        let name = message.name ?? toolCallID
        let part = AntigravityPart(functionResponse: AntigravityFunctionResponse(
            name: name,
            response: AntigravityFunctionResponseBody(name: name, content: text)
        ))
        if var last = contents.last, last.role == "user" {
            last.parts.append(part)
            contents[contents.count - 1] = last
        } else {
            contents.append(AntigravityContent(role: "user", parts: [part]))
        }
    }

    // MARK: - 响应翻译（cloudcode SSE → OpenAI SSE）

    /// 把一条 Gemini 格式 SSE `data:` payload 翻译为 OpenAI `chat.completion.chunk` 字典。
    /// 无内容 / 无 finish / 无 usage 时返回 nil（心跳或元数据事件）。
    ///
    /// 工具调用（参考 OmniRoute `sseCollect.ts` `processAntigravitySSEPayload`）：
    /// - 原生 `functionCall` part（Gemini 3.x 标准）→ OpenAI `delta.tool_calls`；
    /// - 文本 `[Tool call: name]\nArguments: {...}`（旧格式兜底）→ 同样转 `tool_calls`；
    /// - 出现 tool_calls 时 finish_reason 置 `tool_calls`（不被候选的 STOP 覆盖）。
    public static func openAIChunk(
        fromGeminiPayload payload: [String: Any],
        model: String,
        id: String,
        created: Int,
        emitRole: Bool,
        toolCallIndex: Int = 0
    ) -> [String: Any]? {
        var text = ""
        var finishReason: String?
        var usage: [String: Any]?
        var toolCalls: [[String: Any]] = []

        if let markdown = payload["markdown"] as? String {
            text += markdown
        }
        let response = payload["response"] as? [String: Any]
        if let markdown = response?["markdown"] as? String {
            text += markdown
        }

        if let candidate = (response?["candidates"] as? [[String: Any]])?.first {
            if let content = candidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    // 原生 functionCall part（Gemini 3.x 标准，常带 thoughtSignature）优先处理，
                    // 不能被 thought 过滤误删（参考 OmniRoute sseCollect.ts：functionCall 检查在 thought 之前）
                    if let fc = part["functionCall"] as? [String: Any] {
                        if let name = fc["name"] as? String, !name.isEmpty {
                            let args = (fc["args"] as? [String: Any]) ?? [:]
                            let id = (fc["id"] as? String) ?? "call_\(name)-\(Date().timeIntervalSince1970)"
                            toolCalls.append([
                                "id": id,
                                "type": "function",
                                "function": ["name": name, "arguments": jsonString(args)],
                            ])
                        }
                        continue
                    }
                    // 纯文本 part：跳过思考块；文本兜底解析 `[Tool call: ...]` 旧格式
                    if part["thought"] != nil || part["thoughtSignature"] != nil { continue }
                    if let piece = part["text"] as? String {
                        // 文本兜底：`[Tool call: name]\nArguments: {...}` 旧格式
                        if let parsed = parseTextualToolCall(piece) {
                            toolCalls.append([
                                "id": "call_\(parsed.name)-\(Date().timeIntervalSince1970)",
                                "type": "function",
                                "function": ["name": parsed.name, "arguments": parsed.arguments],
                            ])
                        } else {
                            text += piece
                        }
                    }
                }
            }
            if let raw = candidate["finishReason"] as? String {
                finishReason = mapFinishReason(raw)
            }
        }

        if let metadata = response?["usageMetadata"] as? [String: Any] {
            usage = [
                "prompt_tokens": metadata["promptTokenCount"] as? Int ?? 0,
                "completion_tokens": metadata["candidatesTokenCount"] as? Int ?? 0,
                "total_tokens": metadata["totalTokenCount"] as? Int ?? 0,
            ]
        }

        // 有 tool_calls 时 finish_reason 必须为 tool_calls（不被候选 STOP 覆盖）
        if !toolCalls.isEmpty {
            finishReason = "tool_calls"
        }

        guard !text.isEmpty || finishReason != nil || usage != nil || !toolCalls.isEmpty else { return nil }

        var delta: [String: Any] = [:]
        if emitRole { delta["role"] = "assistant" }
        if !text.isEmpty { delta["content"] = text }
        if !toolCalls.isEmpty {
            // 逐条带稳定 index（供客户端增量累加）
            delta["tool_calls"] = toolCalls.enumerated().map { index, call in
                var c = call
                c["index"] = toolCallIndex + index
                return c
            }
        }

        var finishValue: Any = NSNull()
        if let finishReason {
            finishValue = finishReason
        }
        var root: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finishValue,
                ]
            ],
        ]
        if let usage {
            root["usage"] = usage
        }
        return root
    }

    /// `[Tool call: name]\nArguments: {...}` 旧格式解析（Claude 系模型经 Antigravity 的输出兜底）。
    static func parseTextualToolCall(_ text: String) -> (name: String, arguments: String)? {
        let pattern = #"^[\s\S]*?\[Tool call:\s*([^\]\n]+)\]\s*\nArguments:\s*([\s\S]+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        let nameRange = match.range(at: 1)
        let argsRange = match.range(at: 2)
        guard let name = Range(nameRange, in: text).flatMap({ String(text[$0]) }),
              let args = Range(argsRange, in: text).flatMap({ String(text[$0]) }) else {
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedArgs.isEmpty else { return nil }
        return (trimmedName, trimmedArgs)
    }

    /// 字典 → 紧凑 JSON 字符串（工具参数）。
    static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 序列化为 `data: {json}\n\n` 的 SSE 字节。
    public static func encodeSSEChunk(_ json: [String: Any]) -> Data {
        let jsonData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return Data("data: \(String(decoding: jsonData, as: UTF8.self))\n\n".utf8)
    }

    /// 流结束标记。
    public static let doneEvent = Data("data: [DONE]\n\n".utf8)

    // MARK: - fetchAvailableModels 解析（best-effort）

    /// 宽容解析 `:fetchAvailableModels` 响应：
    /// 1. `models` 为字典（key 是模型 id）或数组（`modelId`/`id` + `displayName`）；
    /// 2. 否则 `groups[].buckets[]` 的 `bucketId`/`displayName`。
    public static func parseModels(from data: Data) -> [Model] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let response = (json["response"] as? [String: Any]) ?? json
        var entries: [(id: String, name: String?)] = []

        if let models = response["models"] as? [String: Any] {
            entries = models.keys.map { ($0, nil) }
        } else if let models = response["models"] as? [[String: Any]] {
            entries = models.compactMap { model in
                let id = model["modelId"] as? String ?? model["id"] as? String
                guard let id, !id.isEmpty else { return nil }
                return (id, model["displayName"] as? String)
            }
        }

        if entries.isEmpty, let groups = response["groups"] as? [[String: Any]] {
            for group in groups {
                if let buckets = group["buckets"] as? [[String: Any]] {
                    for bucket in buckets {
                        if let id = bucket["bucketId"] as? String, !id.isEmpty {
                            entries.append((id, bucket["displayName"] as? String))
                        }
                    }
                }
            }
        }

        return entries.map { Model(id: $0.id, name: $0.name ?? $0.id, supportsReasoning: true) }
    }

    // MARK: - 内部

    private static func append(role: String, text: String?, to contents: inout [AntigravityContent]) {
        guard let text, !text.isEmpty else { return }
        if var last = contents.last, last.role == role {
            last.parts.append(AntigravityPart(text: text))
            contents[contents.count - 1] = last
        } else {
            contents.append(AntigravityContent(role: role, parts: [AntigravityPart(text: text)]))
        }
    }

    static func mapFinishReason(_ raw: String) -> String {
        switch raw.uppercased() {
        case "STOP":
            return "stop"
        case "MAX_TOKENS", "MAX_OUTPUT_TOKENS":
            return "length"
        default:
            return "content_filter"
        }
    }

    static func defaultRequestID() -> String {
        let hex = OAuthRandom.hexBytes(4)
        return "agent/\(Int(Date().timeIntervalSince1970 * 1000))/\(hex)"
    }

    static func defaultSessionID() -> String {
        let max: UInt64 = 9_000_000_000_000_000_000
        let value = OAuthRandom.randomUInt64() % max
        return "-\(value)"
    }
}

/// 轻量随机辅助（arc4random，Darwin 可用）。
private enum OAuthRandom {
    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, bytes.count)
        return bytes
    }

    static func hexBytes(_ count: Int) -> String {
        randomBytes(count).map { String(format: "%02x", $0) }.joined()
    }

    static func randomUInt64() -> UInt64 {
        var value: UInt64 = 0
        arc4random_buf(&value, MemoryLayout<UInt64>.size)
        return value
    }
}
