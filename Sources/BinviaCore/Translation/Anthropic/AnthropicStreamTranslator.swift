import Foundation

/// OpenAI Chat Completions SSE → Anthropic Messages SSE 翻译器。
///
/// 事件顺序（对齐计划 §6.2）：
/// `message_start` → `content_block_start` → `content_block_delta` →
/// `content_block_stop` → `message_delta`（stop_reason + usage）→ `message_stop`。
/// 推理内容映射为 `thinking_delta`，工具调用映射为 `tool_use` + `input_json_delta`。
public final class AnthropicStreamTranslator: @unchecked Sendable {
    private let messageID: String
    private let created: Int
    private var parser = SSEParser()

    private var messageStartSent = false
    private var finishSent = false
    private var model: String?
    private var usage: [String: Any]?
    private var nextBlockIndex = 0

    // thinking / text block 状态
    private var thinkingBlockIndex: Int?
    private var thinkingBlockStarted = false
    private var textBlockIndex: Int?
    private var textBlockStarted = false
    private var textBlockClosed = false

    // tool call 状态（按上游 tc.index）
    private var toolCalls: [Int: (id: String, name: String, blockIndex: Int, startEmitted: Bool, argBuffer: String)] = [:]

    public init(messageID: String) {
        self.messageID = messageID
        self.created = Int(Date().timeIntervalSince1970)
    }

    /// 追加一个上游 chunk，返回要转发给客户端的完整 Anthropic SSE 事件。
    @discardableResult
    public func process(_ chunk: Data) -> [Data] {
        var out: [Data] = []
        for event in parser.append(chunk) {
            out.append(contentsOf: processEvent(event))
        }
        return out
    }

    /// 流结束：冲刷残余、关闭未完成块、补 message_delta + message_stop。
    public func finish() -> [Data] {
        var out: [Data] = []
        for event in parser.finish() {
            out.append(contentsOf: processEvent(event))
        }
        out.append(contentsOf: sendFinishIfNeeded())
        return out
    }

    /// 已生成的 assistant 文本（供会话表回填）。
    public var assistantText: String {
        // 简单状态：只累积 text delta；工具参数由调用方从 toolCalls 读取。
        textAccumulator
    }

    /// 已生成的 assistant tool calls。
    public var assistantToolCalls: [ToolCall] {
        toolCalls.values.sorted { $0.blockIndex < $1.blockIndex }.map { info in
            ToolCall(
                id: info.id,
                type: "function",
                function: ToolCallFunction(
                    name: info.name,
                    arguments: info.argBuffer.isEmpty ? "{}" : info.argBuffer
                )
            )
        }
    }

    private var textAccumulator = ""

    // MARK: - 事件处理

    private func processEvent(_ event: String) -> [Data] {
        guard let value = SSEEvent.dataValue(from: event),
              !SSEEvent.isDone(value),
              let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            return []
        }
        if let chunkModel = json["model"] as? String, !chunkModel.isEmpty {
            model = chunkModel
        }
        if let usage = json["usage"] as? [String: Any] {
            self.usage = usage
        }
        guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first else {
            return []
        }

        var out: [Data] = []
        if !messageStartSent {
            out.append(contentsOf: emitMessageStart())
        }

        let delta = (choice["delta"] as? [String: Any]) ?? [:]

