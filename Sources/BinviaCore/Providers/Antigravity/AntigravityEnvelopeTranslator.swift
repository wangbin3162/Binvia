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
public struct AntigravityGeminiRequest: Sendable, Codable, Equatable {
    public var contents: [AntigravityContent]
    public var systemInstruction: AntigravitySystemInstruction?
    public var generationConfig: AntigravityGenerationConfig?
    public var sessionId: String?

    public init(
        contents: [AntigravityContent],
        systemInstruction: AntigravitySystemInstruction? = nil,
        generationConfig: AntigravityGenerationConfig? = nil,
        sessionId: String? = nil
    ) {
        self.contents = contents
        self.systemInstruction = systemInstruction
        self.generationConfig = generationConfig
        self.sessionId = sessionId
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

public struct AntigravityPart: Sendable, Codable, Equatable {
    public var text: String?

    public init(text: String?) {
        self.text = text
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
    /// 规则（参考 OmniRoute `transformRequest()`）：
    /// - `system` 消息 → 首个 systemInstruction；`user`/`tool` → role `user`；`assistant` → role `model`；
    /// - 连续同 role 的 contents 合并；空文本 part 丢弃；
    /// - Claude 模型（Vertex 后端拒绝以 model 结尾的对话）剥离尾部 `model` turn；
    /// - maxOutputTokens 收敛到上游上限。
    public static func makeEnvelope(
        request: ChatRequest,
        project: String,
        requestID: String? = nil,
        sessionID: String? = nil
    ) -> AntigravityEnvelope {
        let upstreamModel = resolveModelID(request.model)
        var contents: [AntigravityContent] = []
        var systemInstruction: AntigravitySystemInstruction?

        for message in request.messages {
            switch message.role {
            case .system:
                if systemInstruction == nil,
                   let text = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    systemInstruction = AntigravitySystemInstruction(parts: [AntigravityPart(text: text)])
                }
            case .assistant:
                append(role: "model", text: message.content, to: &contents)
            case .user, .tool:
                append(role: "user", text: message.content, to: &contents)
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
                sessionId: sessionID ?? defaultSessionID()
            )
        )
    }

    // MARK: - 响应翻译（cloudcode SSE → OpenAI SSE）

    /// 把一条 Gemini 格式 SSE `data:` payload 翻译为 OpenAI `chat.completion.chunk` 字典。
    /// 无内容 / 无 finish / 无 usage 时返回 nil（心跳或元数据事件）。
    public static func openAIChunk(
        fromGeminiPayload payload: [String: Any],
        model: String,
        id: String,
        created: Int,
        emitRole: Bool
    ) -> [String: Any]? {
        var text = ""
        var finishReason: String?
        var usage: [String: Any]?

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
                    if part["functionCall"] != nil { continue }
                    if part["thought"] != nil || part["thoughtSignature"] != nil { continue }
                    if let piece = part["text"] as? String {
                        text += piece
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

        guard !text.isEmpty || finishReason != nil || usage != nil else { return nil }

        var delta: [String: Any] = [:]
        if emitRole { delta["role"] = "assistant" }
        if !text.isEmpty { delta["content"] = text }

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
