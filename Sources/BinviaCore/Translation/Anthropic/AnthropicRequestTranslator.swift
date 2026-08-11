import Foundation

/// Anthropic Messages API → 内部 ChatRequest 翻译器（纯函数，无共享状态）。
///
/// 第一版子集（对齐计划 §6.1）：
/// - `system` 字符串或 blocks 追加 system 消息；
/// - `messages[].content` 支持字符串与 blocks：text / thinking / tool_use / tool_result；
/// - `tools[].input_schema` 转 Chat function parameters；
/// - `max_tokens` / `temperature` / `top_p` / `stream` 透传；
/// - `thinking` 有上游支持时映射 reasoning_effort，否则剥离。
public enum AnthropicRequestTranslator {
    public static func translate(body: Data) throws -> ChatRequest {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ResponsesTranslationError("invalid JSON")
        }
        guard let model = json["model"] as? String, !model.isEmpty else {
            throw ResponsesTranslationError("missing required field: model")
        }

        var messages: [ChatMessage] = []
        if let system = json["system"] {
            let systemText = systemText(system)
            if !systemText.isEmpty {
                messages.append(ChatMessage(role: .system, content: .text(systemText)))
            }
        }

        let rawMessages = (json["messages"] as? [[String: Any]]) ?? []
        for raw in rawMessages {
            let roleRaw = (raw["role"] as? String) ?? "user"
            guard let role = ChatRole(rawValue: roleRaw) else {
                // Anthropic 只有 user/assistant；未知角色按 user 保留文本。
                messages.append(ChatMessage(role: .user, content: .text(contentText(raw["content"]))))
                continue
            }
            appendMessage(role: role, content: raw["content"], to: &messages)
        }

        let tools = (json["tools"] as? [[String: Any]]) ?? []
        var chatTools: [[String: Any]] = []
        for tool in tools {
            guard let name = tool["name"] as? String, !name.isEmpty else { continue }
            var function: [String: Any] = ["name": name]
            if let description = tool["description"] as? String, !description.isEmpty {
                function["description"] = description
            }
            var schema = (tool["input_schema"] as? [String: Any]) ?? ["type": "object"]
            if (schema["type"] as? String) == "object" && schema["properties"] == nil {
                schema["properties"] = [String: Any]()
            }
            function["parameters"] = schema
            chatTools.append(["type": "function", "function": function])
        }

        var chatBody: [String: Any] = [
            "model": model,
            "messages": messages.map(Self.chatMessageJSON),
        ]
        if let stream = json["stream"] as? Bool { chatBody["stream"] = stream }
        if let maxTokens = json["max_tokens"] as? Int { chatBody["max_tokens"] = maxTokens }
        if let temperature = json["temperature"] as? Double { chatBody["temperature"] = temperature }
        if let topP = json["top_p"] as? Double { chatBody["top_p"] = topP }
        if !chatTools.isEmpty { chatBody["tools"] = chatTools }

        // Anthropic thinking → OpenAI reasoning_effort（上游不支持时由 Provider 层剥离）。
        if let thinking = json["thinking"] as? [String: Any],
           (thinking["type"] as? String) == "enabled" {
            let budget = (thinking["budget_tokens"] as? Int) ?? 0
            let effort: String
            if budget <= 0 {
                effort = "off"
            } else if budget <= 1024 {
                effort = "low"
            } else if budget <= 10240 {
                effort = "medium"
            } else {
                effort = "high"
            }
            chatBody["reasoning_effort"] = effort
        }

        let data = try JSONSerialization.data(withJSONObject: chatBody)
        var request = try JSONDecoder().decode(ChatRequest.self, from: data)
        request.rawBody = data
        return request
    }

    private static func appendMessage(role: ChatRole, content: Any?, to messages: inout [ChatMessage]) {
        if let string = content as? String {
            messages.append(ChatMessage(role: role, content: .text(string)))
            return
        }
        guard let blocks = content as? [[String: Any]] else {
            messages.append(ChatMessage(role: role, content: .text("")))
            return
        }

        var textParts: [String] = []
        var toolCalls: [ToolCall] = []
        var toolResults: [ChatMessage] = []
        var reasoning: String?

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                }
            case "thinking":
                if let thinking = block["thinking"] as? String {
                    reasoning = (reasoning ?? "") + thinking
                }
            case "tool_use":
                let id = (block["id"] as? String) ?? ""
                let name = (block["name"] as? String) ?? ""
                guard !name.isEmpty else { continue }
                let arguments: String
                if let args = block["input"] as? String {
                    arguments = args
                } else {
                    arguments = Self.jsonString(block["input"] ?? [:])
                }
                toolCalls.append(ToolCall(
                    id: id.isEmpty ? nil : id,
                    type: "function",
                    function: ToolCallFunction(name: name, arguments: arguments)
                ))
            case "tool_result":
                let id = (block["tool_use_id"] as? String) ?? ""
                let result = toolResultText(block["content"])
                toolResults.append(ChatMessage(
                    role: .tool,
                    content: .text(result),
                    toolCallID: id.isEmpty ? nil : id
                ))
            default:
                continue
            }
        }

        // tool_result 与 tool_use 分属不同消息：先输出 assistant tool_calls，再输出 tool 消息。
        if !toolCalls.isEmpty {
            let text = textParts.joined(separator: "\n")
            messages.append(ChatMessage(
                role: .assistant,
                content: text.isEmpty ? nil : .text(text),
                toolCalls: toolCalls
            ))
            messages.append(contentsOf: toolResults)
            return
        }

        if !toolResults.isEmpty {
            messages.append(contentsOf: toolResults)
            if !textParts.isEmpty {
                messages.append(ChatMessage(role: .user, content: .text(textParts.joined(separator: "\n"))))
            }
            return
        }

        let text = textParts.joined(separator: "\n")
        let message = ChatMessage(role: role, content: text.isEmpty ? nil : .text(text))
        messages.append(message)
    }

    private static func toolResultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [[String: Any]] else { return "" }
        let texts = parts.compactMap { $0["text"] as? String }
        return texts.joined(separator: "\n")
    }

    private static func systemText(_ system: Any) -> String {
        if let string = system as? String { return string }
        guard let blocks = system as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

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
