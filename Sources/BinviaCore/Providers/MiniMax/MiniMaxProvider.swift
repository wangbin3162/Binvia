import Foundation

public enum MiniMaxProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "minimax",
            alias: "mm",
            displayName: "MiniMax",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.minimaxi.com/v1"),
        models: [
            Model(id: "MiniMax-M3", name: "MiniMax-M3", contextLength: 1_048_576, supportsReasoning: true, supportsVision: true),
            Model(id: "MiniMax-M2.7", name: "MiniMax-M2.7"),
            Model(id: "MiniMax-M2.5", name: "MiniMax-M2.5"),
        ],
        supportsStreaming: true,
        modelsURL: URL(string: "https://api.minimaxi.com/v1/models"),
        // 纯 API key（非 Token/Coding Plan 订阅）无法调用用量接口，余额需登录控制台查看
        //（参考 zai 的 usageDashboardURL 方案）。
        usageDashboardURL: URL(string: "https://platform.minimaxi.com/console/recharge-records"),
        makeProvider: { MiniMaxProvider() }
    )
}

/// MiniMax 供应商（API key 型，OpenAI 兼容 `/chat/completions`）。
///
/// 上游端点 `https://api.minimaxi.com/v1/chat/completions`（官方 OpenAI 兼容接口，
/// 可用 `MINIMAX_BASE_URL` 覆盖），认证 `Authorization: Bearer <key>`。
/// `chat` 采用「rawBody 透传」模式（与 DeepSeek / GenericOpenAI 一致），客户端
/// `tools` / `tool_calls` / `tool_result` 等字段原样转发，天然支持工具调用。
/// OpenAI 端点原生支持 `stream=false`（返回单 JSON），非流式客户端直接透传。
/// `listModels` 走协议默认实现（modelsURL → 动态获取，失败回退静态目录）。
public struct MiniMaxProvider: Provider {
    public let id = "minimax"

    private static let defaultBaseURL = "https://api.minimaxi.com/v1"

    public init() {}

    /// 兼容用户把完整 `/chat/completions` 地址填进 `MINIMAX_BASE_URL` 的历史配置。
    /// Provider 内部始终以 `/chat/completions` 作为统一追加路径。
    private static func normalizeBaseURL(_ raw: String) -> String {
        let suffix = "/chat/completions"
        var result = raw
        while result.hasSuffix("/") { result.removeLast() }
        if result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result
    }

    private func resolveBaseURL() -> String {
        if let env = RouteConfig.envValue(["MINIMAX_BASE_URL"]), !env.isEmpty {
            return Self.normalizeBaseURL(env)
        }
        return Self.defaultBaseURL
    }

    /// 构建 OpenAI 上游请求体：优先透传 rawBody（保留 tools / tool_calls 等全部字段），
    /// 否则编码 ChatRequest。model 用路由解析后的裸模型名；developer 角色归一化为 system
    /// （MiniMax 上游不认 developer，会 400）；max_tokens 钳制到通用安全上限。
    private func makeBody(request: ChatRequest, rawBody: Data?) throws -> Data {
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            json["model"] = request.model
            json = RoleNormalizer.normalizeDeveloperRole(json, providerID: id)
            if let maxTokens = json["max_tokens"] as? Int, maxTokens > 131_072 {
                json["max_tokens"] = 131_072
            }
            return try JSONSerialization.data(withJSONObject: json)
        }
        var req = request
        req.messages = req.messages.map { message in
            message.role == .developer
                ? ChatMessage(role: .system, content: message.content, name: message.name, toolCallID: message.toolCallID)
                : message
        }
        if let maxTokens = req.maxTokens, maxTokens > 131_072 {
            req.maxTokens = 131_072
        }
        return try JSONEncoder().encode(req)
    }

    private func resolveKey(_ credential: ProviderCredential?) throws -> String {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["MINIMAX_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("MINIMAX_API_KEY or config providers.minimax.credential.apiKey")
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let key = try resolveKey(credential)
        let endpoint = URL(string: "\(resolveBaseURL())/chat/completions")!

        var upstream = URLRequest(url: endpoint)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        upstream.httpBody = try makeBody(request: request, rawBody: rawBody)

        // 透传流：客户端 stream=true/false 原样转发；上游非 2xx 错误 body 直接透传（反向代理语义）。
        return ProviderHTTPClient.shared.stream(for: upstream)
    }
}
