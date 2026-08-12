import Foundation

/// Responses API 请求翻译错误（客户端请求不合法或暂不支持时返回明确 400）。
public struct ResponsesTranslationError: Error, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Responses 请求翻译结果：ChatRequest + 请求级 namespace 工具身份映射（F2）。
public struct ResponsesTranslationResult: Sendable {
    public let request: ChatRequest
    public let toolIdentity: ResponsesToolIdentityMap

    public init(request: ChatRequest, toolIdentity: ResponsesToolIdentityMap) {
        self.request = request
        self.toolIdentity = toolIdentity
    }
}

/// OpenAI Responses API → 内部 ChatRequest 翻译器（纯函数，无共享状态）。
///
/// 支持（对齐计划 §5.1 + §12 阶段 F/G）：
/// - `input` 字符串 / 消息数组 / function_call_output / input_image / input_file；
/// - `instructions` 追加 system 消息；
/// - 顶层 `tools` 与 `additional_tools` 输入项合并收集（显式顶层声明优先）；
/// - namespace 子工具拍平成 `"\(ns)__\(leaf)"`（64 字符 hash 截断），并产出身份映射；
/// - `web_search` / `file_search` 在 `serverToolsEnabled` 时原样透传，否则跳过；
/// - `previous_response_id` 由调用方用会话表展开为历史消息，翻译器本身不持有状态。
public enum ResponsesRequestTranslator {
    public static func translate(
        body: Data,
        history: [ChatMessage] = [],
        serverToolsEnabled: Bool = false
    ) throws -> ResponsesTranslationResult {
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

        let collected = ResponsesToolCollector.collect(
            rootTools: json["tools"] as? [[String: Any]],
            inputItems: inputItems
        )
        var chatTools: [[String: Any]] = []
        for tool in collected.tools {
            guard let type = tool["type"] as? String else { continue }
            switch type {
            case "function":
                if let chatTool = Self.chatTool(from: tool, wireName: nil) {
                    chatTools.append(chatTool)
                }
            case "namespace":
                let nsName = ResponsesToolCollector.toolName(tool)
                guard !nsName.isEmpty,
                      let subTools = tool["tools"] as? [[String: Any]] else { continue }
                for sub in subTools {
                    let leaf = ResponsesToolCollector.toolName(sub)
                    guard !leaf.isEmpty else { continue }
                    let wireName = ResponsesToolCollector.flattenNamespaceToolName(namespace: nsName, leaf: leaf)
                    if let chatTool = Self.chatTool(from: sub, wireName: wireName) {
                        chatTools.append(chatTool)
                    }
                }
            case let type where ServerToolTypes.isServerTool(type):
                // F4：开关开启时保留原始工具定义透传，上游不支持时原样报错，不自动降级。
                if serverToolsEnabled {
                    chatTools.append(tool)
                }
            case "custom", "command", "local_shell", "tool_search", "image_generation":
                // 元数据、本地执行与搜索/生图托管工具跳过，避免破坏 Codex 主对话。
                continue
            default:
                throw ResponsesTranslationError("unsupported Responses API tool type: \(type)")
            }
        }

        var chatBody: [String: Any] = [
            "model": model,
            "messages": messages.map(ChatMessageJSON.make),
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
        return ResponsesTranslationResult(request: request, toolIdentity: collected.identityMap)
    }

    /// 把 Responses 工具转成 Chat function tool；namespace 子工具用拍平后的 wire name。
    private static func chatTool(from tool: [String: Any], wireName: String?) -> [String: Any]? {
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
            if let strict = tool["strict"] { built["strict"] = strict }
            function = built
        } else {
            return nil
        }
        var chatTool: [String: Any] = ["type": "function", "function": function]
        if let id = tool["id"] as? String { chatTool["id"] = id }
        if let wireName, !wireName.isEmpty {
            var fn = function
            fn["name"] = wireName
            chatTool["function"] = fn
        }
        return chatTool
    }

