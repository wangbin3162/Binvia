import Foundation

/// OpenAI Chat Completions SSE → OpenAI Responses SSE 事件翻译器。
///
/// 对齐计划 §5.3 与 OmniRoute `responsesTransformer.ts`：
/// - 事件顺序：`response.created` → `response.in_progress` → `output_item.added` →
///   `content_part.added` / `output_text.delta` → `output_text.done` →
///   `output_item.done` → `response.completed`；
/// - 推理内容映射为 `reasoning_summary_text.delta`；
/// - 工具调用映射为 `function_call_arguments.delta`；
/// - Responses 协议没有 `[DONE]`，`response.completed` 即终止。
///
/// 用法：把上游 chunk 逐段喂给 `process(_:)`，流结束后调用 `finish()`；
/// 每次调用返回 0..n 个完整 SSE 事件字节。
public final class ResponsesStreamTranslator: @unchecked Sendable {
    private let responseID: String
    private let created: Int
    private var parser = SSEParser()

    private var seq = 0
    private var started = false
    private var completedSent = false
    private var awaitingTrailingUsage = false
    private var model: String?
    private var usage: [String: Any]?
    private var sawFinishReason = false

    // message item 状态（按输出 index）
    private var msgItemAdded: [Int: Bool] = [:]
    private var msgContentAdded: [Int: Bool] = [:]
    private var msgItemDone: [Int: Bool] = [:]
    private var msgTextBuf: [Int: String] = [:]

    // reasoning item 状态
    private var reasoningID: String?
    private var reasoningIndex = -1
    private var reasoningBuf = ""
    private var reasoningDone = false

    // tool call 状态（按上游 tc.index）
    private var funcCallIDs: [Int: String] = [:]
    private var funcNames: [Int: String] = [:]
    private var funcArgsBuf: [Int: String] = [:]
    private var funcItemAdded: [Int: Bool] = [:]
    private var funcItemDone: [Int: Bool] = [:]

    private var completedOutputItems: [(outputIndex: Int, item: [String: Any], seq: Int)] = []

    public init(responseID: String) {
        self.responseID = responseID
        self.created = Int(Date().timeIntervalSince1970)
    }

    /// 追加一个上游 chunk，返回要转发给客户端的完整 SSE 事件块。
    @discardableResult
    public func process(_ chunk: Data) -> [Data] {
        var out: [Data] = []
        for event in parser.append(chunk) {
            out.append(contentsOf: processEvent(event))
        }
        return out
    }

    /// 流结束：冲刷残余 buffer、关闭未完成 item、补发 `response.completed`。
    public func finish() -> [Data] {
        var out: [Data] = []
        for event in parser.finish() {
            out.append(contentsOf: processEvent(event))
        }
        out.append(contentsOf: sendCompletedIfNeeded())
        return out
    }

    /// 已生成的 assistant 文本（供会话表回填）。
    public var assistantText: String {
        msgTextBuf.keys.sorted().compactMap { msgTextBuf[$0] }.joined()
    }

