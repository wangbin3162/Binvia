import Foundation
import BinviaCore

// BinviaCheck — 自包含可运行测试（无 XCTest 依赖）。
// 本机仅安装 CommandLineTools（无 xctest），`swift test` 不可用，
// 故用可执行 target + 极简断言框架，`swift run BinviaCheck` 即跑全部检查。
// 退出码：0 = 全部通过；1 = 存在失败断言。

// MARK: - 极简断言框架

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String,
                               file: String = #filePath, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name) (\(file):\(line))")
        print("       期望: \(expected)")
        print("       实际: \(actual)")
    }
}

func expectTrue(_ condition: Bool, _ name: String,
                file: String = #filePath, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name) (\(file):\(line)) — 期望为 true")
    }
}

func expectFalse(_ condition: Bool, _ name: String,
                 file: String = #filePath, line: Int = #line) {
    expectTrue(!condition, name, file: file, line: line)
}

func expectNil<T>(_ value: T?, _ name: String,
                  file: String = #filePath, line: Int = #line) {
    if value == nil {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name) (\(file):\(line)) — 期望为 nil，实际: \(String(describing: value))")
    }
}

func expectThrows<T>(_ body: () async throws -> T, _ name: String,
                     file: String = #filePath, line: Int = #line) async {
    do {
        _ = try await body()
        failed += 1
        print("FAIL: \(name) (\(file):\(line)) — 期望抛错但未抛出")
    } catch {
        passed += 1
    }
}

/// 运行一个测试套件；套件整体抛出的未预期错误记为一次失败。
func run(_ name: String, _ body: () async throws -> Void) async {
    print("\n--- \(name) ---")
    do {
        try await body()
    } catch {
        failed += 1
        print("FAIL: \(name) — 套件抛出未预期错误: \(error)")
    }
}

// MARK: - Router 路由解析与消歧

func routerTests() {
    ProviderCatalog.registerAll()
    let router = Router(registry: .shared)

    // provider/model 显式
    if let r = router.resolve("deepseek/deepseek-v4-pro") {
        expectEqual(r.providerID, "deepseek", "显式 provider/model 的 provider")
        expectEqual(r.modelID, "deepseek-v4-pro", "显式 provider/model 的 model")
    } else {
        failed += 1
        print("FAIL: deepseek/deepseek-v4-pro 应解析成功")
    }

    // alias/model
    if let r = router.resolve("ds/deepseek-v4-pro") {
        expectEqual(r.providerID, "deepseek", "alias 解析 provider")
        expectEqual(r.modelID, "deepseek-v4-pro", "alias 解析 model")
    } else {
        failed += 1
        print("FAIL: ds/deepseek-v4-pro 应解析成功")
    }

    // 裸模型消歧：deepseek-v4-pro 同时存在于 deepseek 与 codebuddy-cn 静态目录，
    // Router 按前缀优先消歧 → deepseek（而非 codebuddy-cn）。
    if let r = router.resolve("deepseek-v4-pro") {
        expectEqual(r.providerID, "deepseek", "裸模型 deepseek-v4-pro → deepseek（前缀消歧）")
    } else {
        failed += 1
        print("FAIL: 裸模型 deepseek-v4-pro 应解析成功")
    }

    if let r = router.resolve("deepseek-v4-flash") {
        expectEqual(r.providerID, "deepseek", "裸模型 deepseek-v4-flash → deepseek")
    } else {
        failed += 1
        print("FAIL: 裸模型 deepseek-v4-flash 应解析成功")
    }

    // cbcn/glm-5.2 → codebuddy-cn；裸 glm-5.2 → codebuddy-cn
    if let r = router.resolve("cbcn/glm-5.2") {
        expectEqual(r.providerID, "codebuddy-cn", "cbcn alias 解析 provider")
        expectEqual(r.modelID, "glm-5.2", "cbcn alias 解析 model")
    } else {
        failed += 1
        print("FAIL: cbcn/glm-5.2 应解析成功")
    }
    if let r = router.resolve("glm-5.2") {
        expectEqual(r.providerID, "codebuddy-cn", "裸模型 glm-5.2 → codebuddy-cn")
    } else {
        failed += 1
        print("FAIL: 裸模型 glm-5.2 应解析成功")
    }

    // 未知 / 空输入
    expectNil(router.resolve("nope/x"), "未知 provider 返回 nil")
    expectNil(router.resolve(""), "空字符串返回 nil")
    expectNil(router.resolve("   "), "空白字符串返回 nil")
}

// MARK: - SSEParser / SSEJSONAggregator

