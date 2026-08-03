import Foundation

// MARK: - Cursor agent.v1.AgentService/Run

/// Agent RPC 使用的模型解析结果。
private struct CursorAgentModel {
    let modelID: String
    let parameters: [(id: String, value: String)]

    static func resolve(_ model: String) -> CursorAgentModel {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized == "auto" {
            return CursorAgentModel(modelID: "default", parameters: [])
        }
        if normalized.hasPrefix("composer-"), normalized.hasSuffix("-fast") {
            return CursorAgentModel(
                modelID: String(normalized.dropLast("-fast".count)),
                parameters: [("fast", "true")]
            )
        }
        for suffix in ["low", "medium", "high", "xhigh", "max"] {
            let marker = "-\(suffix)"
            if normalized.hasPrefix("claude-"), normalized.hasSuffix(marker), normalized.count > marker.count {
                return CursorAgentModel(
                    modelID: String(normalized.dropLast(marker.count)),
                    parameters: [("effort", suffix)]
                )
            }
            if normalized.hasPrefix("gpt-"), normalized.hasSuffix(marker), normalized.count > marker.count {
                return CursorAgentModel(
                    modelID: String(normalized.dropLast(marker.count)),
                    parameters: [("reasoning", suffix)]
                )
            }
        }
        return CursorAgentModel(modelID: normalized, parameters: [])
    }
}

/// Cursor Agent RPC 的请求编码。
private enum CursorAgentRequestEncoder {
    static func makeBody(messages: [(role: String, content: String)], model: String) -> Data {
        let resolved = CursorAgentModel.resolve(model)
        let conversationID = UUID().uuidString.lowercased()
        let messageID = UUID().uuidString.lowercased()
        let userText = flatten(messages)

        // UserMessage { text, message_id, selected_context, mode=1 }。
        let userMessage = message(
            1,
            CursorProto.stringField(1, userText)
                + CursorProto.stringField(2, messageID)
                + CursorProto.messageField(3, Data())
                + CursorProto.varintField(4, 1)
        )
        // ConversationAction { user_message_action { user_message } }。
        let action = message(2, message(1, userMessage))
        // AgentRunRequest 的必要占位字段。
        let conversationState = message(1, Data())
        let requestedModel = message(
            9,
            CursorProto.stringField(1, resolved.modelID)
                + resolved.parameters.reduce(into: Data()) { result, parameter in
                    result += message(
                        3,
                        CursorProto.stringField(1, parameter.id)
                            + CursorProto.stringField(2, parameter.value)
                    )
                }
        )
        let modelDetails = message(
            3,
            CursorProto.stringField(1, resolved.modelID)
                + CursorProto.stringField(3, resolved.modelID)
                + CursorProto.stringField(4, resolved.modelID)
        )
        // mcp_tools 为空时也必须带占位字段。
        let mcpTools = message(4, Data())
        let runRequest = conversationState
            + action
            + modelDetails
            + mcpTools
            + CursorProto.stringField(5, conversationID)
            + requestedModel
            + CursorProto.varintField(12, 0)
            + CursorProto.stringField(16, conversationID)

        // AgentClientMessage { run_request }。
        let protobuf = message(1, runRequest)
        var framed = Data([0x00])
        framed.append(contentsOf: UInt32(protobuf.count).bigEndianBytes)
        framed.append(protobuf)
        return framed
    }

    private static func message(_ field: Int, _ payload: Data) -> Data {
        CursorProto.messageField(field, payload)
    }

    private static func flatten(_ messages: [(role: String, content: String)]) -> String {
        guard !messages.isEmpty else { return "" }
        if messages.count == 1, messages[0].role == "user" {
            return messages[0].content
        }
        return messages.map { message in
            switch message.role {
            case "assistant": return "Assistant: \(message.content)"
            case "tool": return "Tool result: \(message.content)"
            default: return "User: \(message.content)"
            }
        }.joined(separator: "\n\n")
    }
}