    /// 已生成的 assistant tool calls（供会话表回填）。
    public var toolCalls: [ToolCall] {
        let indices = funcCallIDs.keys.sorted()
        return indices.compactMap { index in
            guard let id = funcCallIDs[index], let name = funcNames[index] else { return nil }
            return ToolCall(
                id: id,
                type: "function",
                function: ToolCallFunction(
                    name: name,
                    arguments: funcArgsBuf[index].flatMap { $0.isEmpty ? nil : $0 } ?? "{}"
                )
            )
        }
    }

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
            // 尾随 usage-only chunk：finish_reason 已到但缺 usage 时现在补 completed。
            if awaitingTrailingUsage {
                return sendCompletedIfNeeded()
            }
            return []
        }

        var out: [Data] = []
        if !started {
            started = true
            out.append(contentsOf: emitStartEvents())
        }

        let index = (choice["index"] as? Int) ?? 0
        let delta = (choice["delta"] as? [String: Any]) ?? [:]

        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            out.append(contentsOf: startReasoning(index: index))
            out.append(contentsOf: emitReasoningDelta(reasoning))
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            if reasoningID != nil && !reasoningDone {
                out.append(contentsOf: closeReasoning())
            }
            let msgIndex = reasoningID != nil ? reasoningIndex + 1 : index
            if msgItemAdded[msgIndex] != true {
                msgItemAdded[msgIndex] = true
                let msgID = "msg_\(responseID)_\(msgIndex)"
                out.append(contentsOf: emitEvent(
                    "response.output_item.added",
                    payload: [
                        "type": "response.output_item.added",
                        "output_index": msgIndex,
                        "item": ["id": msgID, "type": "message", "content": [], "role": "assistant"],
                    ]
                ))
            }
            if msgContentAdded[msgIndex] != true {
                msgContentAdded[msgIndex] = true
                let msgID = "msg_\(responseID)_\(msgIndex)"
                out.append(contentsOf: emitEvent(
                    "response.content_part.added",
                    payload: [
                        "type": "response.content_part.added",
                        "item_id": msgID,
                        "output_index": msgIndex,
                        "content_index": 0,
                        "part": ["type": "output_text", "annotations": [], "logprobs": [], "text": ""],
                    ]
                ))
            }
            msgTextBuf[msgIndex, default: ""] += content
            out.append(contentsOf: emitEvent(
                "response.output_text.delta",
                payload: [
                    "type": "response.output_text.delta",
                    "item_id": "msg_\(responseID)_\(msgIndex)",
                    "output_index": msgIndex,
                    "content_index": 0,
                    "delta": content,
                    "logprobs": [],
                ]
            ))
        }

        if let calls = delta["tool_calls"] as? [[String: Any]] {
            if reasoningID != nil && !reasoningDone {
                out.append(contentsOf: closeReasoning())
            }
            let msgIndex = reasoningID != nil ? reasoningIndex + 1 : index
            out.append(contentsOf: closeMessage(index: msgIndex))
            for call in calls {
                let tcIndex = (call["index"] as? Int) ?? 0
                let newID = call["id"] as? String
                let function = (call["function"] as? [String: Any]) ?? [:]
                let name = function["name"] as? String
                let args = function["arguments"] as? String ?? ""

                if let existingID = funcCallIDs[tcIndex],
                   let newID,
                   existingID != newID {
                    out.append(contentsOf: closeToolCall(index: tcIndex, recordAsCompleted: false))
                    funcCallIDs.removeValue(forKey: tcIndex)
                    funcNames.removeValue(forKey: tcIndex)
                    funcArgsBuf.removeValue(forKey: tcIndex)
                    funcItemAdded.removeValue(forKey: tcIndex)
                    funcItemDone.removeValue(forKey: tcIndex)
                }
                if let name { funcNames[tcIndex] = name }
                if funcCallIDs[tcIndex] == nil, let newID { funcCallIDs[tcIndex] = newID }

                let callID = funcCallIDs[tcIndex] ?? newID ?? "call_\(tcIndex)"
                let toolName = funcNames[tcIndex] ?? name ?? ""
                if callID != "call_\(tcIndex)" || !toolName.isEmpty {
                    if funcItemAdded[tcIndex] != true {
                        funcItemAdded[tcIndex] = true
                        let outputIndex = toolOutputIndex(tcIndex)
                        out.append(contentsOf: emitEvent(
                            "response.output_item.added",
                            payload: [
                                "type": "response.output_item.added",
                                "output_index": outputIndex,
                                "item": [
                                    "id": "fc_\(callID)",
                                    "type": "function_call",
                                    "arguments": "",
                                    "call_id": callID,
                                    "name": toolName,
                                ],
                            ]
                        ))
                    }
                    if !args.isEmpty {
                        funcArgsBuf[tcIndex, default: ""] += args
                        out.append(contentsOf: emitEvent(
                            "response.function_call_arguments.delta",
                            payload: [
                                "type": "response.function_call_arguments.delta",
                                "item_id": "fc_\(callID)",
                                "output_index": toolOutputIndex(tcIndex),
                                "delta": args,
                            ]
                        ))
                    }
                }
            }
        }

        if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
            sawFinishReason = true
            for index in msgItemAdded.keys {
                out.append(contentsOf: closeMessage(index: index))
            }
            out.append(contentsOf: closeReasoning())
            for index in funcCallIDs.keys {
                out.append(contentsOf: closeToolCall(index: index))
            }
            if usage != nil {
                out.append(contentsOf: sendCompletedIfNeeded())
            } else {
                awaitingTrailingUsage = true
            }
        }
        return out
    }

    private func emitStartEvents() -> [Data] {
        var out: [Data] = []
        out.append(contentsOf: emitEvent(
            "response.created",
            payload: [
                "type": "response.created",
                "response": baseResponse(status: "in_progress"),
            ]
        ))
        out.append(contentsOf: emitEvent(
            "response.in_progress",
            payload: [
                "type": "response.in_progress",
                "response": [
                    "id": responseID,
                    "object": "response",
                    "created_at": created,
                    "status": "in_progress",
                ],
            ]
        ))
        return out
    }

    private func startReasoning(index: Int) -> [Data] {
        guard reasoningID == nil else { return [] }
        reasoningID = "rs_\(responseID)_\(index)"
        reasoningIndex = index
        var out: [Data] = []
        out.append(contentsOf: emitEvent(
            "response.output_item.added",
            payload: [
                "type": "response.output_item.added",
                "output_index": index,
                "item": ["id": reasoningID ?? "", "type": "reasoning", "summary": []],
            ]
        ))
        out.append(contentsOf: emitEvent(
            "response.reasoning_summary_part.added",
            payload: [
                "type": "response.reasoning_summary_part.added",
                "item_id": reasoningID ?? "",
                "output_index": index,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": ""],
            ]
        ))
        return out
    }

    private func emitReasoningDelta(_ text: String) -> [Data] {
        reasoningBuf += text
        guard let reasoningID, reasoningIndex >= 0 else { return [] }
        return emitEvent(
            "response.reasoning_summary_text.delta",
            payload: [
                "type": "response.reasoning_summary_text.delta",
                "item_id": reasoningID,
                "output_index": reasoningIndex,
                "summary_index": 0,
                "delta": text,
            ]
        )
    }

    private func closeReasoning() -> [Data] {
        guard let reasoningID, !reasoningDone else { return [] }
        reasoningDone = true
        var out: [Data] = []
        out.append(contentsOf: emitEvent(
            "response.reasoning_summary_text.done",
            payload: [
                "type": "response.reasoning_summary_text.done",
                "item_id": reasoningID,
                "output_index": reasoningIndex,
                "summary_index": 0,
                "text": reasoningBuf,
            ]
        ))
        out.append(contentsOf: emitEvent(
            "response.reasoning_summary_part.done",
            payload: [
                "type": "response.reasoning_summary_part.done",
                "item_id": reasoningID,
                "output_index": reasoningIndex,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": reasoningBuf],
            ]
        ))
        let item: [String: Any] = [
            "id": reasoningID,
            "type": "reasoning",
            "summary": [["type": "summary_text", "text": reasoningBuf]],
        ]
        out.append(contentsOf: emitEvent(
            "response.output_item.done",
            payload: [
                "type": "response.output_item.done",
                "output_index": reasoningIndex,
                "item": item,
            ]
        ))
        completedOutputItems.append((reasoningIndex, item, seq))
        return out
    }

    private func closeMessage(index: Int) -> [Data] {
        guard msgItemAdded[index] == true, msgItemDone[index] != true else { return [] }
        msgItemDone[index] = true
        let fullText = msgTextBuf[index] ?? ""
        let msgID = "msg_\(responseID)_\(index)"
        var out: [Data] = []
        out.append(contentsOf: emitEvent(
            "response.output_text.done",
            payload: [
                "type": "response.output_text.done",
                "item_id": msgID,
                "output_index": index,
                "content_index": 0,
                "text": fullText,
                "logprobs": [],
            ]
        ))
        out.append(contentsOf: emitEvent(
            "response.content_part.done",
            payload: [
                "type": "response.content_part.done",
                "item_id": msgID,
                "output_index": index,
                "content_index": 0,
                "part": ["type": "output_text", "annotations": [], "logprobs": [], "text": fullText],
            ]
        ))
        let item: [String: Any] = [
            "id": msgID,
            "type": "message",
            "content": [["type": "output_text", "annotations": [], "logprobs": [], "text": fullText]],
            "role": "assistant",
        ]
        out.append(contentsOf: emitEvent(
            "response.output_item.done",
            payload: [
                "type": "response.output_item.done",
                "output_index": index,
                "item": item,
            ]
        ))
        completedOutputItems.append((index, item, seq))
        return out
    }

    private func closeToolCall(index: Int, recordAsCompleted: Bool = true) -> [Data] {
        guard let callID = funcCallIDs[index], funcItemDone[index] != true else { return [] }
        funcItemDone[index] = true
        let args = funcArgsBuf[index] ?? "{}"
        let name = funcNames[index] ?? ""
        let outputIndex = toolOutputIndex(index)
        var out: [Data] = []
        out.append(contentsOf: emitEvent(
            "response.function_call_arguments.done",
            payload: [
                "type": "response.function_call_arguments.done",
                "item_id": "fc_\(callID)",
                "output_index": outputIndex,
                "arguments": args,
            ]
        ))
        let item: [String: Any] = [
            "id": "fc_\(callID)",
            "type": "function_call",
            "arguments": args,
            "call_id": callID,
            "name": name,
            "status": "completed",
        ]
        out.append(contentsOf: emitEvent(
            "response.output_item.done",
            payload: [
                "type": "response.output_item.done",
                "output_index": outputIndex,
                "item": item,
            ]
        ))
        if recordAsCompleted {
            completedOutputItems.append((outputIndex, item, seq))
        }
        return out
    }

    private func sendCompletedIfNeeded() -> [Data] {
        guard !completedSent else { return [] }
        completedSent = true
        var out: [Data] = []
        let output = completedOutputItems
            .sorted {
                if $0.outputIndex != $1.outputIndex { return $0.outputIndex < $1.outputIndex }
                return $0.seq < $1.seq
            }
            .map(\.item)
        var response = baseResponse(status: "completed")
        response["output"] = output
        if let usage {
            response["usage"] = ResponsesUsageMapper.map(usage)
        }
        out.append(contentsOf: emitEvent(
            "response.completed",
            payload: [
                "type": "response.completed",
                "response": response,
            ]
        ))
        return out
    }

    private func baseResponse(status: String) -> [String: Any] {
        var response: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": created,
            "status": status,
            "background": false,
            "error": NSNull(),
            "output": [],
        ]
        if let model {
            response["model"] = model
        }
        return response
    }

    private func toolOutputIndex(_ tcIndex: Int) -> Int {
        reasoningID != nil ? reasoningIndex + 1 + tcIndex : tcIndex
    }

    private func emitEvent(_ type: String, payload: [String: Any]) -> [Data] {
        seq += 1
        var data = payload
        data["sequence_number"] = seq
        guard let json = try? JSONSerialization.data(withJSONObject: data) else { return [] }
        return [Data("event: \(type)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)]
    }
}

/// Chat usage → Responses usage 字段名映射。
enum ResponsesUsageMapper {
    static func map(_ usage: [String: Any]) -> [String: Any] {
        let input = (usage["prompt_tokens"] as? Int) ?? 0
        let output = (usage["completion_tokens"] as? Int) ?? 0
        var result: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "total_tokens": (usage["total_tokens"] as? Int) ?? (input + output),
        ]
        if let details = usage["prompt_tokens_details"] as? [String: Any],
           let cached = details["cached_tokens"] as? Int,
           cached > 0 {
            result["input_tokens_details"] = ["cached_tokens": cached]
        }
        if let details = usage["completion_tokens_details"] as? [String: Any],
           let reasoning = details["reasoning_tokens"] as? Int,
           reasoning > 0 {
            result["output_tokens_details"] = ["reasoning_tokens": reasoning]
        }
        return result
    }
}
