import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// C 函数 `listen` 与 `SocketUtil.createListener(host:port:)` 方法名易混淆，模块内会被遮蔽；
// 这里显式别名指向系统版本。
#if canImport(Darwin)
private let sysListen: @Sendable (Int32, Int32) -> Int32 = Darwin.listen
#elseif canImport(Glibc)
private let sysListen: @Sendable (Int32, Int32) -> Int32 = Glibc.listen
#endif

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let queryItems: [String: String]
    public let headers: [String: String]
    public let body: Data?

    public init(method: String, path: String, queryItems: [String: String], headers: [String: String], body: Data?) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }

    public var authorizationToken: String? {
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            return String(auth.dropFirst(7))
        }
        return headers["x-api-key"]
    }
}

public enum HTTPBody: Sendable {
    case data(Data)
    case stream(AsyncThrowingStream<Data, Error>)
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: HTTPBody

    public init(status: Int, headers: [String: String], body: HTTPBody) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, object: some Encodable) throws -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(object)
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .data(data)
        )
    }

    public static func text(_ status: Int, _ text: String, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: ["Content-Type": contentType],
            body: .data(Data(text.utf8))
        )
    }
}

/// 本地代理服务器。借鉴 CodexBar `CLILocalHTTPServer`（原生 POSIX socket，零外部依赖）。
public final class HTTPServer: @unchecked Sendable {
    private let handlerLock = NSLock()
    private var handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let lifecycleLock = NSLock()
    private var stopped = false
    private var listenFD: Int32?

    public init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    /// 运行时替换 handler（配置热更新）。已在 accept 循环中运行的服务立即对新请求生效。
    public func setHandler(_ newHandler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        handler = newHandler
    }

    private func currentHandler() -> @Sendable (HTTPRequest) async throws -> HTTPResponse {
        handlerLock.lock()
        defer { handlerLock.unlock() }
        return handler
    }

    private func isStopped() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return stopped
    }

    public func start(host: String = "localhost", port: Int) throws {
        let fd = try SocketUtil.createListener(host: host, port: port)
        lifecycleLock.lock()
        self.stopped = false
        self.listenFD = fd
        lifecycleLock.unlock()
        print("[Binvia] listening on http://\(host):\(port)")
        // 每连接独立 Task 处理，accept 循环在后台持续运行
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            SocketUtil.acceptLoop(
                listenFD: fd,
                stop: { self.isStopped() },
                handler: { [weak self] request in
                    guard let self else { throw SocketError.closed }
                    let current = self.currentHandler()
                    return try await current(request)
                }
            )
        }
    }

    /// 停止服务：标记停止并关闭监听 fd，accept 循环在 ≤500ms 内退出。
    /// 幂等；停止后可再次 `start()` 重启。
    public func stop() {
        lifecycleLock.lock()
        stopped = true
        let fd = listenFD
        listenFD = nil
        lifecycleLock.unlock()
        if let fd {
            close(fd)
        }
    }
}

// MARK: - Socket

enum SocketError: Error {
    case socket(String)
    case bind(String)
    case listen(String)
    case accept
    case readTimeout
    case closed
    case malformedRequest
}

enum SocketUtil {
    static func createListener(host: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.socket("socket() failed, errno=\(errno)") }

