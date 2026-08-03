import Foundation

public enum CursorProviderDescriptor {
    public static let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(
            id: "cursor",
            alias: "cu",
            displayName: "Cursor",
            authType: .apiKey
        ),
        baseURL: URL(string: "https://api.cursor.com/v1"),
        models: CursorModels.all,
        supportsStreaming: true,
        modelsURL: URL(string: "https://api.cursor.com/v1/models"),
        forceStream: false,
        usageFetcherFactory: { CursorUsageFetcher() },
        makeProvider: { CursorProvider() }
    )
}

/// Cursor 供应商（双模式：API Key / Cursor IDE 自动发现）。
///
/// - **API Key 模式**：有 `CURSOR_API_KEY` 或 config `credential.apiKey` 时，按 OpenAI 兼容端点
///   `https://api.cursor.com/v1` 接入（官方公开 REST，需单独购买 Cursor API key）。
/// - **IDE 模式**：无显式 key 时，自动读取 Cursor IDE 的登录令牌
///   （`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`），默认调用
///   `agent.v1.AgentService/Run`（HTTP/2 双向 Connect-RPC），支持 `auto` / `composer-*`；
///   `CURSOR_BASE_URL` 存在时保留旧协议路径，供 mock/镜像测试兼容。上游帧在 provider 内
///   转换成 OpenAI SSE（客户端 `stream=true` 透传；`stream=false` 由 `SSEJSONAggregator`
///   聚合成 JSON）。令牌约 24h 轮换，由 `CursorCredentialStore` 实时读取。
///   模型目录为 Cursor 实际模型 ID（同步 OmniRoute cursor 注册表，见 `CursorModels`）；命名模型需 Pro/Max 套餐，
///   免费套餐上游会拒绝。设置 `CURSOR_DEBUG=1` 可输出上游帧调试日志到 stderr。
///
/// 认证解析顺序：`credential.apiKey` → `CURSOR_API_KEY` → Cursor IDE 自动发现。
/// `CURSOR_BASE_URL` 环境变量用于旧 URLSession 协议的 mock/镜像测试；默认 Agent RPC 使用固定官方 host。
/// `listModels` 走协议默认实现（IDE 模式无 key 时自动回退静态目录）。
public struct CursorProvider: Provider {
    public let id = "cursor"

    public init() {}

    private enum Endpoint {
        /// 显式环境覆盖。存在时启用旧 URLSession 协议，供测试/镜像兼容；默认 IDE 模式走 Agent RPC。
        static var overrideBase: String? { RouteConfig.envValue(["CURSOR_BASE_URL"]) }
        /// API Key 模式：官方公开 REST 端点（base 已含 `/v1`）。
        static var publicChat: URL {
            URL(string: "\(overrideBase ?? "https://api.cursor.com/v1")/chat/completions")!
        }
        /// 旧 IDE 模式：仅用于 CURSOR_BASE_URL mock/镜像兼容。生产默认路径见 CursorAgentRPC。
        static var ideChat: URL {
            URL(string: "\(overrideBase ?? "https://api2.cursor.sh")/aiserver.v1.ChatService/StreamUnifiedChatWithTools")!
        }
    }

    /// 解析显式 API key：config `credential.apiKey` 优先，回退 `CURSOR_API_KEY`。
    private func resolveAPIKey(_ credential: ProviderCredential?) -> String? {
        if let key = credential?.apiKey, !key.isEmpty {
            return key
        }
        if let key = RouteConfig.envValue(["CURSOR_API_KEY"]), !key.isEmpty {
            return key
        }
        return nil
    }

    /// 构建 OpenAI JSON 请求体：优先透传 rawBody（保留未知字段与客户端 stream 标志），否则编码 ChatRequest。
    private func makeBody(request: ChatRequest, rawBody: Data?) throws -> Data {
        if let rawBody {
            guard var json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any] else {
                throw ProviderError.invalidResponse("invalid request body")
            }
            json["model"] = request.model
            return try JSONSerialization.data(withJSONObject: json)
        }
        return try JSONEncoder().encode(request)
    }

