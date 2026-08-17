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
    private let toolIdentity: ResponsesToolIdentityMap
    private let emitStartEventsEnabled: Bool
    private let created: Int
    private var parser = SSEParser()

    private var seq = 0
    private var started = false
    private var completedSent = false
    private var model: String?
    private var usage: [String: Any]?

    // message item 状态（按输出 index）
    private var msgItemAdded: [Int: Bool] = [:]
    private var msgContentCount: [Int: Int] = [:]
    private var msgTextContentIndex: [Int: Int] = [:]
    private var msgImageParts: [Int: [(index: Int, part: [String: Any])]] = [:]
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

    public init(
        responseID: String,
        toolIdentity: ResponsesToolIdentityMap = ResponsesToolIdentityMap(),
        emitStartEventsEnabled: Bool = true
    ) {
        self.responseID = responseID
        self.toolIdentity = toolIdentity
        self.emitStartEventsEnabled = emitStartEventsEnabled
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
        // 某些上游会在首个文本 chunk 上提前携带 finish_reason，
        // 但后续仍会继续发送文本 delta。必须先消费完整上游流，再关闭 output item；
        // 否则 Codex 收到 output_text.done 后会忽略后续 delta，只显示首个片段。
        out.append(contentsOf: closeOpenOutputItems())
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
            // 尾随 usage-only chunk 不能视为真正结束：部分上游会在它之后继续发送文本。
            // 统一等到上游 EOF（finish()）再关闭 output item 并发送 response.completed。
            return []
        }

        var out: [Data] = []
        if !started {
            started = true
            if emitStartEventsEnabled {
                out.append(contentsOf: emitStartEvents())
            }
        }

        let index = (choice["index"] as? Int) ?? 0
        let delta = (choice["delta"] as? [String: Any]) ?? [:]

        if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty {
            out.append(contentsOf: startReasoning(index: index))
            out.append(contentsOf: emitReasoningDelta(reasoning))
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            out.append(contentsOf: processTextDelta(content, index: index))
        } else if let parts = delta["content"] as? [[String: Any]], !parts.isEmpty {
            for part in parts {
                switch part["type"] as? String {
                case "text", "input_text", "output_text":
                    if let text = part["text"] as? String, !text.isEmpty {
                        out.append(contentsOf: processTextDelta(text, index: index))
                    }
                case "image_url":
                    let imageURL = Self.imageURL(from: part["image_url"])
                    if !imageURL.isEmpty {
                        out.append(contentsOf: processImageDelta(imageURL, index: index))
                    }
                default:
                    if let text = part["text"] as? String, !text.isEmpty {
                        out.append(contentsOf: processTextDelta(text, index: index))
                    }
                }
            }
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
                                "item": toolCallItem(id: "fc_\(callID)", callID: callID, wireName: toolName, arguments: "", status: "in_progress"),
                            ]
                        ))
                    }
                    if !args.isEmpty {
                        funcArgsBuf[tcIndex] = ToolCallArgumentDelta.append(
                            existing: funcArgsBuf[tcIndex],
                            incoming: args
                        )
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

        // 上游可能在 finish_reason 后继续发送文本 delta（尤其 CodeBuddy 会在首块
        // 提前携带 finish_reason）。因此不在这里关闭 output item 或发送 completed：
        // 过早发出 output_text.done 会让 Codex 丢弃后续内容。统一延迟到上游 EOF
        // （finish()）再关闭并补发 response.completed，即使该 chunk 已带 usage 也不提前结束。
        return out
    }

    private func processTextDelta(_ content: String, index: Int) -> [Data] {
        var out: [Data] = []
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
        if msgTextContentIndex[msgIndex] == nil {
            let partIndex = msgContentCount[msgIndex] ?? 0
            msgTextContentIndex[msgIndex] = partIndex
            msgContentCount[msgIndex] = partIndex + 1
            let msgID = "msg_\(responseID)_\(msgIndex)"
            out.append(contentsOf: emitEvent(
                "response.content_part.added",
                payload: [
                    "type": "response.content_part.added",
                    "item_id": msgID,
                    "output_index": msgIndex,
                    "content_index": partIndex,
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
                "content_index": msgTextContentIndex[msgIndex] ?? 0,
                "delta": content,
                "logprobs": [],
            ]
        ))
        return out
    }

    private func processImageDelta(_ imageURL: String, index: Int) -> [Data] {
        var out: [Data] = []
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
        let partIndex = msgContentCount[msgIndex] ?? 0
        msgContentCount[msgIndex] = partIndex + 1
        let msgID = "msg_\(responseID)_\(msgIndex)"
        msgImageParts[msgIndex, default: []].append((
            index: partIndex,
            part: [
                "type": "output_image",
                "image_url": imageURL,
                "annotations": [],
            ]
        ))
        out.append(contentsOf: emitEvent(
            "response.content_part.added",
            payload: [
                "type": "response.content_part.added",
                "item_id": msgID,
                "output_index": msgIndex,
                "content_index": partIndex,
                "part": ["type": "output_image", "image_url": imageURL, "annotations": []],
            ]
        ))
        out.append(contentsOf: emitEvent(
            "response.output_image.delta",
            payload: [
                "type": "response.output_image.delta",
                "item_id": msgID,
                "output_index": msgIndex,
                "content_index": partIndex,
                "delta": ["image_url": imageURL],
            ]
        ))
        return out
    }

    private static func imageURL(from value: Any?) -> String {
        if let string = value as? String { return string }
        if let obj = value as? [String: Any] { return obj["url"] as? String ?? "" }
        return ""
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
                "content_index": msgTextContentIndex[index] ?? 0,
                "part": ["type": "output_text", "annotations": [], "logprobs": [], "text": fullText],
            ]
        ))
        var contentParts: [(index: Int, part: [String: Any])] = []
        if let textIndex = msgTextContentIndex[index] {
            contentParts.append((
                index: textIndex,
                part: ["type": "output_text", "annotations": [], "logprobs": [], "text": fullText]
            ))
        }
        if let images = msgImageParts[index], !images.isEmpty {
            for image in images {
                out.append(contentsOf: emitEvent(
                    "response.output_image.done",
                    payload: [
                        "type": "response.output_image.done",
                        "item_id": msgID,
                        "output_index": index,
                        "content_index": image.index,
                        "image": image.part,
                    ]
                ))
            }
            contentParts.append(contentsOf: images)
        }
        contentParts.sort { $0.index < $1.index }
        let item: [String: Any] = [
            "id": msgID,
            "type": "message",
            "content": contentParts.map(\.part),
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
        let item = toolCallItem(
            id: "fc_\(callID)",
            callID: callID,
            wireName: name,
            arguments: args,
            status: "completed"
        )
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

    /// function_call item：namespace 子工具还原 leaf 名并补 `namespace` 字段（F2）。
    private func toolCallItem(
        id: String,
        callID: String,
        wireName: String,
        arguments: String,
        status: String
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": id,
            "type": "function_call",
            "arguments": arguments,
            "call_id": callID,
            "name": wireName,
            "status": status,
        ]
        if let identity = toolIdentity.identity(forWireName: wireName) {
            item["name"] = identity.name
            item["namespace"] = identity.namespace
        }
        return item
    }

    /// 在完整上游流结束后关闭尚未完成的 Responses output item。
    private func closeOpenOutputItems() -> [Data] {
        var out: [Data] = []
        for index in msgItemAdded.keys.sorted() {
            out.append(contentsOf: closeMessage(index: index))
        }
        out.append(contentsOf: closeReasoning())
        for index in funcCallIDs.keys.sorted() {
            out.append(contentsOf: closeToolCall(index: index))
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
