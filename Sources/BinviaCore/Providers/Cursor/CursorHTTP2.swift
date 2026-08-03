import Foundation
import Network

// MARK: - Cursor Agent HTTP/2（最小双向 Connect-RPC 传输层）

/// HTTP/2 帧。
struct CursorHTTP2Frame: Sendable {
    let type: UInt8
    let flags: UInt8
    let streamID: UInt32
    let payload: Data
}

/// HTTP/2 传输错误。
enum CursorHTTP2Error: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case unexpectedEOF
    case frameTooLarge(Int)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): return "Cursor HTTP/2 连接失败：\(message)"
        case .unexpectedEOF: return "Cursor HTTP/2 连接意外断开"
        case .frameTooLarge(let length): return "Cursor HTTP/2 帧过大：\(length) bytes"
        case .protocolError(let message): return "Cursor HTTP/2 协议错误：\(message)"
        }
    }
}

/// HPACK 静态表编码器。
///
/// 请求头全部使用「literal without indexing」，避免维护动态表；伪头中
/// `POST` 和 `https` 直接使用静态索引。Cursor 服务端接受这种合法的 HPACK 编码。
enum CursorHPACK {
    private static let names: [String] = [
        ":authority", ":method", ":method", ":path", ":path", ":scheme", ":scheme", ":status",
        ":status", ":status", ":status", ":status", ":status", ":status", "accept-charset",
        "accept-encoding", "accept-language", "accept-ranges", "accept", "access-control-allow-origin",
        "age", "allow", "authorization", "cache-control", "content-disposition", "content-encoding",
        "content-language", "content-length", "content-location", "content-range", "content-type",
        "cookie", "date", "etag", "expect", "expires", "from", "host", "if-match",
        "if-modified-since", "if-none-match", "if-range", "if-unmodified-since", "last-modified",
        "link", "location", "max-forwards", "proxy-authenticate", "proxy-authorization", "range",
        "referer", "refresh", "retry-after", "server", "set-cookie", "strict-transport-security",
        "transfer-encoding", "user-agent", "vary", "via", "www-authenticate",
    ]

    /// 返回静态表中指定名称的第一个索引。
    private static func nameIndex(_ name: String) -> Int? {
        names.firstIndex(of: name).map { $0 + 1 }
    }

    /// HPACK 整数编码。
    private static func integer(_ value: Int, prefixBits: Int, prefix: UInt8) -> Data {
        let limit = (1 << prefixBits) - 1
        if value < limit {
            return Data([prefix | UInt8(value)])
        }
        var output = Data([prefix | UInt8(limit)])
        var remaining = value - limit
        while remaining >= 128 {
            output.append(UInt8((remaining & 0x7f) | 0x80))
            remaining >>= 7
        }
        output.append(UInt8(remaining))
        return output
    }

    /// HPACK 原始字符串（不使用 Huffman，避免动态表/解码器依赖）。
    private static func string(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return integer(bytes.count, prefixBits: 7, prefix: 0) + bytes
    }

    /// 编码一个请求头。
    private static func field(name: String, value: String) -> Data {
        // POST 与 https 的完整静态索引，减少伪头编码复杂度。
        if name == ":method", value == "POST" { return Data([0x83]) }
        if name == ":scheme", value == "https" { return Data([0x87]) }

        // literal without indexing，4-bit name index。
        if let index = nameIndex(name) {
            return integer(index, prefixBits: 4, prefix: 0) + string(value)
        }
        return string(name).prepending(0x00) + string(value)
    }

    static func encode(_ headers: [(String, String)]) -> Data {
        headers.reduce(into: Data()) { result, header in
            result.append(field(name: header.0.lowercased(), value: header.1))
        }
    }
}

private extension Data {
    func prepending(_ byte: UInt8) -> Data {
        Data([byte]) + self
    }
}

/// HTTP/2 双向连接。
///
/// `NWConnection` 负责 TCP/TLS，并自动协商 HTTP/2；本类型只实现 HTTP/2
/// 连接前奏、SETTINGS、HEADERS、DATA、PING、WINDOW_UPDATE 和帧解析。
final class CursorHTTP2Client: @unchecked Sendable {
    private static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    private static let maxFrameLength = 16 * 1024 * 1024

    private let connection: NWConnection
    private let sendLock = NSLock()
    private let queue = DispatchQueue(label: "binvia.cursor.http2", qos: .utility)

    init(host: String, port: UInt16 = 443) {
        let tls = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: tls)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    /// 建立连接，发送请求头和初始 Connect-RPC 帧，并开始接收 HTTP/2 帧。
    func start(
        headers: [(String, String)],
        body: Data
    ) async throws -> AsyncThrowingStream<CursorHTTP2Frame, Error> {
        try await waitUntilReady()

        let settings = Self.makeFrame(type: 0x04, flags: 0, streamID: 0, payload: Data())
        let encodedHeaders = CursorHPACK.encode(headers)
        let headerFrame = Self.makeFrame(type: 0x01, flags: 0x04, streamID: 1, payload: encodedHeaders)
        // 不设置 END_STREAM：AgentService/Run 要求后续在同一 HTTP/2 流写回 ack。
        let dataFrame = Self.makeFrame(type: 0x00, flags: 0, streamID: 1, payload: body)
        if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil {
            CursorDebug.log("agent h2 send preface/settings/headers/data headers=\(encodedHeaders.count) body=\(body.count)")
        }
        send(Self.preface + settings + headerFrame + dataFrame)

        let reader = CursorHTTP2Reader(connection: connection, queue: queue)
        return reader.start()
    }

