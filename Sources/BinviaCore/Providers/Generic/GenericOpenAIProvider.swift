import Foundation

/// 用户自定义的 OpenAI 兼容 Provider。
///
/// 与内置 `OpenAIProvider` 的差异：
/// - `baseURL`/`models` 在构造时由 config 注入（不读 env、不读静态目录）；
/// - 模型 id 在 `listModels` 输出时**带 provider 前缀**（`unisound/glm-5.2`），
///   便于客户端复制 `/v1/models` 结果直接调用；`chat` 内部剥前缀后转发上游；
/// - 单 key（无轮换）；`Authorization: Bearer <key>`。
///
/// 路由：客户端发送 `<id>/<model>` → Router Stage 1 解析为 `(providerID: <id>, modelID: <model>)`
/// → `RouteHandler` 调本 provider 的 `chat`，`makeBody` 再保险地剥一次前缀后转发上游。
/// `testModel` 传带前缀的 model id，`chat` 同样剥前缀，故两条入口统一处理。
public struct GenericOpenAIProvider: Provider {
    public let id: String
    private let baseURL: URL
    private let prefixedModels: [Model]

    public init(id: String, baseURL: URL, models: [String]) {
        self.id = id
        self.baseURL = baseURL
        // 归一化：模型名去掉可能已存在的 `<id>/` 前缀后再统一加一次，避免 `/v1/models` 输出双重前缀。
        self.prefixedModels = models.map { raw in
            Model(id: "\(id)/\(Self.stripRepeatedPrefix(raw, id: id))")
        }
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

    /// 直接返回构造时注入的带前缀模型列表。不走 ModelCache / 不拉上游（用户手动维护）。
    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        prefixedModels
    }
}