func sseTests() async throws {
    // 跨 chunk 切分：前一段不应输出
    var parser = SSEParser()
    let first = parser.append(Data("data: hello".utf8))
    expectTrue(first.isEmpty, "事件未完整（缺空行）时不应输出")
    let second = parser.append(Data(" world\n\n".utf8))
    expectEqual(second.count, 1, "完整事件输出 1 条")
    expectEqual(second[0], "data: hello world", "事件文本不含末尾换行")

    // 一个 chunk 内多个事件
    var parser2 = SSEParser()
    let events = parser2.append(Data("data: a\n\ndata: b\n\n".utf8))
    expectEqual(events.count, 2, "单 chunk 输出 2 个事件")
    expectEqual(SSEEvent.dataValue(from: events[0]), "a", "事件 a 的 data 值")
    expectEqual(SSEEvent.dataValue(from: events[1]), "b", "事件 b 的 data 值")

    // finish 冲刷剩余 buffer
    var parser3 = SSEParser()
    _ = parser3.append(Data("data: tail".utf8))
    let flushed = parser3.finish()
    expectEqual(flushed, ["data: tail"], "finish 冲刷剩余 buffer")

    // [DONE] 识别
    expectTrue(SSEEvent.isDone("[DONE]"), "[DONE] 识别为结束标记")
    expectFalse(SSEEvent.isDone("hello"), "普通文本非结束标记")

    // SSEJSONAggregator：把 SSE chunk 聚合成 OpenAI JSON
    func sse(_ json: String) -> String { "data: \(json)\n\n" }
    let chunk1 = sse(#"{"id":"chatcmpl-1","model":"glm-5.2","created":123,"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#)
    let chunk2 = sse(#"{"id":"chatcmpl-1","model":"glm-5.2","created":123,"choices":[{"delta":{"content":" world"},"finish_reason":null}]}"#)
    let chunk3 = sse(#"{"id":"chatcmpl-1","model":"glm-5.2","created":123,"choices":[{"delta":{"content":"!"},"finish_reason":"stop"}]}"#)
        + sse("[DONE]")

    let stream = AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(Data(chunk1.utf8))
        continuation.yield(Data(chunk2.utf8))
        continuation.yield(Data(chunk3.utf8))
        continuation.finish()
    }
    let data = try await SSEJSONAggregator.aggregateChatCompletion(stream)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        failed += 1
        print("FAIL: 聚合 JSON 解析失败")
        return
    }
    expectEqual(json["model"] as? String, "glm-5.2", "聚合 model")
    expectEqual(json["id"] as? String, "chatcmpl-1", "聚合 id")
    expectEqual(json["object"] as? String, "chat.completion", "聚合 object")
    if let choices = json["choices"] as? [[String: Any]],
       let first = choices.first,
       let message = first["message"] as? [String: Any] {
        expectEqual(message["content"] as? String, "Hello world!", "聚合 content")
        expectEqual(first["finish_reason"] as? String, "stop", "聚合 finish_reason")
    } else {
        failed += 1
        print("FAIL: 聚合 choices 结构")
    }
}

// MARK: - APIKeyAuthenticator

func apiKeyAuthenticatorTests() {
    let noKeys = APIKeyAuthenticator(configuredKeys: [])
    expectFalse(noKeys.requiresAuthentication, "无配置 key 时 requiresAuthentication = false")
    expectFalse(noKeys.isValid(token: "anything"), "无配置 key 时任何 token 无效")

    let withKeys = APIKeyAuthenticator(configuredKeys: ["secret-1", "secret-2"])
    expectTrue(withKeys.requiresAuthentication, "配置 key 后 requiresAuthentication = true")

    let single = APIKeyAuthenticator(configuredKeys: ["secret-1"])
    expectTrue(single.isValid(token: "secret-1"), "合法 token 通过")
    expectFalse(single.isValid(token: "secret-2"), "非法 token 拒绝")
    expectFalse(single.isValid(token: nil), "nil token 拒绝")
    expectFalse(single.isValid(token: ""), "空 token 拒绝")
    expectFalse(single.isValid(token: "   "), "空白 token 拒绝")

    // Bearer 与 x-api-key 等价
    let viaBearer = HTTPRequest(
        method: "GET", path: "/v1/models", queryItems: [:],
        headers: ["authorization": "Bearer secret-1"], body: nil
    )
    expectEqual(viaBearer.authorizationToken, "secret-1", "Bearer 头解析")
    expectTrue(single.isValid(token: viaBearer.authorizationToken), "Bearer token 有效")

    let viaHeader = HTTPRequest(
        method: "GET", path: "/v1/models", queryItems: [:],
        headers: ["x-api-key": "secret-1"], body: nil
    )
    expectEqual(viaHeader.authorizationToken, "secret-1", "x-api-key 头解析")
    expectTrue(single.isValid(token: viaHeader.authorizationToken), "x-api-key token 有效")

    // Phase 17：旧 sk-tg- key 向后兼容（鉴权只认配置内容，不校验前缀）
    let legacy = APIKeyAuthenticator(configuredKeys: ["sk-tg-legacy-key", "sk-bv-new-key"])
    expectTrue(legacy.isValid(token: "sk-tg-legacy-key"), "旧 sk-tg- key 仍可鉴权")
    expectTrue(legacy.isValid(token: "sk-bv-new-key"), "新 sk-bv- key 可鉴权")
    expectFalse(legacy.isValid(token: "sk-other-key"), "未知前缀 key 拒绝")
}

// MARK: - RouteConfig

func routeConfigTests() throws {
    // 默认值
    let defaults = RouteConfig()
    expectEqual(defaults.version, 2, "默认 version")
    expectEqual(defaults.host, "127.0.0.1", "默认 host")
    expectEqual(defaults.port, 8231, "默认 port")
    expectEqual(defaults.apiKeys, [], "默认 apiKeys 为空")
    expectEqual(defaults.providers, [:], "默认 providers 为空")

    // credential 优先 config 而非 env
    unsetenv("DEEPSEEK_API_KEY")
    setenv("DEEPSEEK_API_KEY", "env-key", 1)
    let cfg1 = RouteConfig(providers: [
        "deepseek": ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "config-key"), apiKeys: [])
    ])
    expectEqual(cfg1.credential(for: "deepseek").apiKey, "config-key", "credential 优先 config")

    // credential 回退 env
    let cfg2 = RouteConfig(providers: [:])
    expectEqual(cfg2.credential(for: "deepseek").apiKey, "env-key", "credential 回退 env")
    unsetenv("DEEPSEEK_API_KEY")

    // apiKeys：config 数组 + env 合并、去重、过滤空值
    setenv("DEEPSEEK_API_KEY", "env-key", 1)
    let cfg3 = RouteConfig(providers: [
        "deepseek": ProviderConfig(enabled: true, credential: ProviderCredential(), apiKeys: ["cfg-a", "env-key"])
    ])
    expectEqual(cfg3.apiKeys(for: "deepseek"), ["cfg-a", "env-key"], "apiKeys 合并 config 与 env 并去重")

    // apiKeys 仅 env
    setenv("DEEPSEEK_API_KEY", "only-env", 1)
    let cfg4 = RouteConfig()
    expectEqual(cfg4.apiKeys(for: "deepseek"), ["only-env"], "apiKeys 仅 env")
    unsetenv("DEEPSEEK_API_KEY")

    // 旧格式 JSON 解码（无 apiKeys 字段 → 回退空数组）
    let legacy = #"{"enabled": true, "credential": {"apiKey": "legacy-key"}}"#
    let decoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacy.utf8))
    expectEqual(decoded.enabled, true, "legacy enabled")
    expectEqual(decoded.credential.apiKey, "legacy-key", "legacy credential apiKey")
    expectEqual(decoded.apiKeys, [], "legacy apiKeys 回退空数组")

    // round trip
    let pc = ProviderConfig(enabled: false, credential: ProviderCredential(apiKey: "k", accessToken: "t"), apiKeys: ["a", "b"])
    let pcData = try JSONEncoder().encode(pc)
    let pcDecoded = try JSONDecoder().decode(ProviderConfig.self, from: pcData)
    expectEqual(pcDecoded, pc, "ProviderConfig round trip")

    let rc = RouteConfig(
        version: 1, host: "0.0.0.0", port: 9999,
        apiKeys: [GatewayKeyConfig(key: "router-key", enabledModels: ["ds/deepseek-v4-pro"])],
        providers: ["deepseek": ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "k"), apiKeys: ["a"])]
    )
    let rcData = try JSONEncoder().encode(rc)
    let rcDecoded = try JSONDecoder().decode(RouteConfig.self, from: rcData)
    expectEqual(rcDecoded, rc, "RouteConfig round trip")
}