    /// 在同一 HTTP/2 流上写回 Connect-RPC 数据。
    func sendData(_ data: Data, endStream: Bool = false) {
        let flags: UInt8 = endStream ? 0x01 : 0
        send(Self.makeFrame(type: 0x00, flags: flags, streamID: 1, payload: data))
    }

    /// 回 SETTINGS ACK。
    func acknowledgeSettings() {
        send(Self.makeFrame(type: 0x04, flags: 0x01, streamID: 0, payload: Data()))
    }

    /// 回 PING ACK。
    func acknowledgePing(_ payload: Data) {
        send(Self.makeFrame(type: 0x06, flags: 0x01, streamID: 0, payload: payload))
    }

    /// 归还 HTTP/2 流量窗口，避免长回复在 64 KiB 后停住。
    func acknowledgeReceivedBytes(_ count: Int, streamID: UInt32 = 1) {
        guard count > 0, count <= 0x7fff_ffff else { return }
        let increment = UInt32(count)
        let payload = Data([
            UInt8((increment >> 24) & 0x7f),
            UInt8((increment >> 16) & 0xff),
            UInt8((increment >> 8) & 0xff),
            UInt8(increment & 0xff),
        ])
        send(Self.makeFrame(type: 0x08, flags: 0, streamID: streamID, payload: payload))
        if streamID != 0 {
            send(Self.makeFrame(type: 0x08, flags: 0, streamID: 0, payload: payload))
        }
    }

    /// 主动关闭连接。
    func cancel() {
        connection.cancel()
    }

    private func waitUntilReady() async throws {
        let gate = CursorHTTP2ReadyGate()
        connection.stateUpdateHandler = { [gate] state in
            switch state {
            case .ready:
                if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil { CursorDebug.log("agent h2 ready") }
                gate.succeed()
            case .failed(let error):
                if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil { CursorDebug.log("agent h2 failed: \(error)") }
                gate.fail(CursorHTTP2Error.connectionFailed(error.localizedDescription))
            case .cancelled:
                if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil { CursorDebug.log("agent h2 cancelled") }
                gate.fail(CursorHTTP2Error.unexpectedEOF)
            default:
                break
            }
        }
        connection.start(queue: queue)
        try await gate.wait()
    }

    private func send(_ data: Data) {
        sendLock.lock()
        defer { sendLock.unlock() }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private static func makeFrame(type: UInt8, flags: UInt8, streamID: UInt32, payload: Data) -> Data {
        let length = payload.count
        var frame = Data([
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
            type,
            flags,
            UInt8((streamID >> 24) & 0x7f),
            UInt8((streamID >> 16) & 0xff),
            UInt8((streamID >> 8) & 0xff),
            UInt8(streamID & 0xff),
        ])
        frame.append(payload)
        return frame
    }

    fileprivate static var frameLimit: Int { maxFrameLength }
}

private final class CursorHTTP2ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func succeed() { resolve(.success(())) }

    func fail(_ error: Error) { resolve(.failure(error)) }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class CursorHTTP2Reader: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var buffer = Data()
    private var continuation: AsyncThrowingStream<CursorHTTP2Frame, Error>.Continuation?
    private var finished = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() -> AsyncThrowingStream<CursorHTTP2Frame, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            // 由 continuation 持有 reader，确保返回 stream 后接收循环仍然存活。
            continuation.onTermination = { [self] _ in
                self.finish()
            }
            self.receiveNext()
        }
    }

    private func receiveNext() {
        stateLock.lock()
        let active = !finished
        stateLock.unlock()
        guard active else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil { CursorDebug.log("agent h2 received bytes=\(data.count)") }
                self.buffer.append(data)
                do {
                    try self.drainFrames()
                } catch {
                    self.finish(throwing: error)
                    return
                }
            }
            if let error {
                self.finish(throwing: error)
            } else if isComplete {
                self.finish(throwing: CursorHTTP2Error.unexpectedEOF)
            } else {
                self.receiveNext()
            }
        }
    }

    private func drainFrames() throws {
        while buffer.count >= 9 {
            let length = Int(buffer[buffer.startIndex]) << 16
                | Int(buffer[buffer.startIndex + 1]) << 8
                | Int(buffer[buffer.startIndex + 2])
            guard length <= CursorHTTP2Client.frameLimit else {
                throw CursorHTTP2Error.frameTooLarge(length)
            }
            guard buffer.count >= 9 + length else { return }
            let type = buffer[buffer.startIndex + 3]
            let flags = buffer[buffer.startIndex + 4]
            let streamID = (UInt32(buffer[buffer.startIndex + 5]) << 24)
                | (UInt32(buffer[buffer.startIndex + 6]) << 16)
                | (UInt32(buffer[buffer.startIndex + 7]) << 8)
                | UInt32(buffer[buffer.startIndex + 8])
            let payload = buffer.subdata(in: buffer.startIndex + 9 ..< buffer.startIndex + 9 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 9 + length)
            if RouteConfig.envValue(["CURSOR_DEBUG"]) != nil {
                CursorDebug.log("agent h2 frame type=\(type) flags=\(flags) stream=\(streamID & 0x7fff_ffff) len=\(length)")
            }
            continuation?.yield(CursorHTTP2Frame(type: type, flags: flags, streamID: streamID & 0x7fff_ffff, payload: payload))
        }
    }

    private func finish(throwing error: Error? = nil) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
