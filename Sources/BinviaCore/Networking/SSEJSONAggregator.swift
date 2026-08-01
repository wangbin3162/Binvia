import Foundation

/// 把「强制流式」上游的 OpenAI chat completion SSE chunk 流聚合成单个 JSON 响应。
/// 用于 CodeBuddy / Antigravity 等上游只支持流式的供应商：客户端请求 `stream=false` 时，
/// Provider 执行器用本工具把 SSE 聚合为 OpenAI JSON 结构再返回。
public enum SSEJSONAggregator {
    public static func aggregateChatCompletion(_ stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        var parser = SSEParser()
        var id: String?
        var model: String?
        var created: Int?
        var content = ""
        var finishReason: String?
        var usage: [String: Any]?

        func consume(_ event: String) {
            guard let value = SSEEvent.dataValue(from: event) else { return }
            if SSEEvent.isDone(value) { return }
            guard let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return }
            if id == nil { id = json["id"] as? String }
            if model == nil { model = json["model"] as? String }
            if created == nil { created = json["created"] as? Int }
            if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
                if let delta = first["delta"] as? [String: Any], let piece = delta["content"] as? String {
                    content += piece
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

        var root: [String: Any] = [
            "id": id ?? "chatcmpl-aggregated",
            "object": "chat.completion",
            "created": created ?? Int(Date().timeIntervalSince1970),
            "model": model ?? "unknown",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": content],
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
