import Foundation

/// 把「强制流式」上游的 OpenAI chat completion SSE chunk 流聚合成单个 JSON 响应。
/// 用于 CodeBuddy 等上游只支持流式的供应商：客户端请求 `stream=false` 时，
/// Provider 执行器用本工具把 SSE 聚合为 OpenAI JSON 结构再返回。
///
/// 工具调用：`delta.tool_calls` 按 `index` 增量累加（name / arguments 拼接），
/// 聚合后输出 `message.tool_calls` + `finish_reason: "tool_calls"`。
public enum SSEJSONAggregator {
    public static func aggregateChatCompletion(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var parser = SSEParser()
        var id: String?
        var model: String?
        var created: Int?
        var content = ""
        var finishReason: String?
        var usage: [String: Any]?
        // tool_calls 累加器：index → (id, type, name, arguments)
        var toolCalls: [Int: (id: String?, type: String?, name: String, arguments: String)] = [:]
        var hasToolCalls = false

        func consume(_ event: String) {
            guard let value = SSEEvent.dataValue(from: event) else { return }
            if SSEEvent.isDone(value) { return }
            guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return }
            if id == nil { id = json["id"] as? String }
            if model == nil { model = json["model"] as? String }
            if created == nil { created = json["created"] as? Int }
            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                if let delta = first["delta"] as? [String: Any] {
                    if let piece = delta["content"] as? String {
                        content += piece
                    }
                    if let calls = delta["tool_calls"] as? [[String: Any]] {
                        for call in calls {
                            let index = call["index"] as? Int ?? toolCalls.count
                            let id = call["id"] as? String
                            let type = call["type"] as? String
                            var name = ""
                            var arguments = ""
                            if let fn = call["function"] as? [String: Any] {
                                name = (fn["name"] as? String) ?? ""
                                arguments = (fn["arguments"] as? String) ?? ""
                            }
                            var existing = toolCalls[index] ?? (nil, nil, "", "")
                            if let id, !id.isEmpty { existing.id = id }
                            if let type, !type.isEmpty { existing.type = type }
                            if !name.isEmpty { existing.name += name }
                            existing.arguments += arguments
                            toolCalls[index] = existing
                            hasToolCalls = true
                        }
                    }
                }
                if let reason = first["finish_reason"] as? String, !reason.isEmpty {
                    finishReason = reason
                }
            }
            if let u = json["usage"] as? [String: Any] {
                usage = u
            }
        }

        for try await chunk in stream {
            for event in parser.append(chunk) {
                consume(event)
            }
        }
        for event in parser.finish() {
            consume(event)
        }

        var message: [String: Any] = ["role": "assistant", "content": content]
        if hasToolCalls {
            // 按 index 排序输出完整 tool_calls
            let sorted = toolCalls.sorted { $0.key < $1.key }
            message["tool_calls"] = sorted.map { entry in
                let (index, call) = entry
                return [
                    "id": call.id ?? "call_\(index)",
                    "type": call.type ?? "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments.isEmpty ? "{}" : call.arguments,
                    ],
                ]
            }
            finishReason = finishReason == "stop" || finishReason == nil ? "tool_calls" : finishReason
        }

        var root: [String: Any] = [
            "id": id ?? "chatcmpl-aggregated",
            "object": "chat.completion",
            "created": created ?? Int(Date().timeIntervalSince1970),
            "model": model ?? "unknown",
            "choices": [
                [
                    "index": 0,
                    "message": message,
                    "finish_reason": finishReason ?? "stop",
                ]
            ],
        ]
        if let usage {
            root["usage"] = usage
        }
        return try JSONSerialization.data(withJSONObject: root, options: [])
    }
}