        var no = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &no, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        // `inet_addr` 只认 IPv4 点分十进制；`localhost` 需先映射到环回地址。
        let bindHost = host == "localhost" ? "127.0.0.1" : host
        addr.sin_addr.s_addr = inet_addr(bindHost)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw SocketError.bind("bind() failed, errno=\(errno)")
        }

        // 遮蔽 C 函数 `listen`，显式调用系统版本
        let listenResult = sysListen(fd, 128)
        guard listenResult == 0 else {
            close(fd)
            throw SocketError.listen("listen() failed, errno=\(errno)")
        }
        return fd
    }

    /// accept 循环：用 `poll` 以 500ms 为周期探测可读，配合 `stop` 闭包支持优雅停止。
    /// 监听 fd 由 `HTTPServer.stop()` 负责 close；循环检测到 EBADF（fd 已关闭）即退出。
    static func acceptLoop(
        listenFD: Int32,
        stop: @escaping @Sendable () -> Bool,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) {
        while !stop() {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let n = poll(&pfd, 1, 500)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EBADF { break } // fd 已被 stop() 关闭
                break
            }
            if n == 0 { continue } // 超时，回到循环头部检查 stop
            if pfd.revents & Int16(POLLIN) == 0 { continue }

            var addr = sockaddr()
            var len = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &len)
                }
            }
            guard clientFD >= 0 else {
                // 可恢复的错误（EINTR 等）继续；严重错误退出
                if errno == EBADF || errno == EINVAL {
                    break
                }
                continue
            }
            Task.detached {
                await handleConnection(fd: clientFD, handler: handler)
                close(clientFD)
            }
        }
    }

    private static func handleConnection(
        fd: Int32,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) async {
        do {
            let request = try readRequest(fd)
            let response = try await handler(request)
            try await writeResponse(response, to: fd)
        } catch {
            // 尽力返回 500
            let message = "Internal Server Error: \(error.localizedDescription)"
            let body = Data(message.utf8)
            _ = try? writeAll(
                fd,
                Data("HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            )
        }
    }

    // MARK: 读取请求

    static func readRequest(_ fd: Int32) throws -> HTTPRequest {
        // 接收超时 10s
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var temp = [UInt8](repeating: 0, count: 16_384)
        var headerEndIndex: Int?

        while headerEndIndex == nil {
            let n = read(fd, &temp, temp.count)
            if n == 0 { throw SocketError.closed }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.readTimeout }
                throw SocketError.closed
            }
            buffer.append(contentsOf: temp[0 ..< n])
            headerEndIndex = indexOfHeaderTerminator(buffer)
            if buffer.count > 1_048_576 { throw SocketError.malformedRequest }
        }

        guard let end = headerEndIndex, end > 0 else { throw SocketError.malformedRequest }

        let headerData = buffer.subdata(in: 0 ..< end)
        var bodyData = buffer.subdata(in: (end + 4) ..< buffer.count)

        // 解析请求行与头
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw SocketError.malformedRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { throw SocketError.malformedRequest }

        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // 读取 body
        if let contentLengthStr = headers["content-length"], let contentLength = Int(contentLengthStr) {
            while bodyData.count < contentLength {
                let n = read(fd, &temp, temp.count)
                if n <= 0 { throw SocketError.closed }
                bodyData.append(contentsOf: temp[0 ..< n])
            }
            bodyData = bodyData.prefix(contentLength)
        }

        var components = URLComponents(string: target) ?? URLComponents()
        if components.scheme == nil {
            components = URLComponents(string: "http://localhost\(target)") ?? components
        }
        let path = components.path.isEmpty ? "/" : components.path
        var queryItems: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                queryItems[item.name] = value
            }
        }

        return HTTPRequest(method: method, path: path, queryItems: queryItems, headers: headers, body: bodyData.isEmpty ? nil : bodyData)
    }

    static func indexOfHeaderTerminator(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        for i in 0 ... (bytes.count - 4) {
            if bytes[i] == 13, bytes[i + 1] == 10, bytes[i + 2] == 13, bytes[i + 3] == 10 {
                return i
            }
        }
        return nil
    }

    // MARK: 写出响应

    static func writeResponse(_ response: HTTPResponse, to fd: Int32) async throws {
        var head = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
        head += "Connection: close\r\n"
        switch response.body {
        case .data(let data):
            head += "Content-Length: \(data.count)\r\n"
        case .stream:
            // 流式响应不设 Content-Length，以连接关闭标识结束（SSE/代理语义）
            head += "Cache-Control: no-cache\r\n"
        }
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        try writeAll(fd, Data(head.utf8))

        switch response.body {
        case .data(let data):
            if !data.isEmpty {
                try writeAll(fd, data)
            }
        case .stream(let stream):
            for try await chunk in stream {
                try writeAll(fd, chunk)
            }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        var written = 0
        let bytes = [UInt8](data)
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                write(fd, buf.baseAddress! + written, bytes.count - written)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw SocketError.closed
            }
            if n == 0 { throw SocketError.closed }
            written += n
        }
    }

    static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
