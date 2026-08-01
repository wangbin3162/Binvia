import Foundation

/// 可注入的 URLSession 协议 mock。用于拦截 URLSession 请求，
/// 模拟上游状态码/延迟/重试语义，避免真实网络调用。
final class URLProtocolMock: URLProtocol, @unchecked Sendable {
    /// 由测试设置：根据请求返回 (response, data)。抛错等价于网络层失败。
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    /// 统计拦截到的请求次数（供重试断言）。
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLProtocolMock.requestCount += 1
        guard let handler = URLProtocolMock.requestHandler else {
            fatalError("URLProtocolMock.requestHandler 未设置")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// 构造注入了 mock 协议的 URLSession。
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolMock.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        requestHandler = nil
        requestCount = 0
    }
}
