import Foundation

/// OpenAI Chat Completions 响应 → OpenAI Responses API 响应翻译器（非流式）。
///
/// 对齐计划 §5.2：
/// - `choices[0].message.content` → `output[].message.content[].output_text`；
/// - `reasoning_content` → `output[].reasoning.summary[].summary_text`；
/// - `tool_calls` → `output[].function_call`；
/// - usage 字段改名（prompt_tokens → input_tokens / completion_tokens → output_tokens）。
public enum ResponsesResponseTranslator {
    /// 把上游 Chat JSON 翻译成 Responses API Response JSON。
    public static func translate(chatJSON: Data, responseID: String) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: chatJSON) as? [String: Any] else {
            throw ResponsesTranslationError("invalid upstream chat JSON")
        }
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else {
            throw ResponsesTranslationError("upstream chat JSON missing choices")
        }

        let message = (choice["message"] as? [String: Any]) ?? [:]
        let finishReason = (choice["finish_reason"] as? String) ?? "stop"
        let status: String = (finishReason == "length" || finishReason == "content_filter")
            ? "incomplete"
            : "completed"

        var output: [[String: Any]] = []
        var sequence = 0

        if let reasoning = message["reasoning_content"] as? String, !reasoning.isEmpty {
            let itemID = "rs_\(responseID)_\(sequence)"
            output.append([
                "id": itemID,
                "type": "reasoning",
                "summary": [["type": "summary_text", "text": reasoning]],
            ])
            sequence += 1
        }

        let contentText = Self.contentText(message)
        if !contentText.isEmpty {
            let itemID = "msg_\(responseID)_\(sequence)"
            output.append([
                "id": itemID,
                "type": "message",
                "role": "assistant",
                "content": [
                    [
                        "type": "output_text",
                        "text": contentText,
                        "annotations": [],
                    ]
                ],
            ])
            sequence += 1
        }

        if let calls = message["tool_calls"] as? [[String: Any]] {
            for (index, call) in calls.enumerated() {
                let callID = (call["id"] as? String) ?? "call_\(index)"
                let function = (call["function"] as? [String: Any]) ?? [:]
                output.append([
                    "id": "fc_\(callID)",
                    "type": "function_call",
                    "call_id": callID,
                    "name": function["name"] as? String ?? "",
                    "arguments": function["arguments"] as? String ?? "{}",
                    "status": "completed",
                ])
            }
        }

        var root: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": status,
            "model": json["model"] as? String ?? "unknown",
            "output": output,
        ]
        if let usage = Self.usageJSON(json["usage"] as? [String: Any]) {
            root["usage"] = usage
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    private static func contentText(_ message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                return nil
            }.joined()
        }
        return ""
    }

    private static func usageJSON(_ usage: [String: Any]?) -> [String: Any]? {
        guard let usage, !usage.isEmpty else { return nil }
        let input = (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? 0
        var result: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": (usage["total_tokens"] as? Int) ?? (input + output),
        ]
        if let promptDetails = usage["prompt_tokens_details"] as? [String: Any],
           let cached = promptDetails["cached_tokens"] as? Int,
           cached > 0 {
            result["input_tokens_details"] = ["cached_tokens": cached]
        }
        if let outputDetails = usage["completion_tokens_details"] as? [String: Any],
           let reasoning = outputDetails["reasoning_tokens"] as? Int,
           reasoning > 0 {
            result["output_tokens_details"] = ["reasoning_tokens": reasoning]
        }
        return result
    }
}