    /// Responses input 数组逐项转换。reasoning / tool_search 等展示型元数据跳过。
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
                    content: Self.chatContent(from: item["content"])
                ))
            case "input_image":
                flushPending()
                let part = Self.imagePart(from: item)
                messages.append(ChatMessage(role: .user, content: .parts([part])))
            case "input_file":
                flushPending()
                let part = Self.filePart(from: item)
                messages.append(ChatMessage(role: .user, content: .parts([part])))
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
            case "reasoning", "custom_tool_call", "custom_tool_call_output", "tool_search_call", "tool_search_result", "additional_tools":
                // 展示型元数据与已收集的 additional_tools 不产生消息，不阻断对话。
                continue
            default:
                // 未知项类型：跳过而不是伪造消息，避免破坏既有会话。
                continue
            }
        }
        flushPending()
    }

    /// content 可以是字符串、`input_text` 块数组等；含图片/file 时保留 parts。
    private static func chatContent(from content: Any?) -> ChatContent {
        if let string = content as? String { return .text(string) }
        guard let parts = content as? [[String: Any]], !parts.isEmpty else { return .text("") }

        var converted: [ChatContentPart] = []
        for part in parts {
            switch part["type"] as? String {
            case "input_text", "output_text":
                if let text = part["text"] as? String, !text.isEmpty {
                    converted.append(ChatContentPart(type: "text", text: text))
                }
            case "refusal":
                if let refusal = part["refusal"] as? String, !refusal.isEmpty {
                    converted.append(ChatContentPart(type: "text", text: refusal))
                }
            case "input_image":
                converted.append(Self.imagePart(from: part))
            case "input_file":
                converted.append(Self.filePart(from: part))
            default:
                if let text = part["text"] as? String, !text.isEmpty {
                    converted.append(ChatContentPart(type: "text", text: text))
                }
            }
        }
        guard !converted.isEmpty else { return .text("") }
        if converted.contains(where: { $0.type == "image_url" || $0.type == "file" }) {
            return .parts(converted)
        }
        return .text(converted.compactMap(\.text).joined())
    }

    private static func imagePart(from json: [String: Any]) -> ChatContentPart {
        let url: String
        if let string = json["image_url"] as? String {
            url = string
        } else if let obj = json["image_url"] as? [String: Any] {
            url = obj["url"] as? String ?? ""
        } else {
            url = ""
        }
        return ChatContentPart(
            type: "image_url",
            imageURL: url,
            detail: json["detail"] as? String
        )
    }

    private static func filePart(from json: [String: Any]) -> ChatContentPart {
        var data = json
        if let nested = json["file"] as? [String: Any] {
            data = nested
        }
        return ChatContentPart(
            type: "file",
            fileData: data["file_data"] as? String,
            fileID: data["file_id"] as? String,
            fileURL: data["file_url"] as? String,
            filename: data["filename"] as? String
        )
    }

    /// function_call_output 的 output 可能是字符串、JSON 对象或 content part 数组。
    private static func outputString(_ output: Any?) -> String {
        if let string = output as? String { return string }
        if let parts = output as? [[String: Any]] {
            var textParts: [String] = []
            var hasImage = false
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    textParts.append(text)
                } else if part["type"] as? String == "input_image" {
                    hasImage = true
                }
            }
            if !textParts.isEmpty {
                return textParts.joined(separator: "\n")
            }
            if hasImage {
                // Chat tool 消息不能带图片，避免把 base64 当文本嵌入。
                return "[Image omitted: not supported on Chat Completions tool results]"
            }
        }
        return jsonString(output ?? [:])
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

/// 高级工具类型识别（F4）：`web_search` 系列（含 Anthropic versioned 形态）与 `file_search`。
public enum ServerToolTypes {
    public static func isWebSearch(_ type: String) -> Bool {
        type.hasPrefix("web_search")
    }

    public static func isFileSearch(_ type: String) -> Bool {
        type == "file_search" || type.hasPrefix("file_search")
    }

    public static func isServerTool(_ type: String) -> Bool {
        isWebSearch(type) || isFileSearch(type)
    }
}
