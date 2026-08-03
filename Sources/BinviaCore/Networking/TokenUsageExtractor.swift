import Foundation

/// Token 用量提取器：透传 + 旁路解析。
///
/// 用于 `RouteHandler.handleChat` 包裹上游流：每个 chunk **原样返回**（透传不破坏），
/// 同时喂给内部的 `SSEParser` 解析出完整事件，从事件 `data:` 的 JSON 中抽取 `usage` 字段。
/// 流结束时 `finish()` 冲刷残余 buffer（覆盖非流式整段 JSON）并返回累计到的最后一个非空 usage。
///
/// 设计约束（对齐计划书 §3.8 / §6.4）：
/// - `process(_:)` 始终原样返回入参 chunk，解析逻辑完全独立于返回值；
/// - 解析失败一律静默（`try?`），返回 nil，绝不影响透传与日志；
/// - 流式 `usage` 可能出现在多个 chunk（部分供应商发送多个带 usage 的 chunk），取**最后一个非空**。
public final class TokenUsageExtractor: @unchecked Sendable {
    private var parser = SSEParser()
    private var lastUsage: TokenUsage?

    public init() {}

    /// 透传一个上游 chunk 并顺带解析。返回值与入参一致。
    @discardableResult
    public func process(_ chunk: Data) -> Data {
        for event in parser.append(chunk) {
            extractUsage(from: event)
        }
        return chunk
    }

    /// 流结束：冲刷 `SSEParser` 残余 buffer，返回累计到的最后一个非空 usage（无则 nil）。
    public func finish() -> TokenUsage? {
        for event in parser.finish() {
            extractUsage(from: event)
        }
        return lastUsage
    }

    /// 从事件文本抽取 usage。优先取 `data:` 字段（SSE 事件），无 `data:` 前缀时把整段
    /// 当 JSON 解析（非流式整段 JSON / `finish()` 冲刷的残余体）。
    private func extractUsage(from event: String) {
        let value = SSEEvent.dataValue(from: event) ?? event
        extractUsage(fromJSON: value)
    }

    private func extractUsage(fromJSON string: String) {
        guard let data = string.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return }
        let prompt = (usage["prompt_tokens"] as? Int) ?? 0
        let completion = (usage["completion_tokens"] as? Int) ?? 0
        let total = (usage["total_tokens"] as? Int) ?? (prompt + completion)
        lastUsage = TokenUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
    }
}
