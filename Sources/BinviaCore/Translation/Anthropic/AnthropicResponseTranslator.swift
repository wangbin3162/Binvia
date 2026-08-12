import Foundation

/// OpenAI Chat Completions JSON → Anthropic Messages JSON 翻译器（非流式）。
///
/// 对齐计划 §6.2：
/// - `message.content` → `content[].text`；
/// - `reasoning_content` → `content[].thinking`；
/// - `tool_calls` → `content[].tool_use`；
/// - usage 改名：prompt_tokens → input_tokens / completion_tokens → output_tokens。
public enum AnthropicResponseTranslator {
    public static func translate(chatJSON: Data, messageID: String) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: chatJSON) as? [String: Any] else {
            throw ResponsesTranslationError("invalid upstream chat JSON")
        }
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else {
            throw ResponsesTranslationError("upstream chat JSON missing choices")
        }

        let message = (choice["message"] as? [String: Any]) ?? [:]
        let finishReason = (choice["finish_reason"] as? String) ?? "stop"
        var content: [[String: Any]] = []

        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            content.append(["type": "thinking", "thinking": reasoning])
        }
        content.append(contentsOf: Self.contentBlocks(message["content"]))
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in calls.enumerated() {
                let function = (call["function"] as? [String: Any]) ?? [:]
                let input = (function["arguments"] as? String).flatMap { args in
                    try? JSONSerialization.jsonObject(with: Data(args.utf8))
                } ?? [String: Any]()
                content.append([
                    "type": "tool_use",
                    "id": (call["id"] as? String) ?? "toolu_\(index)",
                    "name": function["name"] as? String ?? "",
                    "input": input,
                ])
            }
        }

        let root: [String: Any] = [
            "id": messageID,
            "type": "message",
            "role": "assistant",
            "model": json["model"] as? String ?? "unknown",
            "content": content,
            "stop_reason": stopReason(finishReason),
            "stop_sequence": NSNull(),
            "usage": Self.usageJSON(json["usage"] as? [String: Any]),
        ]
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func stopReason(_ reason: String) -> String {
        switch reason {
        case "stop", "tool_calls": return "end_turn"
        case "length": return "max_tokens"
        case "content_filter": return "refusal"
        default: return reason
        }
    }

    /// Chat 消息 content → Anthropic content blocks（text / image）。
    private static func contentBlocks(_ content: Any?) -> [[String: Any]] {
        if let string = content as? String, !string.isEmpty {
            return [["type": "text", "text": string]]
        }
        guard let parts = content as? [[String: Any]] else { return [] }
        var blocks: [[String: Any]] = []
        for part in parts {
            switch part["type"] as? String {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
            case "image_url":
                let imageURL = Self.imageURL(from: part["image_url"])
                if !imageURL.isEmpty, let block = Self.imageBlock(from: imageURL) {
                    blocks.append(block)
                }
            default:
                if let text = part["text"] as? String, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
            }
        }
        return blocks
    }

    private static func imageURL(from value: Any?) -> String {
        if let string = value as? String { return string }
        if let obj = value as? [String: Any] { return obj["url"] as? String ?? "" }
        return ""
    }

    /// Chat data URL / http URL → Anthropic image source block。
    private static func imageBlock(from url: String) -> [String: Any]? {
        if url.hasPrefix("data:"),
           let range = url.range(of: ";base64,") {
            let start = url.index(url.startIndex, offsetBy: 5)
            let mediaType = String(url[start ..< range.lowerBound])
            let data = String(url[range.upperBound...])
            return [
                "type": "image",
                "source": ["type": "base64", "media_type": mediaType, "data": data],
            ]
        }
        return ["type": "image", "source": ["type": "url", "url": url]]
    }

    private static func usageJSON(_ usage: [String: Any]?) -> [String: Any] {
        guard let usage else { return ["input_tokens": 0, "output_tokens": 0] }
        let input = (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? 0
        var result: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
        ]
        if let details = usage["prompt_tokens_details"] as? [String: Any],
           let cached = details["cached_tokens"] as? Int,
           cached > 0 {
            result["cache_read_input_tokens"] = cached
        }
        if let details = usage["prompt_tokens_details"] as? [String: Any],
           let created = details["cache_creation"] as? Int,
           created > 0 {
            result["cache_creation_input_tokens"] = created
        }
        if let miss = usage["prompt_cache_miss_tokens"] as? Int, miss > 0 {
            result["cache_creation_input_tokens"] = miss
        }
        return result
    }
}
