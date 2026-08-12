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
        if let key = credential?.apiKey {
            if !key.isEmpty { return key }
            throw ProviderError.missingCredentials("请先在供应商设置中启用一个 API Key")
        }
        if let key = RouteConfig.envValue(["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("DEEPSEEK_API_KEY or config providers.deepseek.credential.apiKey")
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
        guard let key = try? resolveKey(credential) else {
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
        let key = try resolveKey(credential)
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
                var upstream = URLRequest(url: Endpoint.chat)
                    upstream.httpMethod = "POST"
                    upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    upstream.httpBody = body

                let stream = ProviderHTTPClient.shared.streamThrowing(for: upstream)
                var iterator = stream.makeAsyncIterator()
                do {
                    while let chunk = try await iterator.next() {
                        continuation.yield(chunk)
                    }
                        continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
