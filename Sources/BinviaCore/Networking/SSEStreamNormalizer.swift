import Foundation

/// 流格式策略：定义结束标记识别、finish_reason 跟踪与 terminal chunk 合成方式。
/// 第一版仅服务 OpenAI Chat；后续 Responses / Anthropic 在此注册新策略。
public enum StreamFormat: Sendable {
    case openaiChat

    /// 事件是否 SSE 格式（含 `data:` / `event:` / 注释）。
    func isSSE(_ event: String) -> Bool {
        if SSEEvent.dataValue(from: event) != nil { return true }
        for line in event.components(separatedBy: "\n") {
            if line.hasPrefix("event:") || line.hasPrefix(":") { return true }
        }
        return false
    }

    /// OpenAI Chat：结束标记是 `data: [DONE]`。
    func isTerminal(_ event: String) -> Bool {
        guard case .openaiChat = self else { return false }
        return SSEEvent.isDone(SSEEvent.dataValue(from: event) ?? "")
    }

    /// 从事件中读取非空 `finish_reason`。
    func finishReason(from event: String) -> String? {
        guard case .openaiChat = self else { return nil }
        guard let value = SSEEvent.dataValue(from: event),
              let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let reason = first["finish_reason"] as? String,
              !reason.isEmpty else { return nil }
        return reason
    }

    /// 事件中是否出现工具调用 delta（缺 finish_reason 时用于合成 `tool_calls`）。
    func hasToolCallDelta(_ event: String) -> Bool {
        guard case .openaiChat = self else { return false }
        guard let value = SSEEvent.dataValue(from: event),
              let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let calls = delta["tool_calls"] as? [Any] else { return false }
        return !calls.isEmpty
    }

    /// 合成结束 chunk（缺 finish_reason 时补发）。
    func syntheticFinishChunk(finishReason: String) -> Data? {
        guard case .openaiChat = self else { return nil }
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
    }

    func doneEvent() -> Data {
        Data("data: [DONE]\n\n".utf8)
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
        out.append(doneEvent())
        return out
    }
}

/// finish_reason 归一化（对齐 OmniRoute `open-sse/utils/finishReason.ts`）。
public enum FinishReasonNormalizer {
    public static func normalized(_ reason: String) -> String {
        switch reason {
        case "max_tokens": return "length"
        case "safety", "recitation", "prohibited_content": return "content_filter"
        default: return reason
        }
    }
}

/// 事件级 SSE 归一化器：跨 chunk 解析事件、跟踪 finish_reason、暂存 `[DONE]`，
/// 流结束时按格式策略补发结束块，保证 `finish_reason` 在 `[DONE]` 之前。
public final class SSEStreamNormalizer: @unchecked Sendable {
    private let format: StreamFormat
    private var parser = SSEParser()
    private var pendingDone = false
    private var sawFinishReason = false
    private var sawToolCall = false
    private var jsonBuffer = Data()
    private var jsonBodyMode = false

    public init(format: StreamFormat = .openaiChat) {
        self.format = format
    }

    /// 追加一个上游 chunk，返回应转发给客户端的完整事件块（0..n）。
    @discardableResult
    public func process(_ chunk: Data) -> [Data] {
        var out: [Data] = []
        for event in parser.append(chunk) {
            out.append(contentsOf: processEvent(event))
        }
        return out
    }

    /// 流结束：冲刷残余 buffer，返回 terminal 事件块。
    public func finish() -> [Data] {
        var out: [Data] = []
        for event in parser.finish() {
            out.append(contentsOf: processEvent(event))
        }
        if jsonBodyMode {
            if let json = try? JSONSerialization.jsonObject(with: jsonBuffer) as? [String: Any] {
                out.append(contentsOf: format.syntheticChunks(fromJSON: json))
            }
            return out
        }
        // 缺 finish_reason：先补发合成结束块，再补 [DONE]
        if !sawFinishReason {
            let reason = sawToolCall ? "tool_calls" : "stop"
            if let chunk = format.syntheticFinishChunk(finishReason: reason) {
                out.append(chunk)
            }
        }
        // 无论上游是否已发过 [DONE]，都保证只输出一次结束标记。
        out.append(format.doneEvent())
        return out
    }

    private func processEvent(_ event: String) -> [Data] {
        guard format.isSSE(event) else {
            // JSON body 模式：整段缓冲，结束前不转发（Phase 5 转 SSE）
            jsonBodyMode = true
            jsonBuffer.append(Data(event.utf8))
            return []
        }
        if format.isTerminal(event) {
            pendingDone = true
            return []
        }
        if format.finishReason(from: event) != nil {
            sawFinishReason = true
        }
        if format.hasToolCallDelta(event) {
            sawToolCall = true
        }
        return [Data((event + "\n\n").utf8)]
    }
}