/// Agent 服务响应中关心的事件。
private enum CursorAgentEvent {
    case text(String)
    case thinking(String)
    case requestContext(id: UInt64, execID: String)
    case keyValueGet(id: UInt64, metadata: Data?)
    case keyValueSet(id: UInt64, metadata: Data?)
    case end
}

private enum CursorAgentResponseDecoder {
    static func events(from frame: CursorFrame) throws -> [CursorAgentEvent] {
        var payload = frame.payload
        if frame.isGzipped {
            guard let inflated = gunzip(payload) else {
                throw ProviderError.invalidResponse("Cursor Agent gzip 帧解压失败")
            }
            payload = inflated
        }

        // Connect-RPC JSON 错误/结束帧。
        if frame.type == 0x02 || frame.type == 0x03 {
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw ProviderError.invalidResponse("Cursor Agent JSON 帧无效")
            }
            if json.isEmpty { return [.end] }
            if let error = json["error"] as? [String: Any] {
                let code = error["code"] as? String
                let details = error["details"] as? [[String: Any]]
                let debug = details?.first?["debug"] as? [String: Any]
                let debugDetails = debug?["details"] as? [String: Any]
                let message = (debugDetails?["detail"] as? String)
                    ?? (debugDetails?["title"] as? String)
                    ?? (error["message"] as? String)
                    ?? "Cursor Agent 返回未知错误"
                let status = code == "resource_exhausted" ? 429 : 400
                throw ProviderError.upstreamError(statusCode: status, message: message)
            }
            return []
        }

        var output: [CursorAgentEvent] = []
        for top in CursorProtoDecoder.fields(in: payload) {
            switch top.number {
            case 1 where top.wire == 2:
                decodeInteraction(top.payload, into: &output)
            case 2 where top.wire == 2:
                if let event = decodeExec(top.payload) { output.append(event) }
            case 4 where top.wire == 2:
                if let event = decodeKeyValue(top.payload) { output.append(event) }
            default:
                continue
            }
        }
        return output
    }

    private static func decodeInteraction(_ payload: Data, into output: inout [CursorAgentEvent]) {
        for update in CursorProtoDecoder.fields(in: payload) {
            guard update.wire == 2 else {
                if update.number == 14 { output.append(.end) }
                continue
            }
            switch update.number {
            case 1:
                if let text = CursorProtoDecoder.string(1, in: update.payload), !text.isEmpty {
                    output.append(.text(text))
                }
            case 4:
                if let text = CursorProtoDecoder.string(1, in: update.payload), !text.isEmpty {
                    output.append(.thinking(text))
                }
            case 14:
                output.append(.end)
            default:
                continue
            }
        }
    }

    private static func decodeExec(_ payload: Data) -> CursorAgentEvent? {
        var id: UInt64 = 0
        var execID = ""
        var variant: CursorProtoDecoder.Field?
        for field in CursorProtoDecoder.fields(in: payload) {
            if field.number == 1, field.wire == 0 { id = field.varint }
            else if field.number == 15, field.wire == 2 { execID = String(data: field.payload, encoding: .utf8) ?? "" }
            else if field.wire == 2, variant == nil { variant = field }
        }
        guard let variant else { return nil }
        // request_context_args = 10。
        guard variant.number == 10 else { return nil }
        return .requestContext(id: id, execID: execID)
    }

    private static func decodeKeyValue(_ payload: Data) -> CursorAgentEvent? {
        var id: UInt64 = 0
        var metadata: Data?
        var isGet = false
        var isSet = false
        for field in CursorProtoDecoder.fields(in: payload) {
            switch field.number {
            case 1 where field.wire == 0: id = field.varint
            case 2 where field.wire == 2: isGet = true
            case 3 where field.wire == 2: isSet = true
            case 4 where field.wire == 2: metadata = field.payload
            default: continue
            }
        }
        if isGet { return .keyValueGet(id: id, metadata: metadata) }
        if isSet { return .keyValueSet(id: id, metadata: metadata) }
        return nil
    }
}

