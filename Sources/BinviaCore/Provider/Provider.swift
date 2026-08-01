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

    /// 串行测试该供应商全部模型（listModels → 逐个 testModel → 汇总）。
    /// 默认实现保证顺序与汇总；子类可覆盖以复用连接或做并发。
    func testAllModels(credential: ProviderCredential?) async -> [ModelTestOutcome]
}

/// 单个模型的批量测试结果（Phase 13，`testAllModels` 的输出单元）。
public struct ModelTestOutcome: Sendable, Equatable, Identifiable {
    public let modelID: String
    public let success: Bool
    public let message: String
    public let latencyMS: Double?

    public var id: String { modelID }

    public init(modelID: String, success: Bool, message: String, latencyMS: Double? = nil) {
        self.modelID = modelID
        self.success = success
        self.message = message
        self.latencyMS = latencyMS
    }
}

/// OpenAI 兼容 `/v1/models` 响应的最小解码结构（供默认 `listModels` 与测试复用）。
struct DynamicModelsResponse: Decodable {
    struct Item: Decodable {
        let id: String
        let ownedBy: String?
    }
    let data: [Item]
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

    /// 默认实现（Phase 13，需求 7）：「`ModelCache` 优先 → 上游 `modelsURL` → 静态兜底」。
    /// 仅支持 OpenAI 兼容的 `/v1/models` 响应（`{"data":[{"id":...}]}`）；已有自定义逻辑的
    /// 供应商（DeepSeek / Antigravity / CodeBuddyCN）仍覆盖本实现。
    func listModels(credential: ProviderCredential?) async throws -> [Model] {
        let descriptor = ProviderRegistry.shared.descriptor(for: id)
        let staticModels = descriptor?.models ?? []
        guard let modelsURL = descriptor?.modelsURL else {
            // 无动态端点：直接返回静态目录
            return staticModels
        }
        return await Self.fetchDynamicModels(
            id: id,
            modelsURL: modelsURL,
            staticModels: staticModels,
            credential: credential
        )
    }

    /// 串行测试全部模型。按 `listModels` 结果顺序逐个 `testModel`，返回汇总。
    /// 单个模型失败不中断后续测试（需求 1 对齐：串行 + 进度条）。
    func testAllModels(credential: ProviderCredential?) async -> [ModelTestOutcome] {
        let models = (try? await listModels(credential: credential)) ?? []
        var outcomes: [ModelTestOutcome] = []
        for model in models {
            do {
                let result = try await testModel(model.id, credential: credential)
                outcomes.append(ModelTestOutcome(
                    modelID: model.id,
                    success: result.success,
                    message: result.message,
                    latencyMS: result.latencyMS
                ))
            } catch {
                outcomes.append(ModelTestOutcome(
                    modelID: model.id,
                    success: false,
                    message: error.localizedDescription
                ))
            }
        }
        return outcomes
    }

    /// 动态模型获取的共享实现（供默认 `listModels` 与测试复用）。
    /// - `ModelCache` 命中直接返回（300s TTL）；
    /// - 无凭据或上游失败静默回退静态目录；
    /// - 上游成功且非空时写缓存。
    nonisolated static func fetchDynamicModels(
        id: String,
        modelsURL: URL,
        staticModels: [Model],
        credential: ProviderCredential?
    ) async -> [Model] {
        // 1. 缓存命中
        if let cached = await ModelCache.shared.get(id) {
            return cached
        }
        // 2. 无凭据时回退静态目录
        let envName = "\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_API_KEY"
        let token: String
        if let apiKey = credential?.apiKey, !apiKey.isEmpty {
            token = apiKey
        } else if let env = RouteConfig.envValue([envName]), !env.isEmpty {
            token = env
        } else {
            return staticModels
        }
        // 3. 支持 <PROVIDER>_BASE_URL 环境变量覆盖（测试/镜像场景）：命中时用 base/models
        //    替代描述符中的 modelsURL（base 已含 /v1，如 http://127.0.0.1:port/v1）。
        let baseEnvName = "\(id.uppercased().replacingOccurrences(of: "-", with: "_"))_BASE_URL"
        let effectiveURL: URL
        if let base = RouteConfig.envValue([baseEnvName]), !base.isEmpty,
           let derived = URL(string: base + "/models") {
            effectiveURL = derived
        } else {
            effectiveURL = modelsURL
        }
        // 4. 打上游
        var request = URLRequest(url: effectiveURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await ProviderHTTPClient.shared.data(for: request, retryPolicy: ProviderHTTPRetryPolicy())
            guard (200 ..< 300).contains(response.statusCode) else {
                return staticModels
            }
            let decoded = try JSONDecoder().decode(DynamicModelsResponse.self, from: data)
            let models = decoded.data.map { Model(id: $0.id, name: $0.id) }
            if !models.isEmpty {
                await ModelCache.shared.set(id, models: models)
                return models
            }
            return staticModels
        } catch {
            return staticModels
        }
    }
}
