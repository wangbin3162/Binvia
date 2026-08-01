import Foundation

/// OpenAI ↔ Anthropic Messages API 信封翻译器（纯枚举静态函数，便于单测）。
///
/// 参考 `AntigravityEnvelopeTranslator` 的「纯翻译器」模式，为 zai / minimax 等
/// Anthropic 兼容（`/v1/messages`）供应商提供：
/// - 请求方向：OpenAI `ChatRequest` → Anthropic `/v1/messages` body（JSON 字典）；
/// - 响应方向：Anthropic SSE `data:` payload → OpenAI `chat.completion.chunk` SSE。
///
/// 两种协议的结构差异：
/// - `system` 是 Anthropic 的独立顶层字段（OpenAI 中 system 是 messages 里的一条消息）；
/// - `max_tokens` 在 Anthropic 必填（OpenAI 可选）；
/// - 流式事件类型不同（`content_block_delta` / `message_delta` / `message_stop`）。
public enum AnthropicEnvelopeTranslator {
    /// Anthropic `max_tokens` 默认值（上游必填；客户端未传时使用）。
    public static let defaultMaxTokens = 4096

    /// Anthropic 版本头值（参考 OmniRoute `ANTHROPIC_VERSION_HEADER`）。
    public static let anthropicVersion = "2023-06-01"

    // MARK: - 请求翻译（OpenAI → Anthropic）

    /// 把 OpenAI `ChatRequest` 翻译为 Anthropic `/v1/messages` 请求体 JSON 字典。
    ///
    /// 规则：
    /// - `system` 消息内容拼接为顶层 `system` 字符串（空则省略该字段）；
    /// - `.user` / `.tool` → role `user`；`.assistant` → role `assistant`；保持消息顺序；
    /// - `max_tokens` 必填，客户端未传时默认 `defaultMaxTokens`；
    /// - `stream` / `temperature` / `top_p` 按需透传（Anthropic 支持这些字段）。
    public static func makeAnthropicRequest(
        model: String,
        messages: [ChatMessage],
        system: String?,
        maxTokens: Int?,
        stream: Bool,
        temperature: Double? = nil,
        topP: Double? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens ?? defaultMaxTokens,
            "stream": stream,
        ]
        if let system, !system.isEmpty {
            body["system"] = system
        }
        var anthropicMessages: [[String: Any]] = []
        for message in messages where message.role != .system {
            let role = (message.role == .assistant) ? "assistant" : "user"
            anthropicMessages.append([
                "role": role,
                "content": message.content ?? "",
            ])
        }
        if anthropicMessages.isEmpty {
            // Anthropic 要求 messages 非空
            anthropicMessages.append(["role": "user", "content": ""])
        }
        body["messages"] = anthropicMessages
        if let temperature {
            body["temperature"] = temperature
        }
        if let topP {
            body["top_p"] = topP
        }
        return body
    }

    // MARK: - 响应翻译（Anthropic SSE → OpenAI SSE）

    /// 把一条 Anthropic SSE `data:` payload 翻译为 OpenAI `chat.completion.chunk` 字典。
    ///
    /// 无论上游带不带 `event:` 行，payload JSON 都含 `type` 字段（`content_block_delta`
    /// 等），故统一按 `type` 分发。可忽略的事件（`message_start` / `content_block_start` /
    /// 非 `text_delta` / `message_stop`）返回 nil。
    ///
    /// - Parameters:
    ///   - json: Anthropic SSE 的 JSON payload（由 `SSEEvent.dataValue` 提取）。
    ///   - model: OpenAI chunk 中的模型名。
    ///   - id: OpenAI chunk 的 id（优先上游 `message.id`）。
    ///   - created: OpenAI chunk 的 created 时间戳。
    ///   - hasEmittedRole: 是否已发射过 assistant role（只在首个内容块发射一次）。
    ///   - lastStopReason: 记录最近一次 `message_delta` 翻译出的 finish_reason。
    public static func translateSSEPayload(
        _ json: [String: Any],
        model: String,
        id: String,
        created: Int,
        hasEmittedRole: inout Bool,
        lastStopReason: inout String?
    ) -> [String: Any]? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "message_start", "content_block_start", "message_stop":
            // 元数据 / 心跳事件：忽略（message_start 可捕获 usage，本实现不展示）。
            return nil
        case "content_block_delta":
            guard let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            var chunkDelta: [String: Any] = [:]
            if !hasEmittedRole {
                chunkDelta["role"] = "assistant"
                hasEmittedRole = true
            }
            if !text.isEmpty {
                chunkDelta["content"] = text
            }
            guard !chunkDelta.isEmpty else { return nil }
            return makeChunk(model: model, id: id, created: created, delta: chunkDelta, finishReason: nil)
        case "message_delta":
            guard let delta = json["delta"] as? [String: Any] else { return nil }
            let reason = mapStopReason(delta["stop_reason"] as? String)
            lastStopReason = reason
            return makeChunk(model: model, id: id, created: created, delta: [:], finishReason: reason)
        default:
            return nil
        }
    }

    /// 序列化为 `data: {json}\n\n` 的 SSE 字节。
    public static func encodeSSEChunk(_ json: [String: Any]) -> Data {
        let jsonData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        return Data("data: \(String(decoding: jsonData, as: UTF8.self))\n\n".utf8)
    }

    /// 流结束标记。
    public static let doneEvent = Data("data: [DONE]\n\n".utf8)

    // MARK: - 内部

    /// 构造 OpenAI `chat.completion.chunk` 字典。
    private static func makeChunk(
        model: String,
        id: String,
        created: Int,
        delta: [String: Any],
        finishReason: String?
    ) -> [String: Any] {
        var finishValue: Any = NSNull()
        if let finishReason {
            finishValue = finishReason
        }
        return [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finishValue,
                ]
            ],
        ]
    }

    /// Anthropic `stop_reason` → OpenAI `finish_reason` 映射。
    static func mapStopReason(_ raw: String?) -> String {
        switch raw {
        case "end_turn":
            return "stop"
        case "max_tokens":
            return "length"
        default:
            return "stop"
        }
    }
}
