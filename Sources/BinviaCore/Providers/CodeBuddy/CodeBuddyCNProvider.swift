import Foundation

/// CodeBuddy CN 供应商描述符。已注册进 ProviderCatalog（勿改 ProviderCatalog.swift）。
/// 模型目录抄自 OmniRoute `open-sse/config/providers/registry/codebuddy-cn/index.ts`（15 个模型）。
public enum CodeBuddyCNProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "codebuddy-cn",
            alias: "cbcn",
            displayName: "CodeBuddy CN",
            authType: .deviceFlow
        ),
        baseURL: URL(string: "https://copilot.tencent.com/v2/chat/completions"),
        models: [
            Model(id: "glm-5.2", name: "GLM-5.2", contextLength: 1_000_000, supportsReasoning: true),
            Model(id: "glm-5.1", name: "GLM-5.1", contextLength: 200_000, supportsReasoning: true),
            Model(id: "glm-5.0", name: "GLM-5.0", contextLength: 200_000, supportsReasoning: true),
            Model(id: "glm-5.0-turbo", name: "GLM-5.0-Turbo", contextLength: 200_000, supportsReasoning: true),
            Model(id: "glm-5v-turbo", name: "GLM-5v-Turbo", contextLength: 200_000, supportsReasoning: true, supportsVision: true),
            Model(id: "glm-4.7", name: "GLM-4.7", contextLength: 200_000, supportsReasoning: true),
            Model(id: "minimax-m3", name: "MiniMax-M3", contextLength: 512_000, supportsReasoning: true, supportsVision: true),
            Model(id: "minimax-m2.7", name: "MiniMax-M2.7", contextLength: 200_000, supportsReasoning: true, supportsVision: true),
            Model(id: "kimi-k2.7", name: "Kimi-K2.7-Code", contextLength: 256_000, supportsReasoning: true, supportsVision: true),
            Model(id: "kimi-k2.6", name: "Kimi-K2.6", contextLength: 256_000, supportsReasoning: true, supportsVision: true),
            Model(id: "kimi-k2.5", name: "Kimi-K2.5", contextLength: 164_000, supportsReasoning: true, supportsVision: true),
            Model(id: "hy3-preview", name: "Hy3 Preview", contextLength: 192_000, supportsReasoning: true, supportsVision: true),
            Model(id: "deepseek-v4-pro", name: "DeepSeek-V4-Pro", contextLength: 1_000_000, supportsReasoning: true, supportsVision: true),
            Model(id: "deepseek-v4-flash", name: "DeepSeek-V4-Flash", contextLength: 1_000_000, supportsReasoning: true, supportsVision: true),
            Model(id: "deepseek-v3-2-volc", name: "DeepSeek-V3.2", contextLength: 96_000, supportsReasoning: true),
        ],
        supportsStreaming: true,
        // 通过 OAuth 登录 token 调腾讯计费接口获取额度（CodeBuddyCnUsageFetcher，参考
        // OmniRoute usage/codebuddy-cn.ts）；失败时兜底展示网页看板入口（登录后查看积分/余额）。
        usageFetcherFactory: { CodeBuddyCnUsageFetcher() },
        usageDashboardURL: URL(string: "https://www.codebuddy.cn/profile/usage"),
        makeProvider: { CodeBuddyCNProvider() }
    )
}

/// 腾讯 CodeBuddy 供应商（OAuth 设备码流）。Phase 2 完整实现。
/// 依据：OmniRoute `registry/codebuddy-cn` + `oauth/providers/codebuddy-cn.ts` + `executors/codebuddy-cn.ts`。
/// 关键点：
/// - 认证：`Authorization: Bearer <accessToken>`（config `apiKeys` 或 env `CODEBUDDY_CN_ACCESS_TOKEN`）。
/// - **OAuth 登录 token（credential.accessToken）仅用于积分查询**（CodeBuddyCnUsageFetcher），
///   不参与模型调用——登录 token 调用模型会报「体验版尚未激活」。
/// - 上游强制流式（非流式请求被拒 400 code 11101）：即使客户端 `stream=false` 也发 `stream:true`，
///   非流式客户端由本层用 `SSEJSONAggregator` 聚合成单个 JSON 返回。
/// - 请求头抄自 OmniRoute registry（CodeBuddy CLI 头）。
/// - 使用 `rawBody` 透传客户端原始 JSON（保留 max_tokens / tools 等字段和正确字段名）。
/// - 使用 `streamThrowing`（非 `stream`）：上游非 2xx 时抛错而非透传错误体。
public struct CodeBuddyCNProvider: Provider {
    public let id = "codebuddy-cn"

