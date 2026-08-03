import Foundation
import CryptoKit
import zlib

// MARK: - 极简 protobuf 编码

/// Cursor 私有协议用到的极简 protobuf wire 编码。
///
/// 参考 `eisbaw/cursor_api_demo`（逆向 Cursor IDE 后端协议）：
/// - 请求：`StreamUnifiedChatWithToolsRequest`，外层 `Request`（field 1）嵌套；
/// - 响应：`StreamUnifiedChatResponseWithTools`（field 2 → `StreamUnifiedChatResponse`，
///   field 1 = text，field 25 = thinking）；
/// - 帧格式：`1 字节类型 + 4 字节大端长度 + 载荷`（gRPC/Connect 风格）。
enum CursorProto {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while true {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            out.append(byte)
            if value == 0 { break }
        }
        return out
    }

    static func tag(_ field: Int, _ wire: Int) -> Data {
        varint(UInt64((field << 3) | wire))
    }

    static func varintField(_ field: Int, _ value: UInt64) -> Data {
        tag(field, 0) + varint(value)
    }

    static func bytesField(_ field: Int, _ value: Data) -> Data {
        tag(field, 2) + varint(UInt64(value.count)) + value
    }

    static func stringField(_ field: Int, _ value: String) -> Data {
        bytesField(field, Data(value.utf8))
    }

    static func messageField(_ field: Int, _ message: Data) -> Data {
        bytesField(field, message)
    }
}

/// 极简 protobuf 解码：迭代消息中的 `(field, wire, 载荷)`。
enum CursorProtoDecoder {
    struct Field {
        let number: Int
        let wire: Int
        let payload: Data
        let varint: UInt64
    }

    static func fields(in data: Data) -> [Field] {
        var result: [Field] = []
        var index = data.startIndex
        while index < data.endIndex {
            guard let (tag, next) = decodeVarint(data, from: index) else { break }
            let number = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            var cursor = next
            switch wire {
            case 0: // varint
                guard let (value, after) = decodeVarint(data, from: cursor) else { return result }
                result.append(Field(number: number, wire: wire, payload: Data(), varint: value))
                cursor = after
            case 2: // length-delimited
                guard let (len, after) = decodeVarint(data, from: cursor) else { return result }
                let start = after
                let end = min(start + Int(len), data.endIndex)
                guard end <= data.endIndex else { return result }
                result.append(Field(number: number, wire: wire, payload: data.subdata(in: start..<end), varint: 0))
                cursor = end
            case 1: // 64-bit fixed
                cursor = min(cursor + 8, data.endIndex)
            case 5: // 32-bit fixed
                cursor = min(cursor + 4, data.endIndex)
            default:
                return result
            }
            index = cursor
        }
        return result
    }

    /// 取指定 field 的字符串（length-delimited）。
    static func string(_ field: Int, in message: Data) -> String? {
        for f in fields(in: message) where f.number == field && f.wire == 2 {
            return String(data: f.payload, encoding: .utf8)
        }
        return nil
    }

    /// 取指定 field 的子消息。
    static func message(_ field: Int, in message: Data) -> Data? {
        fields(in: message).first { $0.number == field && $0.wire == 2 }?.payload
    }

    static func decodeVarint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < data.endIndex && shift < 70 {
            let byte = data[index]
            result |= UInt64(byte & 0x7f) << shift
            index += 1
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
        }
        return nil
    }
}

// MARK: - 请求编码

