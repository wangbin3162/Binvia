import Foundation

/// Codex（chatgpt.com 后端）Responses API 与 OpenAI Chat Completions 的双向翻译。
///
/// 参考 OmniRoute：
/// - 请求：`open-sse/translator/request/openai-responses.ts`（chat → responses 格式映射；
///   模型 effort 后缀剥离 → `reasoning.effort`；system → developer；白名单过滤）。
/// - 响应：`open-sse/translator/response/openai-responses.ts`（Responses SSE → chat chunk 映射；
///   `response.completed` 的 `input_tokens`/`output_tokens` → `prompt_tokens`/`completion_tokens`）。
public enum CodexResponsesTranslator {

    // MARK: - 请求翻译（chat-completions raw JSON → responses body）

    /// 把客户端 chat-completions 请求翻译为 Codex Responses 请求体。
    /// `rawBody` 为客户端原始 JSON（保留未知字段与工具定义）；为 nil 时（如 `testModel` 的
    /// 默认实现）回退用 `JSONEncoder` 编码 `request`。
    /// `request.model` 为路由层剥离前缀后的模型名（如 `gpt-5.6-sol` 或带 effort 后缀的
    /// `gpt-5.6-sol-high`）。
    public static func makeRequestBody(request: ChatRequest, rawBody: Data?) throws -> Data {
        let effectiveBody: Data
        if let rawBody {
            effectiveBody = rawBody
        } else {
            effectiveBody = try JSONEncoder().encode(request)
        }
        guard let json = try? JSONSerialization.jsonObject(with: effectiveBody) as? [String: Any] else {
            throw ProviderError.invalidResponse("invalid request body")
        }

        var body: [String: Any] = [:]
        body["input"] = buildInput(from: json["messages"] as? [[String: Any]] ?? [])
        body["stream"] = true
        body["store"] = false
        body["instructions"] = (json["instructions"] as? String) ?? "You are a ChatGPT agent."
        if let tools = json["tools"] as? [[String: Any]] {
            body["tools"] = tools.map { tool in
                var t = tool
                if (t["type"] as? String) == nil {
                    t["type"] = "function"
                }
                return t
            }
        }
        if let toolChoice = json["tool_choice"] {
            body["tool_choice"] = toolChoice
        }
        if let reasoning = json["reasoning"] as? [String: Any] {
            body["reasoning"] = reasoning
        }

        // 模型 effort 后缀剥离 → reasoning.effort（上游只认基础模型名，effort 单独传）。
        let split = splitEffortSuffix(request.model)
        body["model"] = split.baseModel
        if let effort = split.effort {
            var reasoning = body["reasoning"] as? [String: Any] ?? [:]
            reasoning["effort"] = effort
            body["reasoning"] = reasoning
        }

        return try JSONSerialization.data(withJSONObject: body)
    }