/// Agent RPC 的客户端回写消息编码。
private enum CursorAgentClientMessageEncoder {
    static func requestContext(id: UInt64, execID: String) -> Data {
        let requestContext = CursorProto.messageField(1, Data())
        let success = CursorProto.messageField(1, requestContext)
        let result = CursorProto.messageField(10, success)
        return frame(CursorProto.messageField(
            2,
            CursorProto.varintField(1, id)
                + CursorProto.stringField(15, execID)
                + result
        ))
    }

    static func keyValueGet(id: UInt64, data: Data, metadata: Data?) -> Data {
        let blobResult = CursorProto.messageField(1, CursorProto.bytesField(1, data))
        return keyValue(id: id, field: CursorProto.messageField(2, blobResult), metadata: metadata)
    }

    static func keyValueSet(id: UInt64, metadata: Data?) -> Data {
        return keyValue(id: id, field: CursorProto.messageField(3, Data()), metadata: metadata)
    }

    private static func keyValue(id: UInt64, field: Data, metadata: Data?) -> Data {
        var payload = CursorProto.varintField(1, id) + field
        if let metadata, !metadata.isEmpty {
            payload += CursorProto.bytesField(4, metadata)
        }
        return frame(CursorProto.messageField(3, payload))
    }

    private static func frame(_ payload: Data) -> Data {
        var result = Data([0x00])
        result.append(contentsOf: UInt32(payload.count).bigEndianBytes)
        result.append(payload)
        return result
    }
}

private enum CursorAgentSSE {
    static func role(id: String, model: String, created: Int) -> Data {
        chunk(id: id, model: model, created: created, delta: ["role": "assistant", "content": ""])
    }

    static func text(id: String, model: String, created: Int, content: String) -> Data {
        chunk(id: id, model: model, created: created, delta: ["content": content])
    }

    static func thinking(id: String, model: String, created: Int, content: String) -> Data {
        chunk(id: id, model: model, created: created, delta: ["reasoning_content": content])
    }

    static func finish(id: String, model: String, created: Int) -> Data {
        let object: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [["index": 0, "delta": [:], "finish_reason": "stop"]],
        ]
        return dataEvent(object)
    }

    static let done = Data("data: [DONE]\n\n".utf8)

    private static func chunk(id: String, model: String, created: Int, delta: [String: Any]) -> Data {
        let object: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]],
        ]
        return dataEvent(object)
    }

    private static func dataEvent(_ object: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }
}

private final class CursorAgentStreamState: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var client: CursorHTTP2Client?

    func set(task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func set(client: CursorHTTP2Client) {
        lock.lock(); defer { lock.unlock() }
        self.client = client
    }

    func cancel() {
        lock.lock()
        let task = self.task
        let client = self.client
        lock.unlock()
        task?.cancel()
        client?.cancel()
    }
}

/// Cursor Agent 双向 RPC → OpenAI SSE。
enum CursorAgentRPC {
    static let host = "agentn.global.api5.cursor.sh"
    static let clientVersion = "cli-2026.07.08-0c04a8a"