    public func chat(
        request: ChatRequest,
        rawBody: Data?,
        credential: ProviderCredential?
    ) async throws -> AsyncThrowingStream<Data, Error> {
        // 1. 手动导入账号（GUI「Cursor 账号」保存的 token + machineId）优先。
        if let token = credential?.accessToken, !token.isEmpty {
            let identity = CursorIDEIdentity(
                accessToken: token,
                machineId: credential?.machineId,
                expiresAt: nil
            )
            let messages = extractMessages(request: request, rawBody: rawBody)
            let sseStream: AsyncThrowingStream<Data, Error>
            if Endpoint.overrideBase != nil {
                // 测试/镜像仍走旧 URLSession 协议，保持 URLProtocol mock 兼容。
                let rpcBody = CursorChatRequestEncoder.makeBody(messages: messages, model: request.model)
                let upstream = makeIDERequest(body: rpcBody, identity: identity)
                sseStream = Self.rpcSSEStream(for: upstream, model: request.model)
            } else {
                sseStream = CursorAgentRPC.stream(messages: messages, model: request.model, identity: identity)
            }
            return Self.aggregateIfNeeded(request: request, sseStream: sseStream)
        }

        // 2. API Key 模式（官方公开 REST）。
        if let key = resolveAPIKey(credential) {
            let body = try makeBody(request: request, rawBody: rawBody)
            return ProviderHTTPClient.shared.stream(for: makePublicRequest(key: key, body: body))
        }

        // 3. IDE 模式：读 Cursor IDE 令牌 → 私有 protobuf RPC → SSE
        guard let identity = await CursorCredentialStore.shared.identity() else {
            throw ProviderError.missingCredentials(
                "Cursor：未配置 CURSOR_API_KEY，且未检测到 Cursor IDE 登录（请先登录 Cursor IDE，或设置 CURSOR_API_KEY）"
            )
        }
        let messages = extractMessages(request: request, rawBody: rawBody)
        let sseStream: AsyncThrowingStream<Data, Error>
        if Endpoint.overrideBase != nil {
            // 测试/镜像仍走旧 URLSession 协议，保持 URLProtocol mock 兼容。
            let rpcBody = CursorChatRequestEncoder.makeBody(messages: messages, model: request.model)
            let upstream = makeIDERequest(body: rpcBody, identity: identity)
            sseStream = Self.rpcSSEStream(for: upstream, model: request.model)
        } else {
            sseStream = CursorAgentRPC.stream(messages: messages, model: request.model, identity: identity)
        }
        return Self.aggregateIfNeeded(request: request, sseStream: sseStream)
    }