        if let thinking = delta["reasoning_content"] as? String, !thinking.isEmpty {
            stopTextBlockIfNeeded(&out)
            if !thinkingBlockStarted {
                thinkingBlockIndex = nextBlockIndex
                nextBlockIndex += 1
                thinkingBlockStarted = true
                out.append(contentsOf: emit(
                    "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": thinkingBlockIndex!,
                        "content_block": ["type": "thinking", "thinking": ""],
                    ]
                ))
            }
            out.append(contentsOf: emit(
                "content_block_delta",
                payload: [
                    "type": "content_block_delta",
                    "index": thinkingBlockIndex!,
                    "delta": ["type": "thinking_delta", "thinking": thinking],
                ]
            ))
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            stopThinkingBlockIfNeeded(&out)
            if !textBlockStarted {
                textBlockIndex = nextBlockIndex
                nextBlockIndex += 1
                textBlockStarted = true
                textBlockClosed = false
                out.append(contentsOf: emit(
                    "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": textBlockIndex!,
                        "content_block": ["type": "text", "text": ""],
                    ]
                ))
            }
            textAccumulator += content
            out.append(contentsOf: emit(
                "content_block_delta",
                payload: [
                    "type": "content_block_delta",
                    "index": textBlockIndex!,
                    "delta": ["type": "text_delta", "text": content],
                ]
            ))
        }

        if let calls = delta["tool_calls"] as? [[String: Any]] {
            stopThinkingBlockIfNeeded(&out)
            stopTextBlockIfNeeded(&out)
            for call in calls {
                let tcIndex = (call["index"] as? Int) ?? 0
                let id = (call["id"] as? String) ?? "toolu_\(tcIndex)"
                let function = (call["function"] as? [String: Any]) ?? [:]
                let name = (function["name"] as? String) ?? ""
                let args = (function["arguments"] as? String) ?? ""

                var info: (id: String, name: String, blockIndex: Int, startEmitted: Bool, argBuffer: String)
                if let existing = toolCalls[tcIndex] {
                    info = existing
                } else {
                    info = (id, "", nextBlockIndex, false, "")
                    nextBlockIndex += 1
                }
                if !id.isEmpty { info.id = id }
                if !name.isEmpty { info.name = name }
                if !args.isEmpty { info.argBuffer += args }

                if !info.startEmitted && (!info.name.isEmpty || !info.argBuffer.isEmpty) {
                    info.startEmitted = true
                    out.append(contentsOf: emit(
                        "content_block_start",
                        payload: [
                            "type": "content_block_start",
                            "index": info.blockIndex,
                            "content_block": [
                                "type": "tool_use",
                                "id": info.id,
                                "name": info.name,
                                "input": [String: Any](),
                            ],
                        ]
                    ))
                }
                toolCalls[tcIndex] = info
                if !args.isEmpty {
                    out.append(contentsOf: emit(
                        "content_block_delta",
                        payload: [
                            "type": "content_block_delta",
                            "index": info.blockIndex,
                            "delta": ["type": "input_json_delta", "partial_json": args],
                        ]
                    ))
                }
            }
        }

        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            out.append(contentsOf: sendFinishIfNeeded(reason: reason))
        }
        return out
    }

    private func emitMessageStart() -> [Data] {
        messageStartSent = true
        return emit(
            "message_start",
            payload: [
                "type": "message_start",
                "message": [
                    "id": messageID,
                    "type": "message",
                    "role": "assistant",
                    "model": model ?? "unknown",
                    "content": [],
                    "stop_reason": NSNull(),
                    "stop_sequence": NSNull(),
                    "usage": ["input_tokens": 0, "output_tokens": 0],
                ],
            ]
        )
    }

    private func stopThinkingBlockIfNeeded(_ out: inout [Data]) {
        guard thinkingBlockStarted, let index = thinkingBlockIndex else { return }
        thinkingBlockStarted = false
        out.append(contentsOf: emit(
            "content_block_stop",
            payload: ["type": "content_block_stop", "index": index]
        ))
    }

    private func stopTextBlockIfNeeded(_ out: inout [Data]) {
        guard textBlockStarted, !textBlockClosed, let index = textBlockIndex else { return }
        textBlockClosed = true
        out.append(contentsOf: emit(
            "content_block_stop",
            payload: ["type": "content_block_stop", "index": index]
        ))
    }

    private func sendFinishIfNeeded(reason: String = "stop") -> [Data] {
        guard !finishSent else { return [] }
        finishSent = true
        var out: [Data] = []
        stopThinkingBlockIfNeeded(&out)
        stopTextBlockIfNeeded(&out)
        for (index, info) in toolCalls.sorted(by: { $0.key < $1.key }) {
            if !info.startEmitted {
                out.append(contentsOf: emit(
                    "content_block_start",
                    payload: [
                        "type": "content_block_start",
                        "index": info.blockIndex,
                        "content_block": [
                            "type": "tool_use",
                            "id": info.id,
                            "name": info.name,
                            "input": [String: Any](),
                        ],
                    ]
                ))
            }
            out.append(contentsOf: emit(
                "content_block_stop",
                payload: ["type": "content_block_stop", "index": info.blockIndex]
            ))
            _ = index
        }
        let finalUsage: [String: Any] = usage.map(Self.mapUsage) ?? ["input_tokens": 0, "output_tokens": 0]
        out.append(contentsOf: emit(
            "message_delta",
            payload: [
                "type": "message_delta",
                "delta": ["stop_reason": stopReason(reason)],
                "usage": finalUsage,
            ]
        ))
        out.append(contentsOf: emit("message_stop", payload: ["type": "message_stop"]))
        return out
    }

    private func stopReason(_ reason: String) -> String {
        switch reason {
        case "stop", "tool_calls": return "end_turn"
        case "length": return "max_tokens"
        case "content_filter": return "refusal"
        default: return "end_turn"
        }
    }

    private static func mapUsage(_ usage: [String: Any]) -> [String: Any] {
        let input = (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? 0
        var result: [String: Any] = ["input_tokens": input, "output_tokens": output]
        if let details = usage["prompt_tokens_details"] as? [String: Any],
           let cached = details["cached_tokens"] as? Int,
           cached > 0 {
            result["cache_read_input_tokens"] = cached
        }
        return result
    }

    private func emit(_ type: String, payload: [String: Any]) -> [Data] {
        guard let json = try? JSONSerialization.data(withJSONObject: payload) else { return [] }
        return [Data("event: \(type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)]
    }
}
