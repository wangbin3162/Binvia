import Foundation

/// Chat 消息 → 请求体 JSON 的共享构建器（Responses / Anthropic 翻译器共用）。
///
/// content 保留字符串形态；只有 content 为 parts 且含图片/file 时才输出
/// content part 数组（多模态不能退化成纯文本拼接）。
public enum ChatMessageJSON {
    public static func make(_ message: ChatMessage) -> [String: Any] {
        var json: [String: Any] = ["role": message.role.rawValue]
        if let content = message.content {
            switch content {
            case .text(let value):
                json["content"] = value
            case .parts(let parts):
                if parts.contains(where: { $0.type == "image_url" || $0.type == "file" }) {
                    json["content"] = parts.map(partJSON)
                } else {
                    json["content"] = parts.compactMap(\.text).joined()
                }
            }
        } else {
            json["content"] = ""
        }
        if let name = message.name { json["name"] = name }
        if let toolCallID = message.toolCallID { json["tool_call_id"] = toolCallID }
        if let reasoning = message.reasoningContent, !reasoning.isEmpty {
            json["reasoning_content"] = reasoning
        }
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

    static func partJSON(_ part: ChatContentPart) -> [String: Any] {
        switch part.type {
        case "image_url":
            var image: [String: Any] = ["url": part.imageURL ?? ""]
            if let detail = part.detail, !detail.isEmpty {
                image["detail"] = detail
            }
            return ["type": "image_url", "image_url": image]
        case "file":
            var file: [String: Any] = [:]
            if let value = part.fileData { file["file_data"] = value }
            if let value = part.fileID { file["file_id"] = value }
            if let value = part.fileURL { file["file_url"] = value }
            if let value = part.filename { file["filename"] = value }
            return ["type": "file", "file": file]
        default:
            return ["type": "text", "text": part.text ?? ""]
        }
    }
}
