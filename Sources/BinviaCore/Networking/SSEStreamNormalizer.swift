import Foundation

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
    private var responseID: String?

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
        switch format {
        case .responses:
            // Responses 协议没有 [DONE]；response.completed 是天然结束事件，
            // 缺事件时也不伪造（流式翻译器负责在流末端合成 completed）。
            break
        case .openaiChat:
            // 缺 finish_reason：先补发合成结束块，再补 [DONE]
            if !sawFinishReason {
                let reason = sawToolCall ? "tool_calls" : "stop"
                if let chunk = format.syntheticFinishChunk(finishReason: reason, id: responseID ?? "chatcmpl-binvia") {
                    out.append(chunk)
                }
            }
            // 无论上游是否已发过 [DONE]，都保证只输出一次结束标记。
            if let done = format.doneEvent() {
                out.append(done)
            }
        }
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
        // 补齐并清洗 OpenAI Chat chunk。部分上游（如 grok build）会让个别
        // SSE 事件缺少 id，严格客户端会在该事件上直接反序列化失败。
        let normalized = normalizeChatEvent(in: event)
        // 清洗 OpenAI Chat chunk 里的空串 finish_reason（上游偶发 `finish_reason:""`），
        // 改为 null 后再判定/转发，避免下游严格枚举客户端 serde 报错。
        // 空串被清洗后 finishReason(from:) 返回 nil，末尾照常合成正确值。
        let sanitized = format.sanitizeFinishReason(in: normalized)
        if format.finishReason(from: sanitized) != nil {
            sawFinishReason = true
        }
        if format.hasToolCallDelta(sanitized) {
            sawToolCall = true
        }
        return [Data((sanitized + "\n\n").utf8)]
    }

    /// 为正常 Chat completion SSE 事件补齐协议基础字段；error envelope 不改写。
    private func normalizeChatEvent(in event: String) -> String {
        guard case .openaiChat = format,
              let value = SSEEvent.dataValue(from: event) else {
            return event
        }
        // 廉价短路：仅当 id 已记录且与当前事件一致、四个顶层键齐全、id 非空串时，
        // 跳过 JSON 解析/重序列化（常见上游每次都带全字段，省掉每事件两次序列化开销）。
        // 文本内容恰好含键名属误判，后果只是该补未补，与改动前行为一致，可接受。
        let hasCompleteFields = value.contains("\"id\"")
            && value.contains("\"object\"")
            && value.contains("\"created\"")
            && value.contains("\"model\"")
            // ICU 正则里裸 `""` 会被解析成空模式，需用 \Q…\E 按字面量匹配空串 id。
            && value.range(of: #""id"\s*:\s*\Q""\E"#, options: .regularExpression) == nil
        if let responseID, hasCompleteFields, value.contains("\"id\":\"\(responseID)\"") {
            return event
        }

        guard let data = value.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil,
              json["choices"] is [[String: Any]] else {
            return event
        }

        // 首个事件定下 responseID（上游首个非空 id，否则合成）；之后所有事件
        // 一律改写为 responseID，保证全流 id 一致（部分上游混发缺 id/异 id 事件）。
        if responseID == nil {
            if let id = json["id"] as? String, !id.isEmpty {
                responseID = id
            } else {
                responseID = "chatcmpl-binvia-\(UUID().uuidString.lowercased())"
            }
        }
        var didModify = false
        if (json["id"] as? String) != responseID {
            json["id"] = responseID
            didModify = true
        }
        if json["object"] == nil {
            json["object"] = "chat.completion.chunk"
            didModify = true
        }
        if json["created"] == nil {
            json["created"] = Int(Date().timeIntervalSince1970)
            didModify = true
        }
        if json["model"] == nil {
            json["model"] = "unknown"
            didModify = true
        }
        // 解析后无需改动时原样返回，不做整体重序列化（避免键序/数字精度副作用）。
        guard didModify else { return event }

        guard let normalized = try? JSONSerialization.data(withJSONObject: json, options: []),
              let text = String(data: normalized, encoding: .utf8) else {
            return event
        }
        return SSEEvent.replacingDataValue(in: event, with: text) ?? event
    }
}
