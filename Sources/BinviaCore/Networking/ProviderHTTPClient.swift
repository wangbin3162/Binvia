import Foundation

public enum ProviderHTTPError: Error, Sendable {
    case badResponse
    case httpStatus(Int, String?)
}

extension ProviderHTTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Upstream returned a non-HTTP response"
        case .httpStatus(let code, let body):
            return "Upstream HTTP \(code): \(body ?? "")"
        }
    }
}

/// 上游请求重试策略。仅对幂等请求 + 可重试状态码生效。
public struct ProviderHTTPRetryPolicy: Sendable {
    /// 最大重试次数（首次尝试之外可额外重试的次数）。
    public var maxRetries: Int
    /// 可重试的 HTTP 状态码。
    public var retryableStatusCodes: Set<Int>
    /// 退避基础延迟（秒）。
    public var baseDelay: TimeInterval
    /// 指数退避上限（秒）。
    public var maxDelay: TimeInterval

    public init(
        maxRetries: Int = 2,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 5.0
    ) {
        self.maxRetries = maxRetries
        self.retryableStatusCodes = retryableStatusCodes
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// 第 `attempt` 次重试（从 1 开始）的退避延迟：baseDelay × 2^(attempt-1)，封顶 maxDelay。
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = baseDelay * pow(2.0, Double(max(0, attempt - 1)))
        return min(exponential, maxDelay)
    }

    /// 当前 `attempt`（首次为 0）之后是否还需要重试。
    func shouldRetry(statusCode: Int, request: URLRequest, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        guard retryableStatusCodes.contains(statusCode) else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        return method == "GET" || method == "HEAD" || method == "OPTIONS"
    }
}

/// 上游 HTTP 客户端。借鉴 CodexBar `ProviderHTTPClient`（重试/重定向防护）。
public struct ProviderHTTPClient: Sendable {
    public static let shared = ProviderHTTPClient()

    /// 非流式请求（用量查询 / 模型列表 / 连通性探测）超时上限（秒）。
    /// URLSession 默认 60s：上游不可达（如被墙域名）时会把调用方拖住分钟级
    /// （实测 `/v1/models` 62s、用量轮询 hang）。统一封顶后最坏 12s 返回。
    /// 流式请求走 `stream` / `streamThrowing`，不受影响。
    public static let nonStreamingTimeout: TimeInterval = 12
    /// 流式请求空闲超时上限（秒）：URLSession 等待上游新数据超过该时长即终止。
    /// 只约束“两次数据之间的空闲时间”，不限制长流总时长。
    public static let streamingIdleTimeout: TimeInterval = 60

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// 一次性请求（无重试），返回完整 body 与 HTTP 状态。非 2xx 不抛错，由调用方处理。
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await data(for: request, retryPolicy: ProviderHTTPRetryPolicy(maxRetries: 0))
    }

    /// 一次性请求（带重试），返回完整 body 与 HTTP 状态。非 2xx 不抛错，由调用方处理。
    /// 仅对幂等方法（GET/HEAD/OPTIONS）+ 可重试状态码重试；
    /// 尊重上游 `Retry-After` 头（秒，封顶 60s 防止异常等待）；重试间 `try? await Task.sleep`。
    public func data(
        for request: URLRequest,
        retryPolicy: ProviderHTTPRetryPolicy
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        // 非流式请求超时封顶（12s）：显式设置过更短超时的请求保留原值。
        if request.timeoutInterval > Self.nonStreamingTimeout {
            request.timeoutInterval = Self.nonStreamingTimeout
        }
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderHTTPError.badResponse
            }
            guard retryPolicy.shouldRetry(statusCode: http.statusCode, request: request, attempt: attempt) else {
                return (data, http)
            }
            let backoff = retryPolicy.delay(forAttempt: attempt + 1)
            let delay = Self.retryDelay(from: http, fallback: backoff)
            try? await Task.sleep(for: .seconds(delay))
            attempt += 1
        }
    }

    /// 读取 `Retry-After`（秒），无法解析时回退到指数退避。
    private static func retryDelay(from response: HTTPURLResponse, fallback: TimeInterval) -> TimeInterval {
        if let value = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(value) {
            return min(seconds, 60)
        }
        return fallback
    }

    /// 流式请求。逐字节透传上游 body。
    /// 非 2xx 时把上游错误 body 作为数据块透传（反向代理语义），不抛错。
    public func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        var mutableRequest = request
        if mutableRequest.timeoutInterval > Self.streamingIdleTimeout {
            mutableRequest.timeoutInterval = Self.streamingIdleTimeout
        }
        let effectiveRequest = mutableRequest
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: effectiveRequest)
                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        // 收集错误 body 并透传，保持与上游一致的错误信息
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                        }
                        continuation.yield(errorBody)
                        continuation.finish()
                        return
                    }
                    for try await byte in bytes {
                        continuation.yield(Data([byte]))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 流式请求（抛错版）。与 `stream(for:)` 的区别：非 2xx 时抛
    /// `ProviderError.upstreamError(statusCode:message:)`（可读错误 body），
    /// 而非透传错误 body。用于 key 轮换等需要判断握手状态的场景。
    public func streamThrowing(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        var mutableRequest = request
        if mutableRequest.timeoutInterval > Self.streamingIdleTimeout {
            mutableRequest.timeoutInterval = Self.streamingIdleTimeout
        }
        let effectiveRequest = mutableRequest
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: effectiveRequest)
                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                        }
                        let message = String(data: errorBody, encoding: .utf8) ?? ""
                        continuation.finish(throwing: ProviderError.upstreamError(statusCode: http.statusCode, message: message))
                        return
                    }
                    for try await byte in bytes {
                        continuation.yield(Data([byte]))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
