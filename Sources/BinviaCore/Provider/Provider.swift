import Foundation

/// Provider 抽象协议。借鉴 CodexBar `ProviderDescriptor` 与 OmniRoute `RegistryEntry` 的设计。
///
/// 实现约定：
/// - `chat` 始终以「流」的形式返回上游数据块（SSE chunk 或完整 JSON body），
///   由上层决定透传（streaming）或聚合（non-streaming）。
/// - 上游非 2xx 时，实现应抛 `ProviderError.upstreamError`，以便上层返回正确的 HTTP 状态码。
public protocol Provider: Sendable {
    var id: String { get }

    /// 获取模型列表。优先调用上游 `/v1/models`，失败时回退到注册表静态目录。
    func listModels(credential: ProviderCredential?) async throws -> [Model]

    /// 聊天补全。`request.model` 已由路由层剥离 provider 前缀，是纯模型名。
    /// `rawBody` 是客户端原始 JSON body，供 Provider 透传以保留未知字段和正确的字段名。
    func chat(request: ChatRequest, rawBody: Data?, credential: ProviderCredential?) async throws -> AsyncThrowingStream<Data, Error>

    /// 可用性测试。
    func testConnection(credential: ProviderCredential?) async throws -> ConnectionTestResult

    /// 模型级连通性测试：发送最小请求（max_tokens:1）探测指定模型可用性。
    func testModel(_ modelID: String, credential: ProviderCredential?) async throws -> ConnectionTestResult
}

public extension Provider {
    /// 默认实现：调用 listModels 验证连通性。
    func testConnection(credential: ProviderCredential?) async throws -> ConnectionTestResult {
        let start = Date()
        do {
            _ = try await listModels(credential: credential)
            let latency = Date().timeIntervalSince(start) * 1000
            return ConnectionTestResult(success: true, message: "Connected to \(id)", latencyMS: latency)
        } catch {
            let latency = Date().timeIntervalSince(start) * 1000
            return ConnectionTestResult(success: false, message: error.localizedDescription, latencyMS: latency)
        }
    }

    /// 默认实现：与 testConnection 相同（子类可覆盖以发送真实请求）。
    func testModel(_ modelID: String, credential: ProviderCredential?) async throws -> ConnectionTestResult {
        let start = Date()
        let request = ChatRequest(
            model: modelID,
            messages: [ChatMessage(role: .user, content: "ping")],
            stream: true,
            maxTokens: 1
        )
        do {
            let stream = try await chat(request: request, rawBody: nil, credential: credential)
            var iterator = stream.makeAsyncIterator()
            guard let _ = try await iterator.next() else {
                return ConnectionTestResult(
                    success: false,
                    message: "模型 \(modelID) 返回空响应",
                    latencyMS: Date().timeIntervalSince(start) * 1000
                )
            }
            return ConnectionTestResult(
                success: true,
                message: "模型 \(modelID) 可用",
                latencyMS: Date().timeIntervalSince(start) * 1000
            )
        } catch {
            return ConnectionTestResult(
                success: false,
                message: "模型 \(modelID) 测试失败: \(error.localizedDescription)",
                latencyMS: Date().timeIntervalSince(start) * 1000
            )
        }
    }
}