    /// 非流式客户端把 SSE 聚合成 OpenAI 单 JSON（手动导入账号分支复用 IDE 的聚合逻辑）。
    private static func aggregateIfNeeded(request: ChatRequest, sseStream: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        if request.stream == false {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let json = try await SSEJSONAggregator.aggregateChatCompletion(sseStream)
                        continuation.yield(json)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        return sseStream
    }

    // MARK: - listModels

    /// 模型列表：API Key 模式走 OpenAI 兼容 `/v1/models` 动态获取（失败回退静态目录）；
    /// IDE 模式直接返回官方静态目录（`CursorModels.all`，含 `auto`/`composer-*`）。
    ///
    /// 说明：Cursor 的模型目录是账号套餐相关的（Pro/Max 决定可用模型），且 IDE 私有端点
    /// 没有公开的 `/v1/models`。OmniRoute 用 `cursor-agent --list-models` 同步静态目录；
    /// 本机不一定装 cursor-agent，因此 IDE 模式以 `CursorModels.all` 为唯一来源，
    /// 保证 `/v1/models` 与网关密钥白名单能看到完整模型（含 `cu/auto`）。
    public func listModels(credential: ProviderCredential?) async throws -> [Model] {
        if let key = resolveAPIKey(credential) {
            let staticModels = CursorModels.all
            guard let modelsURL = CursorProviderDescriptor.descriptor.modelsURL else {
                return staticModels
            }
            return await Self.fetchDynamicModels(
                id: id,
                modelsURL: modelsURL,
                staticModels: staticModels,
                credential: ProviderCredential(apiKey: key)
            )
        }
        return CursorModels.all
    }

    /// API Key 模式请求：与 OpenAIProvider 一致（Bearer + application/json）。
    private func makePublicRequest(key: String, body: Data) -> URLRequest {
        var request = URLRequest(url: Endpoint.publicChat)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    /// IDE 模式请求：Connect-RPC protobuf + api2 头集（参考 `eisbaw/cursor_api_demo`）。
    private func makeIDERequest(body: Data, identity: CursorIDEIdentity) -> URLRequest {
        var request = URLRequest(url: Endpoint.ideChat)
        request.httpMethod = "POST"
        request.setValue("application/connect+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("gzip", forHTTPHeaderField: "Connect-Accept-Encoding")
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("connect-es/1.6.1", forHTTPHeaderField: "User-Agent")
        request.setValue("Root=\(UUID().uuidString)", forHTTPHeaderField: "x-amzn-trace-id")
        request.setValue(CursorHeaderHelper.clientKey(token: identity.accessToken), forHTTPHeaderField: "x-client-key")
        if let machineId = identity.machineId, !machineId.isEmpty {
            request.setValue(CursorChecksum.generate(machineId: machineId), forHTTPHeaderField: "x-cursor-checksum")
        }
        request.setValue("1.1.3", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("macos", forHTTPHeaderField: "x-cursor-client-os")
        request.setValue(CursorArch.current, forHTTPHeaderField: "x-cursor-client-arch")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-cursor-config-version")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "x-cursor-timezone")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-request-id")
        request.setValue(CursorHeaderHelper.sessionID(token: identity.accessToken), forHTTPHeaderField: "x-session-id")
        request.httpBody = body
        return request
    }

    // MARK: - 消息转换（OpenAI → Cursor Request）

    /// 从 rawBody / ChatRequest 提取 (role, content)，system 合并进 user。
    private func extractMessages(request: ChatRequest, rawBody: Data?) -> [(role: String, content: String)] {
        if let rawBody,
           let json = try? JSONSerialization.jsonObject(with: rawBody) as? [String: Any],
           let messages = json["messages"] as? [[String: Any]] {
            return Self.convertMessages(messages)
        }
        return request.messages.map { ($0.role.rawValue, $0.content ?? "") }
    }

    /// Cursor 无 system role：system 内容前置到 user 消息（`[System Instructions]`），
    /// 与 OmniRoute `openai-to-cursor` 转换器一致。
    static func convertMessages(_ messages: [[String: Any]]) -> [(role: String, content: String)] {
        var result: [(role: String, content: String)] = []
        var pendingSystem = ""
        for m in messages {
            let role = m["role"] as? String ?? "user"
            let content = extractContent(m["content"])
            if role == "system" {
                pendingSystem += content
            } else {
                var text = content
                if role == "user" && !pendingSystem.isEmpty {
                    text = "[System Instructions]\n\(pendingSystem)\n\n\(text)"
                    pendingSystem = ""
                }
                result.append((role, text))
            }
        }
        if !pendingSystem.isEmpty {
            if result.isEmpty {
                result.append(("user", "[System Instructions]\n\(pendingSystem)"))
            } else {
                let last = result.removeLast()
                result.append((last.role, "[System Instructions]\n\(pendingSystem)\n\n\(last.content)"))
            }
        }
        return result
    }

    private static func extractContent(_ content: Any) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String { return text }
                return nil
            }.joined()
        }
        return ""
    }

    // MARK: - 二进制帧流 → SSE 流

    /// 把 Cursor 二进制帧流转换成 OpenAI SSE 流。非 2xx 时把错误 body 透传（反向代理语义）。
    static func rpcSSEStream(for request: URLRequest, model: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var processor = CursorSSEProcessor(model: model)
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                        }
                        continuation.yield(errorBody)
                        continuation.finish()
                        return
                    }
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        guard buffer.count >= 8192 else { continue }
                        for sse in processor.consume(buffer) {
                            continuation.yield(sse)
                        }
                        buffer = Data()
                        if processor.finished { break }
                    }
                    if !processor.finished {
                        if !buffer.isEmpty {
                            for sse in processor.consume(buffer) {
                                continuation.yield(sse)
                            }
                        }
                        if !processor.finished {
                            continuation.yield(processor.doneChunkData)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

/// 本机 CPU 架构（`x-cursor-client-arch` 头）。
public enum CursorArch {
    public static var current: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }
}