    static func stream(
        messages: [(role: String, content: String)],
        model: String,
        identity: CursorIDEIdentity
    ) -> AsyncThrowingStream<Data, Error> {
        let state = CursorAgentStreamState()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = CursorHTTP2Client(host: host)
                    state.set(client: client)
                    let requestBody = CursorAgentRequestEncoder.makeBody(messages: messages, model: model)
                    let requestID = UUID().uuidString.lowercased()
                    let traceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                        + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    let spanID = String(traceID.prefix(16))
                    let token = identity.accessToken.components(separatedBy: "::").last ?? identity.accessToken
                    let headers = [
                        (":method", "POST"),
                        (":path", "/agent.v1.AgentService/Run"),
                        (":scheme", "https"),
                        (":authority", host),
                        ("authorization", "Bearer \(token)"),
                        ("backend-traceparent", "00-\(traceID)-\(spanID)-01"),
                        ("connect-accept-encoding", "gzip"),
                        ("connect-protocol-version", "1"),
                        ("content-type", "application/connect+proto"),
                        ("traceparent", "00-\(traceID)-\(spanID)-01"),
                        ("user-agent", "connect-es/1.6.1"),
                        ("x-cursor-client-type", "cli"),
                        ("x-cursor-client-version", clientVersion),
                        ("x-ghost-mode", "true"),
                        ("x-original-request-id", requestID),
                        ("x-request-id", requestID),
                    ]
                    let http2Frames = try await client.start(headers: headers, body: requestBody)
                    var connectDecoder = CursorFrameDecoder()
                    var emittedRole = false
                    var finished = false
                    let responseID = "chatcmpl-cursor-\(UUID().uuidString)"
                    let created = Int(Date().timeIntervalSince1970)

                    for try await http2Frame in http2Frames {
                        try Task.checkCancellation()
                        switch http2Frame.type {
                        case 0x04: // SETTINGS
                            if http2Frame.flags & 0x01 == 0 { client.acknowledgeSettings() }
                        case 0x06: // PING
                            if http2Frame.flags & 0x01 == 0 { client.acknowledgePing(http2Frame.payload) }
                        case 0x00 where http2Frame.streamID == 1: // DATA
                            client.acknowledgeReceivedBytes(http2Frame.payload.count, streamID: 1)
                            for connectFrame in connectDecoder.append(http2Frame.payload) {
                                for event in try CursorAgentResponseDecoder.events(from: connectFrame) {
                                    switch event {
                                    case .text(let text):
                                        if !emittedRole {
                                            continuation.yield(CursorAgentSSE.role(id: responseID, model: model, created: created))
                                            emittedRole = true
                                        }
                                        continuation.yield(CursorAgentSSE.text(id: responseID, model: model, created: created, content: text))
                                    case .thinking(let text):
                                        if !emittedRole {
                                            continuation.yield(CursorAgentSSE.role(id: responseID, model: model, created: created))
                                            emittedRole = true
                                        }
                                        continuation.yield(CursorAgentSSE.thinking(id: responseID, model: model, created: created, content: text))
                                    case .requestContext(let id, let execID):
                                        client.sendData(CursorAgentClientMessageEncoder.requestContext(id: id, execID: execID))
                                    case .keyValueGet(let id, let metadata):
                                        client.sendData(CursorAgentClientMessageEncoder.keyValueGet(id: id, data: Data(), metadata: metadata))
                                    case .keyValueSet(let id, let metadata):
                                        client.sendData(CursorAgentClientMessageEncoder.keyValueSet(id: id, metadata: metadata))
                                    case .end:
                                        if !finished {
                                            if !emittedRole {
                                                continuation.yield(CursorAgentSSE.role(id: responseID, model: model, created: created))
                                            }
                                            continuation.yield(CursorAgentSSE.finish(id: responseID, model: model, created: created))
                                            continuation.yield(CursorAgentSSE.done)
                                            finished = true
                                        }
                                    }
                                }
                            }
                        case 0x03: // RST_STREAM
                            throw CursorHTTP2Error.protocolError("Cursor Agent 重置 HTTP/2 流")
                        case 0x07: // GOAWAY
                            throw CursorHTTP2Error.protocolError("Cursor Agent 关闭 HTTP/2 连接")
                        default:
                            continue
                        }
                        if finished { break }
                    }
                    if !finished {
                        throw CursorHTTP2Error.unexpectedEOF
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            state.set(task: task)
            continuation.onTermination = { _ in state.cancel() }
        }
    }
}