    public init() {}

    // MARK: - 端点

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["CODEBUDDY_CN_BASE_URL"]) ?? "https://copilot.tencent.com"
        }
        static var chat: URL { URL(string: "\(base)/v2/chat/completions")! }
    }

    // MARK: - 凭据解析（多 token 轮换）

    /// 当前使用的模型调用 token：config `apiKeys` 首个 → 环境变量兜底。
    /// 注意：`credential.accessToken`（OAuth 登录 token）仅用于积分查询，不参与模型调用。
    private func resolveToken(_ credential: ProviderCredential?) throws -> String {
        if let config = try? ConfigStore.load(),
           let first = config.apiKeys(for: id).first, !first.isEmpty {
            return first
        }
        if let token = RouteConfig.envValue(["CODEBUDDY_CN_ACCESS_TOKEN"]), !token.isEmpty {
            return token
        }
        throw ProviderError.missingCredentials(
            "config providers.codebuddy-cn.apiKeys 或 CODEBUDDY_CN_ACCESS_TOKEN（OAuth 登录 token 仅用于积分查询）"
        )
    }

    /// 解析全部可用模型调用 token（轮换用）：config `apiKeys` 数组 + 环境变量 token。
    /// 不含 `credential.accessToken`（登录 token 仅积分查询，不参与调用轮换）。
    private func resolveTokens(_ credential: ProviderCredential?) -> [String] {
        var tokens: [String] = []
        // 1. 配置文件中的 apiKeys 数组（模型调用 token 载体）
        if let config = try? ConfigStore.load() {
            tokens.append(contentsOf: config.apiKeys(for: id))
        }
        // 2. 环境变量显式兜底（config 读取失败时仍可用）
        if let env = RouteConfig.envValue(["CODEBUDDY_CN_ACCESS_TOKEN"]), !env.isEmpty {
            tokens.append(env)
        }
        var seen = Set<String>()
        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 是否属于可轮换的鉴权失败（401）。
    private static func isAuthRotationError(_ error: Error) -> Bool {
        guard case ProviderError.upstreamError(let statusCode, _) = error else { return false }
        return statusCode == 401 || statusCode == 403
    }

    /// ChatRequest 路径的角色归一化：`developer` → `system`（CodeBuddy 对 developer 角色误判内容审核）。
    public static func normalizeRoles(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { msg in
            guard msg.role == .developer else { return msg }
            var m = msg
            m.role = .system
            return m
        }
    }

    // MARK: - 请求头（抄自 OmniRoute registry/codebuddy-cn）

    private func applyCodeBuddyHeaders(to request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("CLI/2.108.1 CodeBuddy/2.108.1", forHTTPHeaderField: "User-Agent")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Type")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Name")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        request.setValue("1", forHTTPHeaderField: "x-codebuddy-request")
    }

    // MARK: - 请求体卫生化

    /// 把 `role: "developer"` 改写成 `role: "system"`。
    ///
    /// 腾讯 CodeBuddy 后端对 developer 角色会走更严格的内容审核路径，即使内容无害也返回
    /// `finish_reason: content_filter`（"敏感内容"误报，流式中途终止）；同内容用 system
    /// 角色则正常（实测 pi 用 developer 报错、opencode 用 system 正常）。两者在 OpenAI
    /// 规范里语义等价，转发前统一改写为 system。
    public static func sanitizeBody(_ json: [String: Any]) -> [String: Any] {
        var out = json
        if var messages = out["messages"] as? [[String: Any]] {
            messages = messages.map { msg in
                guard (msg["role"] as? String) == "developer" else { return msg }
                var m = msg
                m["role"] = "system"
                return m
            }
            out["messages"] = messages
        }
        return out
    }

    // MARK: - Provider

    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        // 静态目录（注册表唯一事实来源）；后续可通过上游模型配置动态获取。
        return CodeBuddyCNProviderDescriptor.descriptor.models
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        let tokens = resolveTokens(credential)
        guard !tokens.isEmpty else {
            throw ProviderError.missingCredentials(
                "CODEBUDDY_CN_ACCESS_TOKEN or config providers.codebuddy-cn.credential.accessToken"
            )
        }
        // 构建一次 body，轮换时复用（仅更换 Header 中的 Authorization）。
        let bodyData: Data
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            // developer→system 角色改写（CodeBuddy 对 developer 角色误判内容审核）
            json = Self.sanitizeBody(json)
            json["stream"] = true
            json["model"] = request.model
            bodyData = try JSONSerialization.data(withJSONObject: json)
        } else {
            var upstreamBody = request
            upstreamBody.messages = Self.normalizeRoles(upstreamBody.messages)
            upstreamBody.stream = true
            bodyData = try JSONEncoder().encode(upstreamBody)
        }
        // BINVIA_DEBUG_BODY=1：打印发往上游的原始 body（含 system prompt），用于排查上游误报
        if RouteConfig.envValue(["BINVIA_DEBUG_BODY"]) != nil {
            print("[codebuddy-cn:debug] upstream body: \(String(data: bodyData, encoding: .utf8) ?? "<non-utf8>")")
        }

        // 客户端 stream=false：上游强制流式，聚合成 JSON。需要在轮换循环内完成聚合。
        if request.stream != true {
            return aggregatedStream(tokens: tokens, body: bodyData)
        }
        // 客户端 stream=true：透传 SSE。
        return streamingWithRotation(tokens: tokens, body: bodyData)
    }

    /// 多 token 流式轮换：逐个尝试 token，401/403 时流转下一 token。
    private func streamingWithRotation(tokens: [String], body: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for (index, token) in tokens.enumerated() {
                    do {
                        let upstream = makeStreamingRequest(body: body, token: token)
                        let stream = ProviderHTTPClient.shared.streamThrowing(for: upstream)
                        let handler = IteratorHandler(iterator: stream.makeAsyncIterator())
                        // 先取首个元素：此阶段抛出 401/403 视为握手失败并轮换。
                        guard let first = try await handler.next() else {
                            continuation.finish()
                            return
                        }
                        continuation.yield(first)
                        while let chunk = try await handler.next() {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    } catch {
                        if Self.isAuthRotationError(error), index + 1 < tokens.count {
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: ProviderError.invalidResponse("no upstream response"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 多 token 流式轮换 → 聚合为单个 JSON（用于 stream=false 客户端）。
    private func aggregatedStream(tokens: [String], body: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastError: Error?
                for (index, token) in tokens.enumerated() {
                    do {
                        let upstream = makeStreamingRequest(body: body, token: token)
                        let stream = ProviderHTTPClient.shared.streamThrowing(for: upstream)
                        let json = try await SSEJSONAggregator.aggregateChatCompletion(stream)
                        continuation.yield(json)
                        continuation.finish()
                        return
                    } catch {
                        if Self.isAuthRotationError(error), index + 1 < tokens.count {
                            lastError = error
                            continue
                        }
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: lastError ?? ProviderError.invalidResponse("no upstream response"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 构建流式上游请求（stream=true 已在 body 中设置）。
    private func makeStreamingRequest(body: Data, token: String) -> URLRequest {
        var upstream = URLRequest(url: Endpoint.chat)
        upstream.httpMethod = "POST"
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCodeBuddyHeaders(to: &upstream, token: token)
        upstream.httpBody = body
        return upstream
    }

    /// 持有可变迭代器的 Sendable 包装。
    private final class IteratorHandler: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<Data, Error>.Iterator
        init(iterator: AsyncThrowingStream<Data, Error>.Iterator) { self.iterator = iterator }
        func next() async throws -> Data? { try await iterator.next() }
    }

    public func testConnection(credential: ProviderCredential?) async throws -> ConnectionTestResult {
        let start = Date()
        let tokens = resolveTokens(credential)
        guard !tokens.isEmpty else {
            return ConnectionTestResult(
                success: false,
                message: "请先配置 Access Token"
            )
        }

        var lastMessage: String?
        for (index, token) in tokens.enumerated() {
            do {
                try await probe(token: token)
                return ConnectionTestResult(
                    success: true,
                    message: "Connected to \(id)\(tokens.count > 1 ? " (token \(index + 1))" : "")",
                    latencyMS: Date().timeIntervalSince(start) * 1000
                )
            } catch CodeBuddyProbeError.unauthorized {
                // 401：尝试 refresh 一次后重试（token 索引 0 作为主 token 时使用配套的 refreshToken）。
                if index == 0, let refresh = credential?.refreshToken, !refresh.isEmpty {
                    do {
                        let client = CodeBuddyOAuthClient(config: .default)
                        let refreshed = try await client.refreshAccessToken(refreshToken: refresh)
                        do {
                            try await probe(token: refreshed.accessToken)
                            return ConnectionTestResult(
                                success: true,
                                message: "Connected to \(id) (refreshed token)",
                                latencyMS: Date().timeIntervalSince(start) * 1000
                            )
                        } catch {
                            lastMessage = "refreshed probe failed: \(error.localizedDescription)"
                        }
                    } catch {
                        lastMessage = "token refresh failed: \(error.localizedDescription)"
                    }
                }
                lastMessage = lastMessage ?? "401 unauthorized"
                if index + 1 < tokens.count { continue }
            } catch {
                lastMessage = error.localizedDescription
                if Self.isAuthRotationError(error), index + 1 < tokens.count { continue }
            }
        }
        return ConnectionTestResult(
            success: false,
            message: lastMessage ?? "all tokens failed",
            latencyMS: Date().timeIntervalSince(start) * 1000
        )
    }

    /// 模型级测试：用指定模型发送最小流式请求（多 token 轮换）。
    public func testModel(_ modelID: String, credential: ProviderCredential?) async throws -> ConnectionTestResult {
        let start = Date()
        let tokens = resolveTokens(credential)
        guard !tokens.isEmpty else {
            return ConnectionTestResult(
                success: false,
                message: "模型 \(modelID) 测试失败: 未配置 token"
            )
        }
        let probeRequest = ChatRequest(
            model: modelID,
            messages: [ChatMessage(role: .user, content: "ping")],
            stream: true,
            maxTokens: 1
        )
        // 构建一次 body，逐个 token 尝试。
        var bodyData: Data
        do {
            var upstreamBody = probeRequest
            upstreamBody.stream = true
            bodyData = try JSONEncoder().encode(upstreamBody)
        } catch {
            return ConnectionTestResult(success: false, message: error.localizedDescription)
        }
        for token in tokens {
            do {
                let upstream = makeStreamingRequest(body: bodyData, token: token)
                let stream = ProviderHTTPClient.shared.streamThrowing(for: upstream)
                let handler = IteratorHandler(iterator: stream.makeAsyncIterator())
                _ = try await handler.next()
                return ConnectionTestResult(
                    success: true,
                    message: "模型 \(modelID) 可用",
                    latencyMS: Date().timeIntervalSince(start) * 1000
                )
            } catch {
                continue
            }
        }
        return ConnectionTestResult(
            success: false,
            message: "模型 \(modelID) 测试失败: 所有 token 均未通过"
        )
    }

    // MARK: - 探测

    private enum CodeBuddyProbeError: Error, Sendable {
        case unauthorized
    }

    /// 最小流式探测：一次 `stream:true, max_tokens:1` 的 chat 请求，校验认证与上游连通性。
    private func probe(token: String) async throws {
        let probeRequest = ChatRequest(
            model: CodeBuddyCNProviderDescriptor.descriptor.models[0].id,
            messages: [ChatMessage(role: .user, content: "ping")],
            stream: true,
            maxTokens: 1
        )
        var upstreamBody = probeRequest
        upstreamBody.stream = true
        let bodyData = try JSONEncoder().encode(upstreamBody)
        let upstream = makeStreamingRequest(body: bodyData, token: token)
        let (data, response) = try await ProviderHTTPClient.shared.data(for: upstream)
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw CodeBuddyProbeError.unauthorized
            }
            throw ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}
