import Foundation

/// 用户自定义的 OpenAI 兼容 Provider。
///
/// 与内置 `OpenAIProvider` 的差异：
/// - `baseURL`/`models` 在构造时由 config 注入（不读 env、不读静态目录）；
/// - `listModels` 返回**不带 provider 前缀**的模型 id；前缀由 `/v1/models`、模型白名单和 UI 统一拼接，避免重复；
/// - `chat` 兼容接收带前缀或重复前缀的模型名，并在转发上游前剥除；
/// - 单 key（无轮换）；`Authorization: Bearer <key>`。
///
/// 路由：客户端发送 `<id>/<model>` → Router Stage 1 解析为 `(providerID: <id>, modelID: <model>)`
/// → `RouteHandler` 调本 provider 的 `chat`，`makeBody` 再保险地剥一次前缀后转发上游。
/// `testModel` 可能传带前缀的 model id，`chat` 同样剥前缀，故两条入口统一处理。
public struct GenericOpenAIProvider: Provider {
    public let id: String
    private let baseURL: URL
    private let models: [Model]

    public init(id: String, baseURL: URL, models: [ProviderModelEntry]) {
        self.id = id
        self.baseURL = Self.normalizeBaseURL(baseURL)
        self.models = models.map { entry in
            Model(id: Self.stripRepeatedPrefix(entry.modelName, id: id))
        }
    }

    /// 兼容用户把完整 `/chat/completions` 地址填进 Base URL 的历史配置。
    /// Provider 内部始终以 `/chat/completions` 作为统一追加路径。
    private static func normalizeBaseURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let suffix = "/chat/completions"
        if var path = components?.path {
            while path.hasSuffix("/") { path.removeLast() }
            if path.hasSuffix(suffix) {
                path.removeLast(suffix.count)
                components?.path = path.isEmpty ? "/" : path
            }
        }
        return components?.url ?? url
    }

    /// 去掉全部 `<id>/` 前缀（若存在）。兼容路由已剥前缀、testModel 传带前缀、以及用户误存双重前缀三种入口。
    private static func stripRepeatedPrefix(_ modelID: String, id: String) -> String {
        let prefix = "\(id)/"
        var result = modelID
        while result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
        }
        return result
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("config.providers.\(id).credential.apiKey")
    }

    /// 构建上游请求体：优先透传 rawBody（保留未知字段与客户端 stream 标志），否则编码 ChatRequest。
    /// 模型字段剥去全部 `<id>/` 前缀后再转发上游（上游只认原始模型名）。
    private func makeBody(request: ChatRequest, rawBody: Data?) throws -> Data {
        let strippedModel = Self.stripRepeatedPrefix(request.model, id: id)
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            json["model"] = strippedModel
            // 对齐 OmniRoute：非 OpenAI 系供应商把 developer 角色归一化为 system
            // （tokenhub/glm、DeepSeek、MiniMax 等上游只认 system）
            json = RoleNormalizer.normalizeDeveloperRole(json, providerID: id)
            // 对齐 OmniRoute chatCore.ts #711（Provider-specific max_tokens caps）：
            // 客户端可能发送超出上游上限的 max_tokens（如 pi 配置 384000），
            // 上游会直接 400 拒绝，流式客户端会误报 "Stream ended without finish_reason"。
            // 这里钳制到通用安全上限 131072（GLM 等主流模型的 maxOutputTokens）。
            if let maxTokens = json["max_tokens"] as? Int, maxTokens > 131_072 {
                json["max_tokens"] = 131_072
            }
            return try JSONSerialization.data(withJSONObject: json)
        }
        var req = request
        req.model = strippedModel
        // 无 rawBody 时同样归一化 developer → system
        if !RoleNormalizer.preservesDeveloperRole(providerID: id) {
            req.messages = req.messages.map { message in
                message.role == .developer
                    ? ChatMessage(role: .system, content: message.content, name: message.name, toolCallID: message.toolCallID)
                    : message
            }
        }
        // 与 rawBody 路径一致的 max_tokens 钳制（对齐 OmniRoute #711）
        if let maxTokens = req.maxTokens, maxTokens > 131_072 {
            req.maxTokens = 131_072
        }
        return try JSONEncoder().encode(req)
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let key = try resolveKey(credential)
        let upstream = try makeUpstreamRequest(request: request, rawBody: rawBody, key: key)

        // 透传流：客户端 stream=true/false 原样转发；上游非 2xx 抛
        // ProviderError.upstreamError，由路由层保留上游状态码（不再伪装成 200）。
        return ProviderHTTPClient.shared.streamThrowing(for: upstream)
    }

    /// 模型级测试必须使用抛错版流，不能把 404 错误 body 当作“收到首个 chunk”而判定成功。
    public func testModel(_ modelID: String, credential: ProviderCredential?) async throws -> ConnectionTestResult {
        let start = Date()
        let key = try resolveKey(credential)
        let request = ChatRequest(
            model: modelID,
            messages: [ChatMessage(role: .user, content: "ping")],
            stream: true,
            maxTokens: 1
        )
        let upstream = try makeUpstreamRequest(request: request, rawBody: nil, key: key)
        let stream = ProviderHTTPClient.shared.streamThrowing(for: upstream)
        var iterator = stream.makeAsyncIterator()
        guard let first = try await iterator.next() else {
            return ConnectionTestResult(
                success: false,
                message: "模型 \(modelID) 返回空响应",
                latencyMS: Date().timeIntervalSince(start) * 1000
            )
        }
        if let message = Self.upstreamErrorMessage(first) {
            throw ProviderError.upstreamError(statusCode: 400, message: message)
        }
        return ConnectionTestResult(
            success: true,
            message: "模型 \(modelID) 可用",
            latencyMS: Date().timeIntervalSince(start) * 1000
        )
    }

    private func makeUpstreamRequest(request: ChatRequest, rawBody: Data?, key: String) throws -> URLRequest {
        let body = try makeBody(request: request, rawBody: rawBody)
        var upstream = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        upstream.httpBody = body
        return upstream
    }

    /// 兼容上游以 JSON 或单个 SSE data 事件返回 200 + error envelope 的情况。
    private static func upstreamErrorMessage(_ data: Data) -> String? {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let candidates = [raw, raw.replacingOccurrences(of: "data: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)]
        for candidate in candidates {
            guard let jsonData = candidate.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let error = root["error"] else { continue }
            if let object = error as? [String: Any], let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = error as? String, !message.isEmpty { return message }
        }
        return nil
    }

    /// 直接返回构造时注入的不带前缀模型列表。不走 ModelCache / 不拉上游（用户手动维护）。
    /// 外层统一拼接 `<provider>/<model>`，因此这里不能返回带 provider 前缀的 id。
    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        models
    }
}
