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

    public init(id: String, baseURL: URL, models: [String]) {
        self.id = id
        self.baseURL = Self.normalizeBaseURL(baseURL)
        // 归一化：配置只保存原始模型名；兼容历史配置中已经带有一个或多个前缀的情况。
        self.models = models.map { raw in
            Model(id: Self.stripRepeatedPrefix(raw, id: id))
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
            return try JSONSerialization.data(withJSONObject: json)
        }
        var req = request
        req.model = strippedModel
        return try JSONEncoder().encode(req)
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let key = try resolveKey(credential)
        let body = try makeBody(request: request, rawBody: rawBody)

        var upstream = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        upstream.httpBody = body

        // 透传流：客户端 stream=true/false 原样转发；上游非 2xx 错误 body 直接透传（反向代理语义）。
        return ProviderHTTPClient.shared.stream(for: upstream)
    }

    /// 直接返回构造时注入的不带前缀模型列表。不走 ModelCache / 不拉上游（用户手动维护）。
    /// 外层统一拼接 `<provider>/<model>`，因此这里不能返回带 provider 前缀的 id。
    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        models
    }
}
