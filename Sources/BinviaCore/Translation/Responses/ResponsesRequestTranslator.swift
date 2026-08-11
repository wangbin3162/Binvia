import Foundation

/// Responses API 请求翻译错误（客户端请求不合法或暂不支持时返回明确 400）。
public struct ResponsesTranslationError: Error, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// OpenAI Responses API → 内部 ChatRequest 翻译器（纯函数，无共享状态）。
///
/// 第一版子集（对齐计划 §5.1）：
/// - `input` 字符串 / 消息数组 / function_call_output / 跳过 reasoning；
/// - `instructions` 追加 system 消息；
/// - `tools[].type == "function"` 转 Chat function tool，其它类型明确 400；
/// - `stream` / `max_output_tokens` / `temperature` / `top_p` 透传；
/// - `reasoning` 有上游支持时映射 `reasoning_effort`，否则剥离；
/// - `previous_response_id` 由调用方用会话表展开为历史消息，翻译器本身不持有状态。
public enum ResponsesRequestTranslator {
    public static func translate(body: Data, history: [ChatMessage] = []) throws -> ChatRequest {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ResponsesTranslationError("invalid JSON")
        }
        guard let model = json["model"] as? String, !model.isEmpty else {
            throw ResponsesTranslationError("missing required field: model")
        }

        var messages: [ChatMessage] = history
        if let instructions = json["instructions"] as? String, !instructions.isEmpty {
            messages.append(ChatMessage(role: .system, content: .text(instructions)))
        }

        let inputItems: [Any]
        if let stringInput = json["input"] as? String {
            inputItems = [["type": "message", "role": "user", "content": [["type": "input_text", "text": stringInput]]]]
        } else if let array = json["input"] as? [Any] {
            inputItems = array
        } else {
            inputItems = []
        }
        try appendInputItems(inputItems, to: &messages)

        let tools = (json["tools"] as? [[String: Any]]) ?? []
        var chatTools: [[String: Any]] = []
        for tool in tools {
            guard let type = tool["type"] as? String else { continue }
            switch type {
            case "function":
                if let chatTool = Self.chatTool(from: tool, namespacePrefix: nil) {
                    chatTools.append(chatTool)
                }
            case "namespace":
                // Codex/MCP 工具组：子工具拍平成 `namespace.name`，保留参数 schema。
                guard let namespace = tool["namespace"] as? String, !namespace.isEmpty,
                      let subTools = tool["tools"] as? [[String: Any]] else { continue }
                for sub in subTools {
                    guard (sub["type"] as? String) == "function" else { continue }
                    if let chatTool = Self.chatTool(from: sub, namespacePrefix: namespace) {
                        chatTools.append(chatTool)
                    }
                }
            case "custom", "command", "local_shell", "tool_search",
                 "web_search", "file_search", "image_generation":
                // 元数据、本地执行与高级搜索/生图工具第一版跳过，避免破坏 Codex 主对话。
                continue
            default:
                throw ResponsesTranslationError("unsupported Responses API tool type: \(type)")
            }
        }

        var chatBody: [String: Any] = [
            "model": model,
            "messages": messages.map(Self.chatMessageJSON),
        ]
        if let stream = json["stream"] as? Bool { chatBody["stream"] = stream }
        if let maxOutputTokens = json["max_output_tokens"] as? Int { chatBody["max_tokens"] = maxOutputTokens }
        if let temperature = json["temperature"] as? Double { chatBody["temperature"] = temperature }
        if let topP = json["top_p"] as? Double { chatBody["top_p"] = topP }
        if !chatTools.isEmpty { chatBody["tools"] = chatTools }
        if let reasoning = json["reasoning"] as? [String: Any],
           let effort = reasoning["effort"] as? String {
            chatBody["reasoning_effort"] = effort
        }

