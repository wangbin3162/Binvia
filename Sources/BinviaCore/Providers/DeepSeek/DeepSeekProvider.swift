import Foundation

public enum DeepSeekProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "deepseek",
            alias: "ds",
            displayName: "DeepSeek",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.deepseek.com/v1"),
        models: [
            Model(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", supportsReasoning: true),
            Model(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", supportsReasoning: true),
        ],
        supportsStreaming: true,
        usageFetcherFactory: { DeepSeekUsageFetcher() },
        makeProvider: { DeepSeekProvider() }
    )
}

/// DeepSeek 供应商（API key 型）。
/// 依据：CodexBar `Providers/DeepSeek`（APITokenFetchStrategy）+ OmniRoute `registry/deepseek`。
public struct DeepSeekProvider: Provider {
    public let id = "deepseek"

    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["DEEPSEEK_BASE_URL"]) ?? "https://api.deepseek.com/v1"
        }
        static var models: URL { URL(string: "\(base)/models")! }
        static var chat: URL { URL(string: "\(base)/chat/completions")! }
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("DEEPSEEK_API_KEY or config providers.deepseek.credential.apiKey")
    }

    /// 解析全部可用 key（轮换用）：credential.apiKey 优先，并入 config `apiKeys` 数组与环境变量 key。
    private func resolveKeys(_ credential: ProviderCredential?) -> [String] {
        var keys: [String] = []
        // 1. credential.apiKey 优先（RouteHandler 传入的主 key）
        if let apiKey = credential?.apiKey, !apiKey.isEmpty {
            keys.append(apiKey)
        }
        // 2. 配置文件中的 apiKeys 数组 + 环境变量 key（RouteConfig.apiKeys 已去重过滤）
        if let config = try? ConfigStore.load() {
            keys.append(contentsOf: config.apiKeys(for: id))
        }
        // 3. 环境变量显式兜底（config 读取失败时仍可用）
        if let env = RouteConfig.envValue(["DEEPSEEK_API_KEY"]), !env.isEmpty {
            keys.append(env)
        }
        var seen = Set<String>()
        return keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 是否属于可轮换的握手期鉴权错误（401/403）。
    private static func isAuthRotationError(_ error: Error) -> Bool {
        guard case ProviderError.upstreamError(let statusCode, _) = error else { return false }
        return statusCode == 401 || statusCode == 403
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let ownedBy: String?
        }
        let data: [Item]
    }

    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        // 1. 缓存命中直接返回
        if let cached = await ModelCache.shared.get(id) {
            return cached
        }
        // 2. 无凭据时直接回退静态目录（api-key 供应商不应导致 /v1/models 报错）
        guard let key = resolveKeys(credential).first else {
            return DeepSeekProviderDescriptor.descriptor.models
        }
        // 3. 打上游，成功后写缓存；任何失败静默回退静态目录
        var request = URLRequest(url: Endpoint.models)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await ProviderHTTPClient.shared.data(for: request, retryPolicy: ProviderHTTPRetryPolicy())
            guard (200 ..< 300).contains(response.statusCode) else {
                return DeepSeekProviderDescriptor.descriptor.models
            }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let models = decoded.data.map { Model(id: $0.id, name: $0.id) }
            await ModelCache.shared.set(id, models: models)
            return models
        } catch {
            return DeepSeekProviderDescriptor.descriptor.models
        }
    }

    public func chat(request: ChatRequest, rawBody: Data?, credential: ProviderCredential?) async throws -> AsyncThrowingStream<Data, Error> {
        let keys = resolveKeys(credential)
        guard !keys.isEmpty else {
            throw ProviderError.missingCredentials("DEEPSEEK_API_KEY or config providers.deepseek.credential.apiKey")
        }
        // 优先使用 rawBody 透传（保留客户端所有字段和正确字段名）
        let body: Data
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            json["model"] = request.model
            json = RoleNormalizer.normalizeDeveloperRole(json, providerID: id)
            body = try JSONSerialization.data(withJSONObject: json)
        } else {
            // DeepSeek 上游不认 developer 角色（OpenAI 新版约定），归一化为 system
            var req = request
            req.messages = req.messages.map { message in
                message.role == .developer
                    ? ChatMessage(role: .system, content: message.content, name: message.name, toolCallID: message.toolCallID)
                    : message
            }
            body = try JSONEncoder().encode(req)
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                for (index, key) in keys.enumerated() {
                    var upstream = URLRequest(url: Endpoint.chat)
                    upstream.httpMethod = "POST"
                    upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    upstream.httpBody = body

                    let stream = ProviderHTTPClient.shared.streamThrowing(for: upstream)
                    var iterator = stream.makeAsyncIterator()
                    do {
                        // 先取首个元素：此阶段抛错可判定为握手失败并轮换
                        guard let first = try await iterator.next() else {
                            continuation.finish()
                            return
                        }
                        // 已进入传输阶段：提交给该 key，后续失败不再轮换（可接受限制）
                        continuation.yield(first)
                        while let chunk = try await iterator.next() {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    } catch {
                        // 仅初始握手阶段的 401/403 轮换；传输中途失败无法轮换（可接受限制）
                        if Self.isAuthRotationError(error), index + 1 < keys.count {
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
                // 理论不可达（keys 非空时循环内必然 return）
                continuation.finish(throwing: ProviderError.invalidResponse("no upstream response"))
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
