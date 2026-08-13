import Foundation

/// 流格式策略：定义结束标记识别、finish_reason 跟踪与 terminal chunk 合成方式。
/// 目前支持 OpenAI Chat 与 OpenAI Responses；Anthropic 在后续阶段接入。
public enum StreamFormat: Sendable {
    case openaiChat
    case responses

    /// 事件是否 SSE 格式（含 `data:` / `event:` / 注释）。
    func isSSE(_ event: String) -> Bool {
        if SSEEvent.dataValue(from: event) != nil { return true }
        for line in event.components(separatedBy: "\n") {
            if line.hasPrefix("event:") || line.hasPrefix(":") { return true }
        }
        return false
    }

    /// OpenAI Chat：结束标记是 `data: [DONE]`；Responses 协议没有 `[DONE]`。
    func isTerminal(_ event: String) -> Bool {
        switch self {
        case .openaiChat:
            return SSEEvent.isDone(SSEEvent.dataValue(from: event) ?? "")
        case .responses:
            return false
        }
    }

    /// 从事件中读取非空 `finish_reason`（Chat）或 `response.completed`（Responses）。
    func finishReason(from event: String) -> String? {
        switch self {
        case .openaiChat:
            guard let value = SSEEvent.dataValue(from: event),
                  let data = value.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let reason = first["finish_reason"] as? String,
                  !reason.isEmpty else { return nil }
            return reason
        case .responses:
            guard let value = SSEEvent.dataValue(from: event),
                  let data = value.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "response.completed" else { return nil }
            return "completed"
        }
    }

    /// 清洗单个 SSE 事件：把 OpenAI Chat chunk 里的 `"finish_reason":""`（空串）
    /// 改写为 `"finish_reason":null`，避免下游严格枚举客户端 serde 报错。
    ///
    /// 走定点字节重写（不解析→重序列化），保留事件其余字段顺序/精度/空白。
    /// 非 Chat 格式或无空串命中时原样返回。空串被清洗后，`finishReason(from:)`
    /// 返回 nil，`sawFinishReason` 不置位，末尾照常合成正确的 stop/tool_calls。
    func sanitizeFinishReason(in event: String) -> String {
        guard case .openaiChat = self,
              let value = SSEEvent.dataValue(from: event) else {
            return event
        }
        let cleaned = ChatFinishReasonSanitizer.sanitize(Data(value.utf8))
        // 无改写则原样返回整事件（含 SSE 前缀），避免重组丢格式。
        guard let cleanedText = String(data: cleaned, encoding: .utf8),
              cleanedText != value else {
            return event
        }
        // 重组事件：保留原 SSE 前缀（data: / event: / 注释行）。
        return SSEEvent.replacingDataValue(in: event, with: cleanedText) ?? event
    }

    /// 事件中是否出现工具调用 delta（缺 finish_reason 时用于合成 `tool_calls`）。
    func hasToolCallDelta(_ event: String) -> Bool {
        switch self {
        case .openaiChat:
            guard let value = SSEEvent.dataValue(from: event),
                  let data = value.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any],
                  let calls = delta["tool_calls"] as? [Any] else { return false }
            return !calls.isEmpty
        case .responses:
            return false
        }
    }

    /// 合成结束 chunk（缺 finish_reason 时补发）。
    func syntheticFinishChunk(finishReason: String) -> Data? {
        switch self {
        case .openaiChat:
            let root: [String: Any] = [
                "id": "chatcmpl-binvia",
                "object": "chat.completion.chunk",
                "created": Int(Date().timeIntervalSince1970),
                "model": "unknown",
                "choices": [
                    [
                        "index": 0,
                        "delta": [String: Any](),
                        "finish_reason": finishReason,
                    ]
                ],
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: root) else { return nil }
            return Data("data: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
        case .responses:
            // Responses 流以 response.completed 事件结束；正常结束时由 ResponseTranslator
            // 在流末端合成，normalizer 不补发 `[DONE]`。
            return nil
        }
    }

    /// OpenAI Chat 客户端期待 `data: [DONE]`；Responses 客户端以 response.completed 结束。
    func doneEvent() -> Data? {
        switch self {
        case .openaiChat:
            return Data("data: [DONE]\n\n".utf8)
        case .responses:
            return nil
        }
    }

    /// JSON completion body → SSE chunk（Phase 5：上游忽略 `stream:true` 时转 SSE）。
    func syntheticChunks(fromJSON json: [String: Any]) -> [Data] {
        guard case .openaiChat = self else { return [] }
        guard let choices = json["choices"] as? [[String: Any]], let first = choices.first else {
            // 非 completion 结构（如 200 + error envelope）：原样转成 SSE data 事件，不伪造成功
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                return [Data("data: \(String(decoding: data, as: UTF8.self))\n\n".utf8)]
            }
            return []
        }
        let id = json["id"] as? String ?? "chatcmpl-binvia"
        let model = json["model"] as? String ?? "unknown"
        let created = json["created"] as? Int ?? Int(Date().timeIntervalSince1970)
        let message = first["message"] as? [String: Any]
        let delta = first["delta"] as? [String: Any]
        let content = (message?["content"] as? String) ?? (delta?["content"] as? String) ?? ""
        let reason = FinishReasonNormalizer.normalized((first["finish_reason"] as? String) ?? "stop")

        func eventChunk(delta: [String: Any], finishReason: Any?) -> Data? {
            let root: [String: Any] = [
                "id": id,
                "object": "chat.completion.chunk",
                "created": created,
                "model": model,
                "choices": [
                    ["index": 0, "delta": delta, "finish_reason": finishReason ?? NSNull()]
                ],
            ]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: root) else { return nil }
            return Data("data: \(String(decoding: jsonData, as: UTF8.self))\n\n".utf8)
        }

        var out: [Data] = []
        if !content.isEmpty, let chunk = eventChunk(delta: ["content": content], finishReason: nil) {
            out.append(chunk)
        }
        if let chunk = eventChunk(delta: [:], finishReason: reason) {
            out.append(chunk)
        }
        if let done = doneEvent() {
            out.append(done)
        }
        return out
    }
}

/// finish_reason 归一化（对齐 OmniRoute `open-sse/utils/finishReason.ts`）。
///
/// 上游（如 opencode.ai 的 grok 模型）偶发返回空串或非标准值，下游严格枚举客户端
/// （Rust serde）会报 `unknown variant`。这里把空串与所有未知值兜底为 `stop`，
/// 给聚合/翻译路径统一保险（透传路径另由 `ChatFinishReasonSanitizer` 清洗）。
public enum FinishReasonNormalizer {
    public static func normalized(_ reason: String) -> String {
        switch reason {
        case "stop", "length", "tool_calls", "content_filter", "function_call":
            return reason
        case "max_tokens": return "length"
        case "safety", "recitation", "prohibited_content": return "content_filter"
        default: return "stop"
        }
    }
}