/// 构建 `StreamUnifiedChatWithTools` 请求体（含帧头）。
///
/// 采用当前 Cursor 后端实际使用的 schema（`zhengui666/cursor-api-gui/lite.proto`，
/// 2025-11 逆向，与 `Jordan-Jarvis/cursor-grpc` 字段号不同）：
/// - 顶层 `StreamUnifiedChatRequestWithTools.field 1` = `StreamUnifiedChatRequest`；
/// - 对话：`conversation(1)` 数组，`ConversationMessage{ text=1, type=2 }`（HUMAN=1 / AI=2）；
/// - 模型：`model_details(5)` → `ModelDetails.model_name(1)`；
/// - `is_chat(22)=true`、`conversation_id(23)` 为 UUID。
///
/// 实测确认：早期 `eisbaw/cursor_api_demo` 的扁平 schema（model 在 field 5）与
/// `Jordan-Jarvis` 字段号（conversation=2 / model_details=7）均不被当前后端接受。
/// system 消息转成 user 消息前置 `[System Instructions]`。
enum CursorChatRequestEncoder {
    static func makeBody(messages: [(role: String, content: String)], model: String) -> Data {
        // StreamUnifiedChatRequest
        var req = Data()
        for (role, content) in messages {
            var message = CursorProto.stringField(1, content)
            message += CursorProto.varintField(2, role == "assistant" ? 2 : 1)  // HUMAN=1 / AI=2
            req += CursorProto.messageField(1, message)  // conversation
        }
        // model_details.model_name
        var modelDetails = CursorProto.stringField(1, model)
        req += CursorProto.messageField(5, modelDetails)
        // is_chat = true / conversation_id = UUID
        req += CursorProto.varintField(22, 1)
        req += CursorProto.stringField(23, UUID().uuidString.lowercased())

        // 顶层：StreamUnifiedChatRequestWithTools.field 1 = StreamUnifiedChatRequest
        let outer = CursorProto.messageField(1, req)
        // 帧头：1 字节类型（0x00 未压缩）+ 4 字节大端长度
        var body = Data()
        body.append(0x00)
        body.append(contentsOf: UInt32(outer.count).bigEndianBytes)
        body.append(outer)
        return body
    }

    static func timestampString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - 帧解码

/// Cursor 流式帧（`1 字节类型 + 4 字节大端长度 + 载荷`）。
struct CursorFrame {
    let type: UInt8
    let payload: Data

    /// 0x00/0x01 = protobuf；0x02/0x03 = JSON；奇数位含 gzip。
    var isGzipped: Bool { type == 0x01 || type == 0x03 }
}

/// 有状态帧解析器（跨网络 chunk 累积）。
struct CursorFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [CursorFrame] {
        buffer.append(data)
        var frames: [CursorFrame] = []
        while buffer.count >= 5 {
            let type = buffer[buffer.startIndex]
            let len = Int(
                UInt32(buffer[buffer.startIndex + 1]) << 24
                    | UInt32(buffer[buffer.startIndex + 2]) << 16
                    | UInt32(buffer[buffer.startIndex + 3]) << 8
                    | UInt32(buffer[buffer.startIndex + 4])
            )
            guard buffer.count >= 5 + len else { break }
            let start = buffer.startIndex + 5
            let payload = buffer.subdata(in: start..<(start + len))
            frames.append(CursorFrame(type: type, payload: payload))
            buffer.removeSubrange(buffer.startIndex..<(start + len))
        }
        return frames
    }
}

// MARK: - 响应解码

/// 解码后的聊天事件。
enum CursorChatEvent {
    case text(String)
    case thinking(String)
    /// 流结束（服务端 `{}` JSON 帧）。
    case end
}

/// 把帧载荷解码为聊天事件。
enum CursorChatResponseDecoder {
    static func decode(frame: CursorFrame) -> [CursorChatEvent] {
        var payload = frame.payload
        if frame.isGzipped {
            guard let inflated = gunzip(payload) else { return [] }
            payload = inflated
        }
        // JSON 帧
        if frame.type == 0x02 || frame.type == 0x03 {
            guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return [] }
            if json.isEmpty { return [.end] }
            if let error = json["error"] {
                // error 可能是字符串或对象（{code, message, details}）
                if let string = error as? String, !string.isEmpty {
                    return [.text(string)]
                }
                if let dict = error as? [String: Any] {
                    if let message = dict["message"] as? String, !message.isEmpty {
                        return [.text(message)]
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: dict),
                       let text = String(data: data, encoding: .utf8) {
                        return [.text(text)]
                    }
                }
            }
            return []
        }
        // protobuf 帧：StreamUnifiedChatResponseWithTools.field 2 → StreamUnifiedChatResponse
        guard let chat = CursorProtoDecoder.message(2, in: payload) else { return [] }
        if let text = CursorProtoDecoder.string(1, in: chat), !text.isEmpty {
            return [.text(text)]
        }
        if let thinking = CursorProtoDecoder.message(25, in: chat),
           let text = CursorProtoDecoder.string(1, in: thinking) ?? CursorProtoDecoder.string(2, in: thinking),
           !text.isEmpty {
            return [.thinking(text)]
        }
        return []
    }
}

