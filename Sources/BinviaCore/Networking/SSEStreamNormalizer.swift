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
                if let chunk = format.syntheticFinishChunk(finishReason: reason) {
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
        if format.finishReason(from: event) != nil {
            sawFinishReason = true
        }
        if format.hasToolCallDelta(event) {
            sawToolCall = true
        }
        return [Data((event + "\n\n").utf8)]
    }
}