// MARK: - ProviderRegistry 反向索引 + Router 消歧升级（Phase 12）

func registryReverseIndexTests() {
    ProviderCatalog.registerAll()
    let registry = ProviderRegistry.shared

    // deepseek-v4-pro 同时存在于 deepseek 与 codebuddy-cn 静态目录
    let owners = registry.providers(forModel: "deepseek-v4-pro")
    expectEqual(Set(owners), Set(["codebuddy-cn", "deepseek"]), "反向索引: deepseek-v4-pro 归属两家")

    // 单 provider 模型
    expectEqual(registry.providers(forModel: "glm-5.2"), ["codebuddy-cn"], "反向索引: glm-5.2 单归属")
    expectEqual(registry.providers(forModel: "gemini-3.6-flash-high"), ["antigravity"], "反向索引: gemini 单归属")
    expectEqual(registry.providers(forModel: "nope-model"), [], "反向索引: 未知模型空归属")
}

func routerDisambiguationTests() {
    ProviderCatalog.registerAll()
    let router = Router(registry: .shared)

    // 阶段 2：单候选直选（唯一供应商拥有）
    if let r = router.resolve("glm-5.1") {
        expectEqual(r.providerID, "codebuddy-cn", "单候选 glm-5.1 → codebuddy-cn")
    } else {
        failed += 1
        print("FAIL: glm-5.1 应解析成功")
    }

    // 阶段 3：前缀启发式——deepseek-v4-pro 被两家拥有，deepseek-* → deepseek
    if let r = router.resolve("deepseek-v4-pro") {
        expectEqual(r.providerID, "deepseek", "前缀启发式 deepseek-v4-pro → deepseek")
    } else {
        failed += 1
        print("FAIL: deepseek-v4-pro 应解析成功")
    }

    // 阶段 3：前缀启发式——glm 系模型同时出现时 → codebuddy-cn（glm 规则）
    if let r = router.resolve("glm-5.2") {
        expectEqual(r.providerID, "codebuddy-cn", "前缀启发式 glm-5.2 → codebuddy-cn")
    } else {
        failed += 1
        print("FAIL: glm-5.2 应解析成功")
    }

    // 显式前缀仍最高优先
    if let r = router.resolve("codebuddy-cn/deepseek-v4-pro") {
        expectEqual(r.providerID, "codebuddy-cn", "显式前缀 codebuddy-cn/deepseek-v4-pro → codebuddy-cn")
        expectEqual(r.modelID, "deepseek-v4-pro", "显式前缀 model 透传")
    } else {
        failed += 1
        print("FAIL: codebuddy-cn/deepseek-v4-pro 应解析成功")
    }
}

// MARK: - 配置 v1→v2 迁移（Phase 12）