// MARK: - 二进制流 → OpenAI SSE

/// 把 Cursor 二进制帧流转成 OpenAI SSE chunk 流。
struct CursorSSEProcessor {
    private var frames = CursorFrameDecoder()
    private(set) var finished = false

    let id: String
    let model: String
    let created: Int

    init(model: String) {
        self.id = "chatcmpl-cursor-\(UUID().uuidString)"
        self.model = model
        self.created = Int(Date().timeIntervalSince1970)
    }

    mutating func consume(_ data: Data) -> [Data] {
        guard !finished else { return [] }
        var out: [Data] = []
        for frame in frames.append(data) {
            if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil {
                let payloadPreview = String(data: frame.payload, encoding: .utf8) ?? frame.payload.map { String(format: "%02x", $0) }.joined()
                CursorDebug.log("frame type=\(frame.type) len=\(frame.payload.count) payload=\(payloadPreview.prefix(600))")
            }
            for event in CursorChatResponseDecoder.decode(frame: frame) {
                switch event {
                case .text(let text):
                    if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil {
                        CursorDebug.log("event text=\(text.prefix(200))")
                    }
                    out.append(Self.chunk(id: id, model: model, created: created, delta: ["content": text]))
                case .thinking(let text):
                    out.append(Self.chunk(id: id, model: model, created: created, delta: ["reasoning_content": text]))
                case .end:
                    finished = true
                    out.append(Self.doneChunk())
                    return out
                }
            }
        }
        return out
    }

    var doneChunkData: Data { Self.doneChunk() }

    static func chunk(id: String, model: String, created: Int, delta: [String: Any]) -> Data {
        let object: [String: Any] = [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [
                ["index": 0, "delta": delta, "finish_reason": NSNull()]
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    static func doneChunk() -> Data {
        Data("data: [DONE]\n\n".utf8)
    }
}

// MARK: - gzip 解压（zlib，系统库）

/// gzip/zlib 解压。`windowBits = 15 + 32` 自动识别 gzip/zlib 头；
/// 若失败再尝试裸 deflate（windowBits = -15）。
func gunzip(_ data: Data) -> Data? {
    if let result = inflate(data, windowBits: 15 + 32) { return result }
    return inflate(data, windowBits: -15)
}

private func inflate(_ data: Data, windowBits: Int32) -> Data? {
    guard !data.isEmpty else { return nil }
    var stream = z_stream()
    let initStatus = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int32 in
        guard let base = src.baseAddress else { return Z_DATA_ERROR }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(data.count)
        return inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }
    guard initStatus == Z_OK else { return nil }
    defer { inflateEnd(&stream) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let status = buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int32 in
            guard let base = dst.baseAddress else { return Z_DATA_ERROR }
            stream.next_out = base.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(dst.count)
            return inflate(&stream, Z_NO_FLUSH)
        }
        if status != Z_OK && status != Z_STREAM_END {
            return nil
        }
        let produced = buffer.count - Int(stream.avail_out)
        if produced > 0 {
            output.append(contentsOf: buffer[0..<produced])
        }
        if status == Z_STREAM_END {
            break
        }
        if stream.avail_out != 0 {
            // 输入耗尽但未到流末尾 → 异常
            return nil
        }
    }
    return output
}

// MARK: - 杂项

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8((self >> 24) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 8) & 0xff), UInt8(self & 0xff)]
    }
}

/// Cursor RPC 调试日志（`CURSOR_DEBUG` 环境变量开启，输出到 stderr）。
enum CursorDebug {
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[cursor-debug] \(message)\n".utf8))
    }
}

/// Cursor 头部辅助（sha256 client-key、uuidv5 session-id）。
enum CursorHeaderHelper {
    /// `x-client-key`：access token 的 SHA256 十六进制。
    static func clientKey(token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `x-session-id`：UUID v5（DNS 命名空间 + token）。
    static func sessionID(token: String) -> String {
        let namespace = Data([0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8])
        var input = Data()
        input.append(namespace)
        input.append(Data(token.utf8))
        let digest = Data(Insecure.SHA1.hash(data: input))
        var bytes = [UInt8](digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
    }
}
