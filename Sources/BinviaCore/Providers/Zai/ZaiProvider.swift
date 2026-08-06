import Foundation

/// z.ai API 区域。
///
/// 默认 `.bigmodelCN`（中国区）——Phase 20 需求：默认 BigModel CN，可切 Global。
/// `ProviderCredential.region` 存原始值（`global` / `bigmodel-cn`），nil 视为默认区域。
public enum ZaiAPIRegion: String, CaseIterable, Sendable {
    case global
    case bigmodelCN = "bigmodel-cn"

    public var displayName: String {
        switch self {
        case .global: return "Global (api.z.ai)"
        case .bigmodelCN: return "BigModel CN (open.bigmodel.cn)"
        }
    }

    /// 区域 host（不含 `/api/coding/paas/v4` 路径）。
    public var baseHost: String {
        switch self {
        case .global: return "https://api.z.ai"
        case .bigmodelCN: return "https://open.bigmodel.cn"
        }
    }
}

public enum ZaiProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "zai",
            alias: "zai",
            displayName: "z.ai",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://open.bigmodel.cn/api/coding/paas/v4"),
        models: [
            Model(id: "glm-5.2", name: "GLM-5.2", supportsReasoning: true),
            Model(id: "glm-5.1", name: "GLM-5.1"),
            Model(id: "glm-5", name: "GLM-5"),
            Model(id: "glm-4.7-flash", name: "GLM-4.7-Flash"),
            Model(id: "glm-4.5-air", name: "GLM-4.5-Air"),
        ],
        supportsStreaming: true,
        // 首个区域为默认（BigModel CN）；设置面板按此顺序渲染 Picker。
        regions: [
            ProviderAPIRegion(id: ZaiAPIRegion.bigmodelCN.rawValue, displayName: ZaiAPIRegion.bigmodelCN.displayName),
            ProviderAPIRegion(id: ZaiAPIRegion.global.rawValue, displayName: ZaiAPIRegion.global.displayName),
        ],
        // 智谱官方未提供公开用量 API，提供网页看板入口（登录后查看余额/用量）。
        usageDashboardURL: URL(string: "https://bigmodel.cn/finance-center/finance/overview"),
        makeProvider: { ZaiProvider() }
    )
}

/// Z.ai / BigModel（GLM）供应商（API key 型，OpenAI 兼容 `/chat/completions`）。
///
/// 上游端点 `{region}/api/coding/paas/v4/chat/completions`（GLM Coding Plan 专属
/// OpenAI 兼容端点），认证 `Authorization: Bearer <key>`。
/// 区域解析：`ZAI_BASE_URL` 环境变量 → `ProviderCredential.region` → 默认 BigModel CN。
/// `chat` 采用「rawBody 透传」模式（与 DeepSeek / GenericOpenAI 一致），客户端
/// `tools` / `tool_calls` / `tool_result` 等字段原样转发，天然支持工具调用。
/// OpenAI 端点原生支持 `stream=false`（返回单 JSON），非流式客户端直接透传。
/// `listModels` 走协议默认实现（无 modelsURL → 静态目录）。
public struct ZaiProvider: Provider {
    public let id = "zai"

    public init() {}

    /// 按区域解析 OpenAI 兼容端点基础 URL（到 `/api/coding/paas/v4` 层）。
    private func resolveBaseURL(_ credential: ProviderCredential?) -> String {
        if let env = RouteConfig.envValue(["ZAI_BASE_URL"]), !env.isEmpty {
            return Self.normalizeBaseURL(env)
        }
        let region = credential?.region.flatMap(ZaiAPIRegion.init(rawValue:)) ?? .bigmodelCN
        return "\(region.baseHost)/api/coding/paas/v4"
    }

    /// 兼容用户把完整 `/chat/completions` 地址填进 `ZAI_BASE_URL` 的历史配置。
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

    /// 构建 OpenAI 上游请求体：优先透传 rawBody（保留 tools / tool_calls 等全部字段），
    /// 否则编码 ChatRequest。model 用路由解析后的裸模型名；developer 角色归一化为 system
    /// （GLM 上游不认 developer，会 400）；max_tokens 钳制到通用安全上限。
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
        if let key = RouteConfig.envValue(["ZAI_API_KEY"]), !key.isEmpty {
            return key
        }
        throw ProviderError.missingCredentials("ZAI_API_KEY or config providers.zai.credential.apiKey")
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let key = try resolveKey(credential)
        let base = resolveBaseURL(credential)
        let endpoint = URL(string: "\(base)/chat/completions")!

        var upstream = URLRequest(url: endpoint)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        upstream.httpBody = try makeBody(request: request, rawBody: rawBody)

        // 透传流：客户端 stream=true/false 原样转发；上游非 2xx 错误 body 直接透传（反向代理语义）。
        return ProviderHTTPClient.shared.stream(for: upstream)
    }
}