        let data = try JSONSerialization.data(withJSONObject: chatBody)
        var request = try JSONDecoder().decode(ChatRequest.self, from: data)
        request.rawBody = data
        return request
    }

    /// 把 Responses 工具转成 Chat function tool；namespace 子工具加前缀。
    private static func chatTool(from tool: [String: Any], namespacePrefix: String?) -> [String: Any]? {
        let function: [String: Any]
        if let nested = tool["function"] as? [String: Any] {
            function = nested
        } else if let name = tool["name"] as? String, !name.isEmpty {
            var built: [String: Any] = ["name": name]
            if let description = tool["description"] as? String, !description.isEmpty {
                built["description"] = description
            }
            if let parameters = tool["parameters"] as? [String: Any] {
                built["parameters"] = parameters
            }
            function = built
        } else {
            return nil
        }
        var chatTool: [String: Any] = ["type": "function", "function": function]
        if let id = tool["id"] as? String { chatTool["id"] = id }
        if let namespacePrefix,
           let name = function["name"] as? String,
           !name.isEmpty {
            var fn = function
            fn["name"] = "\(namespacePrefix).\(name)"
            chatTool["function"] = fn
        }
        return chatTool
    }

    /// Responses input 数组逐项转换。第一版跳过 reasoning / 未识别 metadata 项。
    private static func appendInputItems(_ items: [Any], to messages: inout [ChatMessage]) throws {
        var pendingAssistantToolCalls: [ToolCall] = []
        var pendingToolResults: [ChatMessage] = []

        func flushPending() {
            if !pendingAssistantToolCalls.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: "", toolCalls: pendingAssistantToolCalls))
                pendingAssistantToolCalls = []
            }
            messages.append(contentsOf: pendingToolResults)
            pendingToolResults = []
        }

        for item in items {
            guard let item = item as? [String: Any] else { continue }
            let type = (item["type"] as? String) ?? (item["role"] != nil ? "message" : "")

            switch type {
            case "message":
                flushPending()
                let role = ChatRole(rawValue: (item["role"] as? String) ?? "user") ?? .user
                messages.append(ChatMessage(
                    role: role,
                    content: .text(Self.textValue(from: item["content"]))
                ))
            case "function_call":
                let callID = (item["call_id"] as? String) ?? ""
                let name = (item["name"] as? String) ?? ""
                guard !name.isEmpty, !callID.isEmpty else { continue }
                let arguments: String
                if let args = item["arguments"] as? String {
                    arguments = args
                } else {
                    arguments = Self.jsonString(item["arguments"] ?? [:])
                }
                pendingAssistantToolCalls.append(ToolCall(
                    id: callID,
                    type: "function",
                    function: ToolCallFunction(name: name, arguments: arguments)
                ))
            case "function_call_output":
                flushPending()
                let callID = (item["call_id"] as? String) ?? ""
                let output = Self.outputString(item["output"])
                pendingToolResults.append(ChatMessage(
                    role: .tool,
                    content: .text(output),
                    toolCallID: callID.isEmpty ? nil : callID
                ))
            case "reasoning", "custom_tool_call", "custom_tool_call_output", "tool_search_call", "tool_search_result":
                // 第一版跳过展示型 / 搜索元数据项，不阻断对话。
                continue
            default:
                // 未知项类型：跳过而不是伪造消息，避免破坏既有会话。
                continue
            }
        }
        flushPending()
    }

    /// content 可以是字符串、`input_text` 块数组、`output_text` 块数组等，统一取纯文本。
    private static func textValue(from content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return "" }
        var text = ""
        for part in parts {
            if let value = part["text"] as? String {
                text += value
            } else if let refusal = part["refusal"] as? String {
                text += refusal
            }
        }
        return text
    }

    /// function_call_output 的 output 可能是字符串、JSON 对象或 content part 数组。
    private static func outputString(_ output: Any?) -> String {
        if let string = output as? String { return string }
        if let parts = output as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        return jsonString(output ?? [:])
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// 生成 Chat 请求体中的消息 JSON（content 保留字符串形式）。
    private static func chatMessageJSON(_ message: ChatMessage) -> [String: Any] {
        var json: [String: Any] = ["role": message.role.rawValue]
        json["content"] = message.content?.textValue ?? ""
        if let name = message.name { json["name"] = name }
        if let toolCallID = message.toolCallID { json["tool_call_id"] = toolCallID }
        if let calls = message.toolCalls {
            json["tool_calls"] = calls.map { call in
                var callJSON: [String: Any] = [:]
                if let id = call.id { callJSON["id"] = id }
                if let type = call.type { callJSON["type"] = type }
                callJSON["function"] = [
                    "name": call.function?.name ?? "",
                    "arguments": call.function?.arguments ?? "{}",
                ]
                return callJSON
            }
        }
        return json
    }
}