func configMigrationTests() throws {
    let path = "/tmp/binvia-migration-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: path) }
    // v1 配置：apiKeys 是字符串数组
    let v1 = #"""
    {"version":1,"host":"127.0.0.1","port":8231,"apiKeys":["legacy-key-1","legacy-key-2"],"providers":{}}
    """#
    try Data(v1.utf8).write(to: URL(fileURLWithPath: path))

    let migrated = try ConfigStore.load(path: path)
    expectEqual(migrated.version, 2, "迁移后 version=2")
    expectEqual(migrated.gatewayKeyStrings, ["legacy-key-1", "legacy-key-2"], "旧字符串数组转为 GatewayKeyConfig")
    expectEqual(migrated.apiKeys[0].enabledModels, nil, "迁移后 enabledModels 为 nil（全部启用）")

    // 备份文件已生成
    expectTrue(FileManager.default.fileExists(atPath: path + ".v1.bak"), "迁移前已备份 v1 配置文件")

    // 二次加载不重复迁移（backup 不覆盖）
    let again = try ConfigStore.load(path: path)
    expectEqual(again.version, 2, "二次加载仍为 v2")
    expectEqual(again.gatewayKeyStrings, ["legacy-key-1", "legacy-key-2"], "二次加载 key 不变")

    // v2 格式直接解码（无需迁移）
    let v2 = #"""
    {"version":2,"apiKeys":[{"key":"sk-bv-abc","enabled_models":["ds/deepseek-v4-pro"]}]}
    """#
    let v2Decoder = JSONDecoder()
    v2Decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try v2Decoder.decode(RouteConfig.self, from: Data(v2.utf8))
    expectEqual(decoded.version, 2, "v2 直接解码 version")
    expectEqual(decoded.apiKeys.first?.key, "sk-bv-abc", "v2 解码 key")
    expectEqual(decoded.apiKeys.first?.enabledModels, ["ds/deepseek-v4-pro"], "v2 解码 enabledModels")
}

// MARK: - 网关 key 级 enabledModels 过滤（Phase 12）

func gatewayKeyWhitelistTests() async throws {
    ProviderCatalog.registerAll()
    unsetenv("DEEPSEEK_API_KEY")
    unsetenv("DEEPSEEK_BASE_URL")
    await ModelCache.shared.invalidate("deepseek")

    let config = RouteConfig(
        host: "127.0.0.1", port: 0,
        apiKeys: [
            GatewayKeyConfig(key: "whitelisted-key", enabledModels: ["ds/deepseek-v4-pro"]),
            GatewayKeyConfig(key: "open-key"),
        ]
    )
    let handler = RouteHandler(config: config)

    func req(_ method: String, _ path: String, authorization: String? = nil, body: Data? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let authorization { headers["authorization"] = authorization }
        return HTTPRequest(method: method, path: path, queryItems: [:], headers: headers, body: body)
    }
    func chatBody(model: String) -> Data {
        Data(#"{"model": "\#(model)", "messages": [{"role": "user", "content": "hi"}]}"#.utf8)
    }

    // 白名单命中 → 进入上游（无凭据/不可达上游 → 502，而非 403）
    let allowed = try await handler.handle(req(
        "POST", "/v1/chat/completions",
        authorization: "Bearer whitelisted-key", body: chatBody(model: "ds/deepseek-v4-pro")
    ))
    expectEqual(allowed.status, 502, "白名单内模型应进入上游（无凭据 → 502 而非 403）")

    // 白名单未命中 → 403
    let forbidden = try await handler.handle(req(
        "POST", "/v1/chat/completions",
        authorization: "Bearer whitelisted-key", body: chatBody(model: "ds/deepseek-v4-flash")
    ))
    expectEqual(forbidden.status, 403, "白名单外模型返回 403")

    // 无白名单的 key → 不拦截
    let open = try await handler.handle(req(
        "POST", "/v1/chat/completions",
        authorization: "Bearer open-key", body: chatBody(model: "ds/deepseek-v4-flash")
    ))
    expectEqual(open.status, 502, "无白名单 key 不拦截（无凭据 → 502）")

    // /v1/models 白名单过滤：白名单 key 只看到 whitelisted 模型
    let modelsResp = try await handler.handle(req("GET", "/v1/models", authorization: "Bearer whitelisted-key"))
    if let data = modelsResp.bodyData(),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let models = json["data"] as? [[String: Any]] ?? []
        let ids = Set(models.compactMap { $0["id"] as? String })
        expectTrue(ids.contains("deepseek-v4-pro"), "白名单 key 的 /v1/models 包含 deepseek-v4-pro")
        expectFalse(ids.contains("deepseek-v4-flash"), "白名单 key 的 /v1/models 不含 deepseek-v4-flash")
    } else {
        failed += 1
        print("FAIL: /v1/models 白名单过滤响应解析失败")
    }

    // 无白名单 key 的 /v1/models 不受影响
    let openModelsResp = try await handler.handle(req("GET", "/v1/models", authorization: "Bearer open-key"))
    if let data = openModelsResp.bodyData(),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let models = json["data"] as? [[String: Any]] ?? []
        expectTrue(models.contains { ($0["id"] as? String) == "deepseek-v4-flash" }, "无白名单 key 的 /v1/models 含 deepseek-v4-flash")
    } else {
        failed += 1
        print("FAIL: 无白名单 key 的 /v1/models 响应解析失败")
    }
}

extension HTTPResponse {
    /// 便捷取 data body（测试用）。
    func bodyData() -> Data? {
        if case .data(let d) = body { return d }
        return nil
    }
}

// MARK: - ModelCache

func modelCacheTests() async {
    let cache = ModelCache()
    let models = [Model(id: "glm-5.2", name: "GLM-5.2")]
    await cache.set("deepseek", models: models)
    let fetched = await cache.get("deepseek", ttl: 300)
    expectEqual(fetched, models, "set 后 get 命中")

    let miss = await cache.get("never-set", ttl: 300)
    expectNil(miss, "未知 key miss")

    await cache.set("deepseek", models: [Model(id: "m1")])
    let expired = await cache.get("deepseek", ttl: 0)
    expectNil(expired, "ttl=0 视为已过期")

    await cache.set("deepseek", models: [Model(id: "m1")])
    await cache.invalidate("deepseek")
    let invalidated = await cache.get("deepseek", ttl: 300)
    expectNil(invalidated, "invalidate 后 miss")

    await ModelCache.shared.invalidate("deepseek")
    await ModelCache.shared.set("deepseek", models: [Model(id: "m1")])
    let sharedFetched = await ModelCache.shared.get("deepseek", ttl: 300)
    expectEqual(sharedFetched?.first?.id, "m1", "shared 缓存可用")
}

// MARK: - RequestLogger

func requestLoggerTests() {
    let logger = RequestLogger()
    let now = Date()
    logger.log(RequestLogEntry(timestamp: now, method: "POST", path: "/v1/chat/completions",
                               providerID: "deepseek", model: "deepseek-v4-pro",
                               statusCode: 200, durationMS: 100))
    logger.log(RequestLogEntry(timestamp: now, method: "POST", path: "/v1/chat/completions",
                               providerID: "deepseek", model: "deepseek-v4-pro",
                               statusCode: 502, durationMS: 200, error: "upstream error"))
    logger.log(RequestLogEntry(timestamp: now, method: "POST", path: "/v1/chat/completions",
                               providerID: "codebuddy-cn", model: "glm-5.2",
                               statusCode: 200, durationMS: 50))
    logger.log(RequestLogEntry(timestamp: now, method: "GET", path: "/v1/health",
                               providerID: nil, model: nil,
                               statusCode: 200, durationMS: 1))

    let summary = logger.summary()
    expectEqual(summary.byProvider.count, 3, "byProvider 聚合 3 个 provider")
    let deepseek = summary.byProvider["deepseek"]
    expectEqual(deepseek?.requestCount, 2, "deepseek requestCount")
    expectEqual(deepseek?.errorCount, 1, "deepseek errorCount")
    expectEqual(deepseek?.totalDurationMS, 300, "deepseek totalDurationMS")
    expectEqual(deepseek?.models["deepseek-v4-pro"], 2, "deepseek models 计数")
    let cbcn = summary.byProvider["codebuddy-cn"]
    expectEqual(cbcn?.requestCount, 1, "cbcn requestCount")
    expectEqual(cbcn?.errorCount, 0, "cbcn errorCount")
    expectEqual(cbcn?.models["glm-5.2"], 1, "cbcn models 计数")
    let unknown = summary.byProvider["unknown"]
    expectEqual(unknown?.requestCount, 1, "unknown requestCount")

    let logger2 = RequestLogger()
    logger2.log(RequestLogEntry(timestamp: Date(), method: "GET", path: "/v1/usage",
                                providerID: nil, model: nil, statusCode: 200, durationMS: 5))
    expectEqual(logger2.allEntries().count, 1, "allEntries count")
    expectEqual(logger2.allEntries().first?.path, "/v1/usage", "allEntries path")
}

// MARK: - ProviderHTTPClient 重试

func httpRetryTests() async throws {
    // 1) 503 + Retry-After:0 → 重试后成功，请求计数=2
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        if URLProtocolMock.requestCount == 1 {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503, httpVersion: nil,
                headerFields: ["Retry-After": "0"]
            )!
            return (response, Data("busy".utf8))
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (response, Data("ok".utf8))
    }
    let client = ProviderHTTPClient(session: URLProtocolMock.makeSession())
    var request = URLRequest(url: URL(string: "https://mock.test/v1/models")!)
    request.httpMethod = "GET"
    let policy = ProviderHTTPRetryPolicy(maxRetries: 1, retryableStatusCodes: [503], baseDelay: 0, maxDelay: 0)
    let (data, response) = try await client.data(for: request, retryPolicy: policy)
    expectEqual(response.statusCode, 200, "503 重试后返回 200")
    expectEqual(String(data: data, encoding: .utf8), "ok", "重试后 body 为 ok")
    expectEqual(URLProtocolMock.requestCount, 2, "503 重试请求计数为 2")

    // 2) 401 不重试
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
        )!
        return (response, Data("unauthorized".utf8))
    }
    let client2 = ProviderHTTPClient(session: URLProtocolMock.makeSession())
    var request2 = URLRequest(url: URL(string: "https://mock.test/v1/models")!)
    request2.httpMethod = "GET"
    let policy2 = ProviderHTTPRetryPolicy(maxRetries: 3, retryableStatusCodes: [503], baseDelay: 0, maxDelay: 0)
    let (data2, response2) = try await client2.data(for: request2, retryPolicy: policy2)
    expectEqual(response2.statusCode, 401, "401 不重试")
    expectEqual(String(data: data2, encoding: .utf8), "unauthorized", "401 body 原样返回")
    expectEqual(URLProtocolMock.requestCount, 1, "401 请求计数为 1")

    // 3) POST 非幂等不重试
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil,
            headerFields: ["Retry-After": "0"]
        )!
        return (response, Data("busy".utf8))
    }
    let client3 = ProviderHTTPClient(session: URLProtocolMock.makeSession())
    var request3 = URLRequest(url: URL(string: "https://mock.test/v1/chat/completions")!)
    request3.httpMethod = "POST"
    let policy3 = ProviderHTTPRetryPolicy(maxRetries: 3, retryableStatusCodes: [503], baseDelay: 0, maxDelay: 0)
    let (_, response3) = try await client3.data(for: request3, retryPolicy: policy3)
    expectEqual(response3.statusCode, 503, "POST 503 不重试")
    expectEqual(URLProtocolMock.requestCount, 1, "POST 请求计数为 1")

    // 4) Retry-After: 0.001 覆盖指数退避（baseDelay 10），避免等待
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 503, httpVersion: nil,
            headerFields: ["Retry-After": "0.001"]
        )!
        return (response, Data("busy".utf8))
    }
    let client4 = ProviderHTTPClient(session: URLProtocolMock.makeSession())
    var request4 = URLRequest(url: URL(string: "https://mock.test/v1/models")!)
    request4.httpMethod = "GET"
    let policy4 = ProviderHTTPRetryPolicy(maxRetries: 1, retryableStatusCodes: [503], baseDelay: 10, maxDelay: 10)
    let (_, response4) = try await client4.data(for: request4, retryPolicy: policy4)
    expectEqual(response4.statusCode, 503, "Retry-After 测试最终返回 503")
    expectEqual(URLProtocolMock.requestCount, 2, "Retry-After 覆盖退避，请求计数为 2")
    URLProtocolMock.reset()
}

// MARK: - RouteHandler 路由分发

func routeHandlerTests() async throws {
    ProviderCatalog.registerAll()
    // 清理环境变量与缓存，避免残留导致 /v1/models 真实打上游
    unsetenv("DEEPSEEK_API_KEY")
    unsetenv("DEEPSEEK_BASE_URL")
    unsetenv("CODEBUDDY_CN_ACCESS_TOKEN")
    await ModelCache.shared.invalidate("deepseek")
    let config = RouteConfig(host: "127.0.0.1", port: 0, apiKeys: [GatewayKeyConfig(key: "test-key")])
    let handler = RouteHandler(config: config)

    func req(_ method: String, _ path: String, authorization: String? = nil, body: Data? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let authorization { headers["authorization"] = authorization }
        return HTTPRequest(method: method, path: path, queryItems: [:], headers: headers, body: body)
    }
    func chatBody(model: String) -> Data {
        Data(#"{"model": "\#(model)", "messages": [{"role": "user", "content": "hi"}]}"#.utf8)
    }
    func bodyData(_ response: HTTPResponse) -> Data? {
        if case .data(let d) = response.body { return d }
        return nil
    }

    // /v1/models 认证
    let noKey = try await handler.handle(req("GET", "/v1/models"))
    expectEqual(noKey.status, 401, "无 key 访问 /v1/models 返回 401")

    let withKey = try await handler.handle(req("GET", "/v1/models", authorization: "Bearer test-key"))
    expectEqual(withKey.status, 200, "带 key 访问 /v1/models 返回 200")
    if let data = bodyData(withKey),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let models = json["data"] as? [[String: Any]] ?? []
        expectFalse(models.isEmpty, "模型列表不应为空")
        expectTrue(models.contains { ($0["id"] as? String) == "glm-5.2" }, "模型列表应包含 glm-5.2")
    } else {
        failed += 1
        print("FAIL: /v1/models 响应 JSON 解析失败")
    }

    // /v1/chat/completions 路由
    let unknown = try await handler.handle(req(
        "POST", "/v1/chat/completions",
        authorization: "Bearer test-key", body: chatBody(model: "nope/nope")
    ))
    expectEqual(unknown.status, 404, "未知模型 chat 返回 404")

    // codebuddy-cn 是 OAuth 型，无凭据时抛 missingCredentials → 502
    let oauthNoCred = try await handler.handle(req(
        "POST", "/v1/chat/completions",
        authorization: "Bearer test-key", body: chatBody(model: "codebuddy-cn/glm-5.2")
    ))
    expectEqual(oauthNoCred.status, 502, "codebuddy-cn 无凭据 chat 返回 502")

    // 不可达上游：handle 取首个 chunk 时失败，直接返回 502（避免 200 后出错）。
    setenv("DEEPSEEK_API_KEY", "test", 1)
    setenv("DEEPSEEK_BASE_URL", "http://127.0.0.1:1/v1", 1)
    let unreachable = try await handler.handle(req(
        "POST", "/v1/chat/completions",
        authorization: "Bearer test-key", body: chatBody(model: "ds/deepseek-v4-pro")
    ))
    expectEqual(unreachable.status, 502, "上游不可达时 handle 直接返回 502")
    unsetenv("DEEPSEEK_API_KEY")
    unsetenv("DEEPSEEK_BASE_URL")

    // 其他端点
    let health = try await handler.handle(req("GET", "/v1/health"))
    expectEqual(health.status, 200, "/v1/health 返回 200")
    let usage = try await handler.handle(req("GET", "/v1/usage", authorization: "Bearer test-key"))
    expectEqual(usage.status, 200, "/v1/usage 返回 200")
    let nope = try await handler.handle(req("GET", "/v1/nope"))
    expectEqual(nope.status, 404, "未知路径返回 404")
}

// MARK: - DeepSeek 集成（本地 HTTPServer 当 mock 上游）

func sseChunk(_ json: String) -> String { "data: \(json)\n\n" }

/// mock 上游：GET /v1/models 返回模型列表；其余（chat）返回 SSE。
let mockUpstreamHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
    if request.method == "GET", request.path == "/v1/models" {
        return HTTPResponse.text(
            200,
            #"{"data":[{"id":"mock-model-1","owned_by":"mock"}]}"#,
            contentType: "application/json"
        )
    }
    let sse =
        sseChunk(#"{"id":"chatcmpl-mock","model":"deepseek-v4-pro","created":1,"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-mock","model":"deepseek-v4-pro","created":1,"choices":[{"delta":{"content":" there"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-mock","model":"deepseek-v4-pro","created":1,"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        + sseChunk("[DONE]")
    return HTTPResponse.text(200, sse, contentType: "text/event-stream")
}

func deepSeekIntegrationTests() async throws {
    // 0) 无凭据时 chat 应同步抛 missingCredentials
    unsetenv("DEEPSEEK_API_KEY")
    unsetenv("DEEPSEEK_BASE_URL")
    let noCredRequest = ChatRequest(
        model: "deepseek-v4-pro",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
await expectThrows({ _ = try await DeepSeekProvider().chat(request: noCredRequest, rawBody: nil, credential: nil) },
"无凭据时 DeepSeek chat 抛 missingCredentials")

    // 启动本地 mock 上游（真实 socket + HTTP）
    let server = HTTPServer(handler: mockUpstreamHandler)
    var port: Int?
    var lastError: Error?
    for _ in 0 ..< 3 {
        let candidate = Int.random(in: 20_000 ... 40_000)
        do {
            try server.start(host: "127.0.0.1", port: candidate)
            port = candidate
            break
        } catch {
            lastError = error
        }
    }
    guard let port else {
        failed += 1
        print("FAIL: 无法启动 mock 上游端口: \(String(describing: lastError))")
        return
    }
    defer {
        unsetenv("DEEPSEEK_API_KEY")
        unsetenv("DEEPSEEK_BASE_URL")
    }

    setenv("DEEPSEEK_API_KEY", "mock-key", 1)
    setenv("DEEPSEEK_BASE_URL", "http://127.0.0.1:\(port)/v1", 1)
    await ModelCache.shared.invalidate("deepseek")

    // 1) listModels 命中 mock 上游（而非回退静态目录）
    let models = try await DeepSeekProvider().listModels(credential: nil)
    expectEqual(models.map(\.id), ["mock-model-1"], "listModels 命中 mock 上游")

    // 2) 缓存命中：把 base URL 改成不可达端口，二次调用仍返回缓存
    setenv("DEEPSEEK_BASE_URL", "http://127.0.0.1:1/v1", 1)
    let cached = try await DeepSeekProvider().listModels(credential: nil)
    expectEqual(cached.map(\.id), ["mock-model-1"], "listModels 二次调用命中缓存（不访问网络）")
    setenv("DEEPSEEK_BASE_URL", "http://127.0.0.1:\(port)/v1", 1)

    // 3) chat stream=true 透传 SSE（含内容块与 [DONE]）
    let streamRequest = ChatRequest(
        model: "deepseek-v4-pro",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let stream = try await DeepSeekProvider().chat(request: streamRequest, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hi""#), "SSE 应包含 Hi 内容块，实际: \(text)")
    expectTrue(text.contains("[DONE]"), "SSE 应包含 [DONE]")

    // 4) chat stream=false 仍透传上游 SSE，且可被 SSEJSONAggregator 聚合成 JSON
    let nonStreamRequest = ChatRequest(
        model: "deepseek-v4-pro",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: false
    )
    let nonStream = try await DeepSeekProvider().chat(request: nonStreamRequest, rawBody: nil, credential: nil)
    var raw = Data()
    for try await chunk in nonStream { raw.append(chunk) }
    expectFalse(raw.isEmpty, "非流式请求也应透传上游数据")
    let rawText = String(data: raw, encoding: .utf8) ?? ""
    expectTrue(rawText.contains(#""content":"Hi""#), "非流式透传 SSE 应包含 Hi")

    let aggStream = AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(raw)
        continuation.finish()
    }
    let aggregated = try await SSEJSONAggregator.aggregateChatCompletion(aggStream)
    if let json = try? JSONSerialization.jsonObject(with: aggregated) as? [String: Any],
       let choices = json["choices"] as? [[String: Any]],
       let first = choices.first,
       let message = first["message"] as? [String: Any] {
        expectEqual(message["content"] as? String, "Hi there", "SSE 聚合内容为 'Hi there'")
    } else {
        failed += 1
        print("FAIL: 聚合 JSON 结构")
    }

    await ModelCache.shared.invalidate("deepseek")
}

// MARK: - Antigravity 集成（本地 HTTPServer 当 mock 上游）

/// Antigravity mock 上游共享状态：记录 fetchAvailableModels 请求体，可注入状态码。
private final class AntigravityMockState: @unchecked Sendable {
    static let shared = AntigravityMockState()
    private let lock = NSLock()
    private var body: String?
    private var count = 0
    private var status = 200

    var fetchAvailableModelsBody: String? {
        lock.lock(); defer { lock.unlock() }
        return body
    }

    var fetchAvailableModelsCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    var fetchAvailableModelsStatus: Int {
        get { lock.lock(); defer { lock.unlock() }; return status }
        set { lock.lock(); defer { lock.unlock() }; status = newValue }
    }

    func record(body: Data) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        self.body = String(data: body, encoding: .utf8)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        body = nil
        count = 0
        status = 200
    }
}

/// Antigravity mock 上游：仅处理 `/v1internal:fetchAvailableModels`。
private let antigravityMockHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
    guard request.path == "/v1internal:fetchAvailableModels" else {
        return HTTPResponse.text(404, "not found")
    }
    AntigravityMockState.shared.record(body: request.body ?? Data())
    let status = AntigravityMockState.shared.fetchAvailableModelsStatus
    guard status == 200 else {
        return HTTPResponse.text(
            status,
            #"{"error":{"code":\#(status),"message":"Unknown name \"metadata\""}}"#,
            contentType: "application/json"
        )
    }
    return HTTPResponse.text(
        200,
        #"{"models":{"mock-gemini-3.6-flash-high":{},"mock-claude-sonnet-4-6":{}}}"#,
        contentType: "application/json"
    )
}

func antigravityIntegrationTests() async throws {
    AntigravityMockState.shared.reset()
    unsetenv("ANTIGRAVITY_BASE_URL")
    unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
    unsetenv("ANTIGRAVITY_PROJECT_ID")

    // 启动本地 mock 上游（真实 socket + HTTP）
    let server = HTTPServer(handler: antigravityMockHandler)
    var port: Int?
    var lastError: Error?
    for _ in 0 ..< 3 {
        let candidate = Int.random(in: 40_000 ... 60_000)
        do {
            try server.start(host: "127.0.0.1", port: candidate)
            port = candidate
            break
        } catch {
            lastError = error
        }
    }
    guard let port else {
        failed += 1
        print("FAIL: Antigravity 无法启动 mock 上游端口: \(String(describing: lastError))")
        return
    }
    defer {
        server.stop()
        unsetenv("ANTIGRAVITY_BASE_URL")
        unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
        AntigravityMockState.shared.reset()
    }

    setenv("ANTIGRAVITY_BASE_URL", "http://127.0.0.1:\(port)", 1)
    let credential = ProviderCredential(accessToken: "mock-token")

    // 1) testConnection 走 fetchAvailableModels：请求体必须为空对象 {}。
    //    回归：此前误带 `{"metadata":{"ideType":"ANTIGRAVITY"}}`（loadCodeAssist 字段），
    //    被上游 protobuf JSON 拒绝返回 400。
    let result = try await AntigravityProvider().testConnection(credential: credential)
    expectTrue(result.success, "mock 上游 200 时 testConnection 应成功，实际: \(result.message)")
    expectEqual(AntigravityMockState.shared.fetchAvailableModelsCount, 1, "testConnection 应请求 1 次 fetchAvailableModels")
    expectEqual(AntigravityMockState.shared.fetchAvailableModelsBody, "{}", "fetchAvailableModels 请求体应为空对象 {}")

    // 2) 上游 400（Google 错误格式）时 testConnection 失败，且消息提取可读 error.message。
    AntigravityMockState.shared.reset()
    AntigravityMockState.shared.fetchAvailableModelsStatus = 400
    let failResult = try await AntigravityProvider().testConnection(credential: credential)
    expectFalse(failResult.success, "上游 400 时 testConnection 应失败")
    expectTrue(failResult.message.contains("Unknown name"), "400 消息应提取上游 error.message，实际: \(failResult.message)")
}

// MARK: - 入口

// 隔离本机真实配置文件，保证测试确定性（BINVIA_CONFIG 指向不存在的临时路径）
let checkConfigPath = "/tmp/binvia-check-config.json"
try? FileManager.default.removeItem(atPath: checkConfigPath)
unsetenv("BINVIA_CONFIG")
setenv("BINVIA_CONFIG", checkConfigPath, 1)

// 清理可能残留的环境变量
unsetenv("DEEPSEEK_API_KEY")
unsetenv("DEEPSEEK_BASE_URL")
unsetenv("CODEBUDDY_CN_ACCESS_TOKEN")
unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
unsetenv("ANTIGRAVITY_BASE_URL")
unsetenv("ANTIGRAVITY_PROJECT_ID")

await run("Router 路由解析与消歧", routerTests)
await run("ProviderRegistry 反向索引", registryReverseIndexTests)
await run("Router 消歧升级", routerDisambiguationTests)
await run("配置 v1→v2 迁移", configMigrationTests)
await run("网关 key 白名单过滤", gatewayKeyWhitelistTests)
await run("SSE 解析与聚合", sseTests)
await run("APIKey 认证", apiKeyAuthenticatorTests)
await run("RouteConfig 配置", routeConfigTests)
await run("ModelCache 缓存", modelCacheTests)
await run("RequestLogger 日志聚合", requestLoggerTests)
await run("ProviderHTTPClient 重试", httpRetryTests)
await run("RouteHandler 路由分发", routeHandlerTests)
await run("DeepSeek 集成（本地 mock 上游）", deepSeekIntegrationTests)
await run("Antigravity 集成（本地 mock 上游）", antigravityIntegrationTests)

print("")
print("========================================")
print("BinviaCheck 完成: passed=\(passed), failed=\(failed)")
if failed > 0 {
    print("存在 \(failed) 个失败断言")
    exit(1)
}
print("全部通过")
exit(0)