    /// messages → Responses `input` 数组。
    /// - system → `role: developer`
    /// - assistant 带 tool_calls → `function_call` item + 文本 message item
    /// - tool → `function_call_output` item
    private static func buildInput(from messages: [[String: Any]]) -> [[String: Any]] {
        var input: [[String: Any]] = []
        for message in messages {
            guard let role = message["role"] as? String else { continue }
            switch role {
            case "system":
                input.append([
                    "type": "message",
                    "role": "developer",
                    "content": normalizedContent(message["content"]),
                ])
            case "user":
                input.append([
                    "type": "message",
                    "role": "user",
                    "content": normalizedContent(message["content"]),
                ])
            case "assistant":
                if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                    for toolCall in toolCalls {
                        let fn = toolCall["function"] as? [String: Any] ?? [:]
                        input.append([
                            "type": "function_call",
                            "call_id": toolCall["id"] as? String ?? "",
                            "name": fn["name"] as? String ?? "",
                            "arguments": fn["arguments"] as? String ?? "",
                        ])
                    }
                }
                let content = message["content"] as? String ?? ""
                if !content.isEmpty {
                    input.append([
                        "type": "message",
                        "role": "assistant",
                        "content": normalizedContent(content),
                    ])
                }
            case "tool":
                input.append([
                    "type": "function_call_output",
                    "call_id": message["tool_call_id"] as? String ?? "",
                    "output": message["content"] as? String ?? "",
                ])
            default:
                break
            }
        }
        if input.isEmpty {
            // 空 input 会被后端拒绝：补一个 continue 占位（同 OmniRoute stripStoredItemReferences）。
            input.append([
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "continue"]],
            ])
        }
        return input
    }

    /// content 归一化：string → `[{type: input_text, text}]`；多段数组把 `text` 映射为 `input_text`。
    private static func normalizedContent(_ content: Any?) -> [[String: Any]] {
        if let string = content as? String {
            return [["type": "input_text", "text": string]]
        }
        if let parts = content as? [[String: Any]] {
            return parts.map { part in
                if (part["type"] as? String) == "text" {
                    var mapped = part
                    mapped["type"] = "input_text"
                    return mapped
                }
                return part
            }
        }
        return [["type": "input_text", "text": ""]]
    }

    /// 模型 effort 后缀（-low/-medium/-high/-xhigh/-max/-ultra）剥离。
    /// 参考 OmniRoute `splitCodexReasoningSuffix`。
    public static func splitEffortSuffix(_ model: String) -> (baseModel: String, effort: String?) {
        let suffixes = ["xhigh", "high", "medium", "low", "max", "ultra"]
        for suffix in suffixes where model.hasSuffix("-\(suffix)") {
            return (String(model.dropLast(suffix.count + 1)), suffix)
        }
        return (model, nil)
    }

    // MARK: - 响应翻译（Responses SSE → OpenAI chat-completions SSE）

    /// 响应翻译的累积状态（单请求流内可变对象）。
    public struct CodexResponseState: Sendable {
        public var chatID: String
        public var created: Int
        public var model: String
        public var toolCallIndex: Int
        public var currentToolCallID: String?
        public var currentToolCallArgsBuffer: String
        public var hasToolCalls: Bool
        public var roleEmitted: Bool
        public var usage: CodexUsage?
        /// 中途错误（`response.failed` / `error` 事件），流结束由调用方抛错。
        public var error: String?
        /// 已收到 `response.completed` / `response.failed`。
        public var terminal: Bool

        public init(model: String) {
            self.chatID = "chatcmpl-\(UUID().uuidString)"
            self.created = Int(Date().timeIntervalSince1970)
            self.model = model
            self.toolCallIndex = 0
            self.currentToolCallID = nil
            self.currentToolCallArgsBuffer = ""
            self.hasToolCalls = false
            self.roleEmitted = false
            self.usage = nil
            self.error = nil
            self.terminal = false
        }
    }

    /// 规范化后的 token 用量（来自 `response.completed` 的 usage 字段）。
    public struct CodexUsage: Sendable, Equatable {
        public let promptTokens: Int
        public let completionTokens: Int
        public let totalTokens: Int
    }

    /// 翻译一个上游 SSE 事件块为 OpenAI chat-completions SSE chunk；无需输出返回 nil。
    /// 支持两种上游格式：带 `event:` 头，或仅 `data:` JSON（从 JSON `type` 字段推断事件类型）。
    public static func translatedChunk(_ data: Data, state: inout CodexResponseState) -> Data? {
        guard let block = String(data: data, encoding: .utf8) else { return nil }
        let (eventHeader, dataString) = parseSSEBlock(block)
        guard let dataString, !dataString.isEmpty, dataString != "[DONE]" else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(dataString.utf8)) as? [String: Any] else {
            return nil
        }
        let type = (json["type"] as? String) ?? (eventHeader ?? "")

        // 更新模型（上游回显）。
        if state.model.isEmpty, let m = json["model"] as? String {
            state.model = m
        }

        switch type {
        case "response.created", "response.in_progress", "response.output_text.done",
             "response.content_part.added", "response.content_part.done", "response.output_item.done",
             "response.output_item.added":
            // `response.output_item.added/done` 里只有 function_call 需要翻译（下面单独处理），
            // 普通 message item 由 delta 事件驱动，这里跳过。
            if type == "response.output_item.added" || type == "response.output_item.done" {
                return translatedOutputItem(json, eventType: type, state: &state)
            }
            return nil

        case "response.output_text.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return nil }
            return chatChunk(state: &state, delta: ["content": delta])

        case "response.function_call_arguments.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return nil }
            state.currentToolCallArgsBuffer += delta
            state.hasToolCalls = true
            return chatChunk(state: &state, delta: [
                "tool_calls": [
                    ["index": state.toolCallIndex, "function": ["arguments": delta]],
                ],
            ])

        case "response.completed":
            state.terminal = true
            if let response = json["response"] as? [String: Any] {
                if let usage = response["usage"] as? [String: Any] {
                    state.usage = parseUsage(usage)
                }
                if let status = response["status"] as? String, status == "failed",
                   let error = response["error"] as? [String: Any],
                   let message = error["message"] as? String, !message.isEmpty {
                    state.error = message
                    return nil
                }
            }
            return finalChunk(state: &state)

        case "response.failed", "error":
            state.terminal = true
            state.error = extractErrorMessage(json) ?? "Codex upstream error"
            return nil

        default:
            return nil
        }
    }

    /// `response.output_item.added/done` 中 function_call 的翻译（首个 chunk 或补发 arguments）。
    private static func translatedOutputItem(
        _ json: [String: Any],
        eventType: String,
        state: inout CodexResponseState
    ) -> Data? {
        guard let item = json["item"] as? [String: Any],
              (item["type"] as? String) == "function_call" else {
            return nil
        }
        let callID = (item["call_id"] as? String) ?? state.currentToolCallID ?? fallbackToolCallID()
        let name = item["name"] as? String ?? ""
        let args = item["arguments"] as? String ?? ""
        let isAdded = eventType == "response.output_item.added"

        if isAdded {
            state.currentToolCallID = callID
            state.currentToolCallArgsBuffer = ""
            state.hasToolCalls = true
            guard !name.isEmpty else { return nil }
            return chatChunk(state: &state, delta: [
                "tool_calls": [
                    ["index": state.toolCallIndex, "id": callID, "type": "function",
                     "function": ["name": name, "arguments": ""]],
                ],
            ])
        } else {
            // output_item.done：无 delta 时补发完整 arguments（同 OmniRoute 行为）。
            if state.currentToolCallArgsBuffer.isEmpty, !args.isEmpty {
                guard !name.isEmpty else { return nil }
                let index = state.toolCallIndex
                state.toolCallIndex += 1
                return chatChunk(state: &state, delta: [
                    "tool_calls": [
                        ["index": index, "id": callID, "type": "function",
                         "function": ["name": name, "arguments": args]],
                    ],
                ])
            }
            state.toolCallIndex += 1
            return nil
        }
    }

    /// 最终 chunk：finish_reason + usage（映射为 OpenAI chat completion 字段）。
    public static func finalChunk(state: inout CodexResponseState) -> Data {
        var chunk: [String: Any] = [
            "id": state.chatID,
            "object": "chat.completion.chunk",
            "created": state.created,
            "model": state.model,
            "choices": [
                [
                    "index": 0,
                    "delta": [String: Any](),
                    "finish_reason": state.hasToolCalls ? "tool_calls" : "stop",
                ],
            ],
        ]
        if let usage = state.usage {
            chunk["usage"] = [
                "prompt_tokens": usage.promptTokens,
                "completion_tokens": usage.completionTokens,
                "total_tokens": usage.totalTokens,
            ]
        }
        return encodeChunk(chunk)
    }

    /// 结束标记。
    public static let doneEvent = Data("data: [DONE]\n\n".utf8)

    // MARK: - 内部工具

    /// 构造 chat-completion chunk SSE（`data:` 行）。首个 content delta 附带 `role: assistant`。
    private static func chatChunk(state: inout CodexResponseState, delta: [String: Any]) -> Data {
        var d = delta
        if d["content"] != nil, !state.roleEmitted {
            d["role"] = "assistant"
            state.roleEmitted = true
        }
        let chunk: [String: Any] = [
            "id": state.chatID,
            "object": "chat.completion.chunk",
            "created": state.created,
            "model": state.model,
            "choices": [
                ["index": 0, "delta": d, "finish_reason": NSNull()],
            ],
        ]
        return encodeChunk(chunk)
    }

    private static func encodeChunk(_ chunk: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data("{}".utf8)
        let text = "data: \(String(data: data, encoding: .utf8) ?? "{}")\n\n"
        return Data(text.utf8)
    }

    /// 解析单个 SSE 事件块，返回 (event 头, data 值)。
    private static func parseSSEBlock(_ block: String) -> (event: String?, data: String?) {
        var event: String?
        var dataLines: [String] = []
        for line in block.components(separatedBy: "\n") {
            let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if cleaned.hasPrefix("event:") {
                event = String(cleaned.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if cleaned.hasPrefix("data:") {
                dataLines.append(String(cleaned.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return (event, dataLines.isEmpty ? nil : dataLines.joined(separator: "\n"))
    }

    /// 从 `response.completed` 的 usage 对象提取 token 用量（`input_tokens`/`output_tokens`）。
    private static func parseUsage(_ usage: [String: Any]) -> CodexUsage {
        let prompt = (usage["input_tokens"] as? Int) ?? 0
        let completion = (usage["output_tokens"] as? Int) ?? 0
        let total = (usage["total_tokens"] as? Int) ?? (prompt + completion)
        return CodexUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }

    /// 提取错误消息（`data.error` 或 `data.response.error`）。
    private static func extractErrorMessage(_ json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let response = json["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return nil
    }

    private static func fallbackToolCallID() -> String {
        "call_\(UUID().uuidString)"
    }
}
