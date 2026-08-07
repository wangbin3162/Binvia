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

/// 构造带标签令牌的便捷函数（测试用）：空标签自动生成掩码标签。
func kt(_ value: String, label: String = "") -> KeyedToken {
    label.isEmpty ? KeyedToken(value: value) : KeyedToken(label: label, value: value)
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
    expectEqual(defaults.host, "localhost", "默认 host")
    expectEqual(defaults.port, 20427, "默认 port")
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
        "deepseek": ProviderConfig(enabled: true, credential: ProviderCredential(), apiKeys: [kt("cfg-a"), kt("env-key")])
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

    // 旧格式 apiKeys: [String] → 自动迁移为 KeyedToken（掩码标签）
    let legacyKeys = #"{"enabled": true, "apiKeys": ["sk-abcdef1234567890"]}"#
    let legacyKeysDecoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacyKeys.utf8))
    expectEqual(legacyKeysDecoded.apiKeyValues, ["sk-abcdef1234567890"], "旧 [String] apiKeys 迁移为 KeyedToken")
    expectEqual(legacyKeysDecoded.apiKeys.first?.label, "sk-abc••••7890", "旧 key 自动生成掩码标签")
    expectEqual(KeyedToken.defaultLabel(for: "sk-abcdef1234567890"), "sk-abc••••7890", "掩码标签规则（前6后4）")
    // 新格式 {label,value} 解码
    let newFormat = #"{"enabled": true, "apiKeys": [{"label": "主 Key", "value": "sk-xyz"}]}"#
    let newFormatDecoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(newFormat.utf8))
    expectEqual(newFormatDecoded.apiKeys.first?.label, "主 Key", "新版 {label,value} 解码标签")
    expectEqual(newFormatDecoded.apiKeys.first?.value, "sk-xyz", "新版 {label,value} 解码值")

    // round trip（含 KeyedToken 标签）
    let pc = ProviderConfig(enabled: false, credential: ProviderCredential(apiKey: "k", accessToken: "t"), apiKeys: [kt("a", label: "主"), kt("b")])
    let pcData = try JSONEncoder().encode(pc)
    let pcDecoded = try JSONDecoder().decode(ProviderConfig.self, from: pcData)
    expectEqual(pcDecoded, pc, "ProviderConfig round trip")
    expectEqual(pcDecoded.apiKeyValues, ["a", "b"], "apiKeyValues 返回全部令牌值")

    let rc = RouteConfig(
        version: 1, host: "0.0.0.0", port: 9999,
        apiKeys: [GatewayKeyConfig(key: "router-key", enabledModels: ["ds/deepseek-v4-pro"])],
        providers: ["deepseek": ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "k"), apiKeys: [kt("a")])]
    )
    let rcData = try JSONEncoder().encode(rc)
    let rcDecoded = try JSONDecoder().decode(RouteConfig.self, from: rcData)
    expectEqual(rcDecoded, rc, "RouteConfig round trip")

    // Phase 20: credential(for:) 把 apiKeys[0] 合并进 credential.apiKey（GUI 单 key 存 apiKeys[]）
    let cfg5 = RouteConfig(providers: [
        "opencode": ProviderConfig(enabled: true, credential: ProviderCredential(), apiKeys: [kt("gui-key")])
    ])
    expectEqual(cfg5.credential(for: "opencode").apiKey, "gui-key", "credential(for:) 合并 apiKeys[0]")

    // Phase 20 补充: enabled=false 也应返回已保存凭据（禁用态仍可测试模型）
    let cfg5b = RouteConfig(providers: [
        "opencode": ProviderConfig(enabled: false, credential: ProviderCredential(), apiKeys: [kt("gui-key")])
    ])
    expectEqual(cfg5b.credential(for: "opencode").apiKey, "gui-key", "禁用态仍返回合并后的凭据")

    // 已显式配置 credential.apiKey 时不被 apiKeys[] 覆盖
    let cfg6 = RouteConfig(providers: [
        "deepseek": ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "explicit"), apiKeys: [kt("first-rotation")])
    ])
    expectEqual(cfg6.credential(for: "deepseek").apiKey, "explicit", "显式 apiKey 优先于 apiKeys[]")

    // Phase 20: credential(for:) 透传 ProviderConfig.region
    let cfg7 = RouteConfig(providers: [
        "zai": ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "k"), apiKeys: [], region: "global")
    ])
    expectEqual(cfg7.credential(for: "zai").region, "global", "credential(for:) 透传 region")
    let cfg8 = RouteConfig(providers: [
        "zai": ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "k"))
    ])
    expectNil(cfg8.credential(for: "zai").region, "未配置 region 时为 nil")

    // Phase 20: ProviderConfig.region 编解码（含旧配置缺省）
    let legacyNoRegion = #"{"enabled": true, "credential": {"apiKey": "k"}, "apiKeys": ["a"]}"#
    let legacyNoRegionDecoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacyNoRegion.utf8))
    expectNil(legacyNoRegionDecoded.region, "旧配置缺 region → nil")
    let regionPC = ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "k"), apiKeys: [], region: "bigmodel-cn")
    let regionPCData = try JSONEncoder().encode(regionPC)
    let regionPCDecoded = try JSONDecoder().decode(ProviderConfig.self, from: regionPCData)
    expectEqual(regionPCDecoded, regionPC, "ProviderConfig region round trip")

    // Phase 20: ProviderCredential 新增字段（email/expiresAt/region）向后兼容编解码
    let legacyCred = #"{"apiKey": "k", "accessToken": "t", "refreshToken": "r"}"#
    let legacyCredDecoded = try JSONDecoder().decode(ProviderCredential.self, from: Data(legacyCred.utf8))
    expectEqual(legacyCredDecoded.apiKey, "k", "legacy credential apiKey")
    expectNil(legacyCredDecoded.email, "旧凭据缺 email → nil")
    expectNil(legacyCredDecoded.expiresAt, "旧凭据缺 expiresAt → nil")
    expectNil(legacyCredDecoded.region, "旧凭据缺 region → nil")
    let fullCred = ProviderCredential(
        apiKey: "k", accessToken: "t", refreshToken: "r",
        email: "user@example.com", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), region: "global")
    let fullCredData = try JSONEncoder().encode(fullCred)
    let fullCredDecoded = try JSONDecoder().decode(ProviderCredential.self, from: fullCredData)
    expectEqual(fullCredDecoded, fullCred, "ProviderCredential 新字段 round trip")
}

// MARK: - ProviderRegistry 反向索引 + Router 消歧升级（Phase 12）

func registryReverseIndexTests() {
    ProviderCatalog.registerAll()
    let registry = ProviderRegistry.shared

    // deepseek-v4-pro 同时存在于 deepseek / codebuddy-cn / opencode（Phase 20 opencode 静态目录
    // 同步线上后新增）静态目录
    let owners = registry.providers(forModel: "deepseek-v4-pro")
    expectEqual(Set(owners), Set(["codebuddy-cn", "deepseek", "opencode"]), "反向索引: deepseek-v4-pro 归属三家")

    // glm-5.2 同时存在于 codebuddy-cn / zai / opencode-go / opencode（Phase 20 opencode 静态目录
    // 同步线上后新增）静态目录
    expectEqual(
        Set(registry.providers(forModel: "glm-5.2")),
        Set(["codebuddy-cn", "zai", "opencode-go", "opencode"]),
        "反向索引: glm-5.2 归属 codebuddy-cn、zai、opencode-go、opencode"
    )
    expectEqual(registry.providers(forModel: "gemini-3.6-flash-high"), ["antigravity"], "反向索引: gemini 单归属")
    expectEqual(registry.providers(forModel: "nope-model"), [], "反向索引: 未知模型空归属")
}

func routerDisambiguationTests() {
    ProviderCatalog.registerAll()
    let router = Router(registry: .shared)

    // 阶段 3：前缀启发式——glm-5.1 被 codebuddy-cn 与 zai 拥有，glm 规则 → codebuddy-cn
    if let r = router.resolve("glm-5.1") {
        expectEqual(r.providerID, "codebuddy-cn", "前缀启发式 glm-5.1 → codebuddy-cn")
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
        ],
        providers: ["deepseek": ProviderConfig(enabled: true)]
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
        expectTrue(ids.contains("ds/deepseek-v4-pro"), "白名单 key 的 /v1/models 包含 ds/deepseek-v4-pro")
        expectFalse(ids.contains("ds/deepseek-v4-flash"), "白名单 key 的 /v1/models 不含 ds/deepseek-v4-flash")
    } else {
        failed += 1
        print("FAIL: /v1/models 白名单过滤响应解析失败")
    }

    // 无白名单 key 的 /v1/models 不受影响
    let openModelsResp = try await handler.handle(req("GET", "/v1/models", authorization: "Bearer open-key"))
    if let data = openModelsResp.bodyData(),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let models = json["data"] as? [[String: Any]] ?? []
        expectTrue(models.contains { ($0["id"] as? String) == "ds/deepseek-v4-flash" }, "无白名单 key 的 /v1/models 含 ds/deepseek-v4-flash")
    } else {
        failed += 1
        print("FAIL: 无白名单 key 的 /v1/models 响应解析失败")
    }
}

// MARK: - 供应商级模型禁用（设置面板「禁用」开关）

/// 禁用模型视为不存在：/v1/models 不展示、chat 请求 404；配置可往返编解码。
func providerModelDisableTests() async throws {
    ProviderCatalog.registerAll()
    unsetenv("DEEPSEEK_API_KEY")
    unsetenv("DEEPSEEK_BASE_URL")
    await ModelCache.shared.invalidate("deepseek")

    // 1) ProviderConfig.disabledModels 编解码（含旧配置缺字段回退）
    let pc = ProviderConfig(enabled: true, credential: ProviderCredential(apiKey: "k"), disabledModels: ["deepseek-v4-flash"])
    let pcData = try JSONEncoder().encode(pc)
    let pcDecoded = try JSONDecoder().decode(ProviderConfig.self, from: pcData)
    expectEqual(pcDecoded.disabledModels, ["deepseek-v4-flash"], "disabledModels round trip")
    expectTrue(pcDecoded.isModelDisabled("deepseek-v4-flash"), "isModelDisabled 命中")
    expectFalse(pcDecoded.isModelDisabled("deepseek-v4-pro"), "isModelDisabled 未命中")

    let legacy = #"{"enabled": true, "credential": {"apiKey": "k"}}"#
    let legacyDecoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacy.utf8))
    expectEqual(legacyDecoded.disabledModels, [], "旧配置缺 disabledModels → 空数组")

    // 2) 路由：禁用模型不出现在 /v1/models，chat 返回 404
    let config = RouteConfig(
        host: "127.0.0.1", port: 0,
        apiKeys: [GatewayKeyConfig(key: "test-key")],
        providers: [
            "deepseek": ProviderConfig(
                enabled: true,
                credential: ProviderCredential(apiKey: "k"),
                disabledModels: ["deepseek-v4-flash"]
            ),
        ]
    )
    let handler = RouteHandler(config: config)

    func req(_ method: String, _ path: String, body: Data? = nil) -> HTTPRequest {
        HTTPRequest(
            method: method, path: path, queryItems: [:],
            headers: ["authorization": "Bearer test-key"], body: body)
    }
    func chatBody(model: String) -> Data {
        Data(#"{"model": "\#(model)", "messages": [{"role": "user", "content": "hi"}]}"#.utf8)
    }

    let modelsResp = try await handler.handle(req("GET", "/v1/models"))
    if let data = modelsResp.bodyData(),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let ids = Set((json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        expectTrue(ids.contains("ds/deepseek-v4-pro"), "/v1/models 含未禁用模型")
        expectFalse(ids.contains("ds/deepseek-v4-flash"), "/v1/models 不含禁用模型")
    } else {
        failed += 1
        print("FAIL: /v1/models 禁用模型过滤响应解析失败")
    }

    let disabled = try await handler.handle(req("POST", "/v1/chat/completions", body: chatBody(model: "ds/deepseek-v4-flash")))
    expectEqual(disabled.status, 404, "禁用模型 chat → 404")

    // 未禁用模型仍正常路由（无凭据/不可达上游 → 502，而非 404）
    let enabled = try await handler.handle(req("POST", "/v1/chat/completions", body: chatBody(model: "ds/deepseek-v4-pro")))
    expectEqual(enabled.status, 502, "未禁用模型正常进入上游（无凭据 → 502）")
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
    let config = RouteConfig(
        host: "127.0.0.1", port: 0,
        apiKeys: [GatewayKeyConfig(key: "test-key")],
        providers: ["codebuddy-cn": ProviderConfig(enabled: true)]
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
        expectTrue(models.contains { ($0["id"] as? String) == "cbcn/glm-5.2" }, "模型列表应包含 cbcn/glm-5.2")
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

    // 裸路径归一化（Issue 5：客户端 baseURL 漏写 /v1 时请求打到 /chat/completions 等）
    let bareModels = try await handler.handle(req("GET", "/models", authorization: "Bearer test-key"))
    expectEqual(bareModels.status, 200, "裸路径 /models 返回 200（归一化为 /v1/models）")
    let bareHealth = try await handler.handle(req("GET", "/health"))
    expectEqual(bareHealth.status, 200, "裸路径 /health 返回 200")
    let bareUsage = try await handler.handle(req("GET", "/usage", authorization: "Bearer test-key"))
    expectEqual(bareUsage.status, 200, "裸路径 /usage 返回 200")
    let bareUnknownModel = try await handler.handle(req(
        "POST", "/chat/completions",
        authorization: "Bearer test-key", body: chatBody(model: "nope/nope")
    ))
    expectEqual(bareUnknownModel.status, 404, "裸路径未知模型 chat 返回 404（归一化后走同一逻辑）")
    let bareNope = try await handler.handle(req("GET", "/nope"))
    expectEqual(bareNope.status, 404, "裸路径未知路径返回 404")
    // 已带 /v1 的路径不应重复加前缀
    let doubleV1 = try await handler.handle(req("GET", "/v1/health"))
    expectEqual(doubleV1.status, 200, "/v1/health 不受归一化影响")
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

// MARK: - Antigravity 工具调用（翻译器纯单测 + 本地 mock 流式）

/// 工具调用翻译单测（纯函数，不碰网络）。
func antigravityToolCallTests() async throws {
    // 1) 请求方向：tools → functionDeclarations；tool_calls → functionCall；tool 结果 → functionResponse
    let toolsBody = #"""
    {
      "model": "gemini-3.6-flash-high",
      "messages": [
        {"role": "user", "content": "查一下天气"},
        {"role": "assistant", "tool_calls": [{"id": "call_1", "type": "function", "function": {"name": "get_weather", "arguments": "{\"city\":\"北京\"}"}}]},
        {"role": "tool", "tool_call_id": "call_1", "name": "get_weather", "content": "{\"temp\":25}"}
      ],
      "tools": [
        {"type": "function", "function": {"name": "get_weather", "description": "查询天气", "parameters": {"type": "object", "properties": {"city": {"type": "string", "minLength": 1}}, "required": ["city"], "strict": true}}}
      ],
      "stream": true
    }
    """#
    let decoded = try JSONDecoder().decode(ChatRequest.self, from: Data(toolsBody.utf8))
    let envelope = AntigravityEnvelopeTranslator.makeEnvelope(
        request: decoded,
        project: "p1",
        rawBody: Data(toolsBody.utf8)
    )
    let geminiRequest = envelope.request

    // tools → functionDeclarations
    guard let tools = geminiRequest.tools, let tool = tools.first else {
        expectTrue(false, "tools 应翻译为 Gemini functionDeclarations")
        return
    }
    expectEqual(tool.functionDeclarations.count, 1, "应有 1 个 function declaration")
    let decl = tool.functionDeclarations[0]
    expectEqual(decl.name, "get_weather", "工具名保留")
    // parameters 已清洗：strict 被删除、空 properties placeholder
    let params = decl.parameters ?? [:]
    expectNil(params["strict"], "Gemini 不支持的 strict 关键字应被删除")
    expectFalse(params["type"] == nil, "parameters 顶层应为 object 类型")

    // tool_calls → functionCall part（assistant 消息）
    let assistantTurn = geminiRequest.contents.first { $0.role == "model" }
    expectFalse(assistantTurn == nil, "assistant 消息应翻译为 model turn")
    if let assistantTurn {
        let hasFunctionCall = assistantTurn.parts.contains { $0.functionCall != nil }
        expectTrue(hasFunctionCall, "assistant 消息应含 functionCall part")
        if let fc = assistantTurn.parts.first(where: { $0.functionCall != nil })?.functionCall {
            expectEqual(fc.name, "get_weather", "functionCall.name")
        }
    }

    // tool 结果 → functionResponse part（role 为 user）
    let toolResultTurn = geminiRequest.contents.first { $0.role == "user" && $0.parts.contains { $0.functionResponse != nil } }
    expectFalse(toolResultTurn == nil, "tool 结果消息应翻译为 functionResponse part（role=user）")

    // toolConfig
    expectEqual(geminiRequest.toolConfig?.functionCallingConfig.mode, "VALIDATED", "toolConfig.mode 应为 VALIDATED")

    // 2) 响应方向：原生 functionCall part → OpenAI tool_calls（finish_reason=tool_calls）
    let payload: [String: Any] = [
        "response": [
            "candidates": [[
                "content": ["role": "model", "parts": [[
                    "functionCall": ["name": "get_weather", "args": ["city": "北京"]],
                    "thoughtSignature": "sig1",
                ]]],
                "finishReason": "STOP",
            ]],
        ],
    ]
    let chunk = AntigravityEnvelopeTranslator.openAIChunk(
        fromGeminiPayload: payload,
        model: "gemini-3.6-flash-high",
        id: "id1",
        created: 1,
        emitRole: true
    )
    expectFalse(chunk == nil, "functionCall payload 应翻译出 chunk")
    if let chunk {
        let choices = chunk["choices"] as? [[String: Any]]
        let delta = choices?.first?["delta"] as? [String: Any]
        let toolCalls = delta?["tool_calls"] as? [[String: Any]]
        expectEqual(toolCalls?.count ?? 0, 1, "应产出 1 个 tool_call")
        let fn = toolCalls?.first?["function"] as? [String: Any]
        expectEqual(fn?["name"] as? String, "get_weather", "tool_call.function.name")
        expectEqual(choices?.first?["finish_reason"] as? String, "tool_calls", "finish_reason 应为 tool_calls")
        let role = delta?["role"] as? String
        expectEqual(role, "assistant", "delta.role 应为 assistant")
    }

    // 3) 响应方向：文本 `[Tool call: ...]` 旧格式兜底
    let textPayload: [String: Any] = [
        "response": [
            "candidates": [[
                "content": ["role": "model", "parts": [["text": "[Tool call: search_files]\nArguments: {\"query\":\"x\"}"]]],
                "finishReason": "STOP",
            ]],
        ],
    ]
    let textChunk = AntigravityEnvelopeTranslator.openAIChunk(
        fromGeminiPayload: textPayload,
        model: "gemini-3.6-flash-high",
        id: "id2",
        created: 2,
        emitRole: true
    )
    expectFalse(textChunk == nil, "文本工具调用应翻译出 chunk")
    if let textChunk {
        let toolCalls = ((textChunk["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        expectEqual(toolCalls?.count ?? 0, 1, "文本工具调用应产出 1 个 tool_call")
        expectEqual((toolCalls?.first?["function"] as? [String: Any])?["name"] as? String, "search_files", "文本工具名")
    }
}

/// Antigravity 工具调用端到端（本地 HTTPServer mock 上游，流式 + 聚合）。
func antigravityToolCallIntegrationTests() async throws {
    // mock 上游：/v1internal:streamGenerateContent 返回 functionCall SSE
    let toolMockHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
        if request.path == "/v1internal:streamGenerateContent" {
            let sse =
                sseChunk(#"{"response":{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"get_weather","args":{"city":"北京"}}}]},"finishReason":"STOP"}]}}"#)
                + sseChunk("[DONE]")
            return HTTPResponse.text(200, sse, contentType: "text/event-stream")
        }
        return HTTPResponse.text(404, "not found")
    }

    let server = HTTPServer(handler: toolMockHandler)
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
        print("FAIL: Antigravity 工具 mock 上游无法启动: \(String(describing: lastError))")
        return
    }
    defer {
        server.stop()
        unsetenv("ANTIGRAVITY_BASE_URL")
    }
    setenv("ANTIGRAVITY_BASE_URL", "http://127.0.0.1:\(port)", 1)
    setenv("ANTIGRAVITY_PROJECT_ID", "mock-project", 1)
    defer { unsetenv("ANTIGRAVITY_PROJECT_ID") }

    let credential = ProviderCredential(accessToken: "mock-token")
    let body = #"""
    {
      "model": "gemini-3.6-flash-high",
      "messages": [{"role": "user", "content": "查天气"}],
      "tools": [{"type": "function", "function": {"name": "get_weather", "description": "天气", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}}}}],
      "stream": true
    }
    """#
    let request = try JSONDecoder().decode(ChatRequest.self, from: Data(body.utf8))
    let rawBody = Data(body.utf8)

    // 1) 流式：第一个 chunk 应含 tool_calls
    let stream = try await AntigravityProvider().chat(request: request, rawBody: rawBody, credential: credential)
    var iterator = stream.makeAsyncIterator()
    var sawToolCall = false
    var sawDone = false
    while let chunk = try await iterator.next() {
        let text = String(data: chunk, encoding: .utf8) ?? ""
        if text.contains("tool_calls") { sawToolCall = true }
        if text.contains("[DONE]") { sawDone = true }
    }
    expectTrue(sawToolCall, "流式响应应含 tool_calls")
    expectTrue(sawDone, "流式响应应以 [DONE] 结束")

    // 2) 非流式：聚合 JSON 应含 message.tool_calls + finish_reason=tool_calls
    let nonStreamRequest = ChatRequest(
        model: "gemini-3.6-flash-high",
        messages: [ChatMessage(role: .user, content: "查天气")],
        stream: false
    )
    let nonStream = try await AntigravityProvider().chat(
        request: nonStreamRequest,
        rawBody: Data(body.replacingOccurrences(of: "\"stream\": true", with: "\"stream\": false").utf8),
        credential: credential
    )
    var aggregated = Data()
    for try await chunk in nonStream {
        aggregated.append(chunk)
    }
    let json = try? JSONSerialization.jsonObject(with: aggregated) as? [String: Any]
    let message = json?["choices"] as? [[String: Any]] ?? []
    let firstMessage = message.first?["message"] as? [String: Any]
    let toolCalls = firstMessage?["tool_calls"] as? [[String: Any]]
    expectEqual(toolCalls?.count ?? 0, 1, "非流式聚合应含 1 个 tool_call")
    expectEqual(message.first?["finish_reason"] as? String, "tool_calls", "聚合 finish_reason 应为 tool_calls")
}

// MARK: - Antigravity token 刷新（URLProtocol mock，Phase 20）

/// 刷新流程：refresh_token 换新 access_token（含旋转）、fetchUserEmail 补邮箱。
func antigravityTokenRefreshTests() async throws {
    unsetenv("ANTIGRAVITY_BASE_URL")
    unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
    defer {
        unsetenv("ANTIGRAVITY_BASE_URL")
        unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }

    URLProtocol.registerClass(URLProtocolMock.self)
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        // token 端点：返回新 access/refresh token
        if request.url?.path == "/token" {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"access_token":"new-at","refresh_token":"new-rt","expires_in":3600,"scope":"openid"}"#
            return (response, Data(body.utf8))
        }
        // userinfo 端点：返回邮箱
        if request.url?.host?.contains("googleapis.com") == true {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"email":"me@example.com"}"#.utf8))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (response, Data("not found".utf8))
    }

    let client = AntigravityOAuthClient(config: .live())

    // 1) refresh 返回新 token + 旋转后的 refreshToken
    let refreshed = try await client.refreshAccessToken(refreshToken: "old-rt")
    expectEqual(refreshed.accessToken, "new-at", "refresh 返回新 access_token")
    expectEqual(refreshed.refreshToken, "new-rt", "refresh 旋转 refresh_token")
    expectEqual(refreshed.expiresIn, 3600, "refresh 返回 expires_in")

    // 2) fetchUserEmail 命中 userinfo
    let email = await client.fetchUserEmail(accessToken: "new-at")
    expectEqual(email, "me@example.com", "fetchUserEmail 返回账号邮箱")
}

// MARK: - opencode 集成（本地 HTTPServer 当 mock 上游，Phase 15）

/// opencode mock 上游：GET /v1/models 返回模型列表；POST /v1/chat/completions 返回 SSE。
private let opencodeMockHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
    if request.method == "GET", request.path == "/v1/models" {
        return HTTPResponse.text(
            200,
            #"{"data":[{"id":"mock-oc-1","owned_by":"mock"}]}"#,
            contentType: "application/json"
        )
    }
    let sse =
        sseChunk(#"{"id":"chatcmpl-oc","model":"big-pickle","created":1,"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-oc","model":"big-pickle","created":1,"choices":[{"delta":{"content":" there"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-oc","model":"big-pickle","created":1,"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        + sseChunk("[DONE]")
    return HTTPResponse.text(200, sse, contentType: "text/event-stream")
}

func opencodeIntegrationTests() async throws {
    unsetenv("OPENCODE_API_KEY")
    unsetenv("OPENCODE_BASE_URL")

    let server = HTTPServer(handler: opencodeMockHandler)
    var port: Int?
    var lastError: Error?
    for _ in 0 ..< 3 {
        let candidate = Int.random(in: 20_000 ... 60_000)
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
        print("FAIL: opencode 无法启动 mock 上游端口: \(String(describing: lastError))")
        return
    }
    defer {
        server.stop()
        unsetenv("OPENCODE_API_KEY")
        unsetenv("OPENCODE_BASE_URL")
    }

    setenv("OPENCODE_API_KEY", "mock-key", 1)
    setenv("OPENCODE_BASE_URL", "http://127.0.0.1:\(port)/v1", 1)
    await ModelCache.shared.invalidate("opencode")

    // 1) listModels 命中 mock 上游（modelsURL 路径）
    let models = try await OpenCodeProvider().listModels(credential: nil)
    expectEqual(models.map(\.id), ["mock-oc-1"], "opencode listModels 命中 mock 上游")

    // 2) chat 调用成功（SSE 透传）
    let request = ChatRequest(
        model: "big-pickle",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let stream = try await OpenCodeProvider().chat(request: request, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hi""#), "opencode SSE 应包含 Hi 内容块，实际: \(text)")
    expectTrue(text.contains("[DONE]"), "opencode SSE 应包含 [DONE]")

    await ModelCache.shared.invalidate("opencode")
}

// MARK: - Kimi 集成（强制流式 + SSEJSONAggregator 聚合，Phase 15）

/// Kimi mock 上游共享状态：记录 chat 请求体（锁保护）。
private final class KimiMockState: @unchecked Sendable {
    static let shared = KimiMockState()
    private let lock = NSLock()
    private var bodies: [String] = []

    /// 最近一次 chat 请求体。
    var lastBody: String? {
        lock.lock(); defer { lock.unlock() }
        return bodies.last
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bodies.count
    }

    func record(body: Data) {
        lock.lock(); defer { lock.unlock() }
        bodies.append(String(data: body, encoding: .utf8) ?? "")
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        bodies = []
    }
}

/// Kimi mock 上游：仅处理 POST /v1/chat/completions，记录请求体并返回 SSE。
private let kimiMockHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
    guard request.path == "/v1/chat/completions" else {
        return HTTPResponse.text(404, "not found")
    }
    KimiMockState.shared.record(body: request.body ?? Data())
    let sse =
        sseChunk(#"{"id":"chatcmpl-kimi","model":"kimi-k3","created":1,"choices":[{"delta":{"content":"Hello"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-kimi","model":"kimi-k3","created":1,"choices":[{"delta":{"content":" Kimi"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-kimi","model":"kimi-k3","created":1,"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        + sseChunk("[DONE]")
    return HTTPResponse.text(200, sse, contentType: "text/event-stream")
}

func kimiIntegrationTests() async throws {
    KimiMockState.shared.reset()
    unsetenv("KIMI_API_KEY")
    unsetenv("MOONSHOT_API_KEY")
    unsetenv("KIMI_BASE_URL")

    // 0) 无凭据时 chat 应同步抛 missingCredentials
    let noCredRequest = ChatRequest(
        model: "kimi-k3",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    await expectThrows({ _ = try await KimiProvider().chat(request: noCredRequest, rawBody: nil, credential: nil) },
        "无凭据时 Kimi chat 抛 missingCredentials")

    let server = HTTPServer(handler: kimiMockHandler)
    var port: Int?
    var lastError: Error?
    for _ in 0 ..< 3 {
        let candidate = Int.random(in: 20_000 ... 60_000)
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
        print("FAIL: Kimi 无法启动 mock 上游端口: \(String(describing: lastError))")
        return
    }
    defer {
        server.stop()
        unsetenv("KIMI_API_KEY")
        unsetenv("MOONSHOT_API_KEY")
        unsetenv("KIMI_BASE_URL")
    }

    setenv("KIMI_API_KEY", "mock-key", 1)
    setenv("KIMI_BASE_URL", "http://127.0.0.1:\(port)/v1", 1)
    await ModelCache.shared.invalidate("kimi")

    // 1) 客户端 stream=false → 上游请求体必须强制 stream=true；返回单个聚合 JSON（而非 SSE 透传）
    let nonStreamRequest = ChatRequest(
        model: "kimi-k3",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: false
    )
    let nonStream = try await KimiProvider().chat(request: nonStreamRequest, rawBody: nil, credential: nil)
    var chunks: [Data] = []
    for try await chunk in nonStream { chunks.append(chunk) }
    expectEqual(chunks.count, 1, "Kimi 非流式客户端应拿到单个聚合 JSON 块")
    expectEqual(KimiMockState.shared.requestCount, 1, "Kimi chat 请求上游一次")
    let upstreamBody = KimiMockState.shared.lastBody ?? ""
    expectTrue(upstreamBody.contains("\"stream\":true"), "Kimi 上游请求体应强制 stream=true，实际: \(upstreamBody)")
    if let json = try? JSONSerialization.jsonObject(with: chunks[0]) as? [String: Any],
       let choices = json["choices"] as? [[String: Any]],
       let first = choices.first,
       let message = first["message"] as? [String: Any] {
        expectEqual(message["content"] as? String, "Hello Kimi", "Kimi 聚合内容为 'Hello Kimi'")
        expectEqual(first["finish_reason"] as? String, "stop", "Kimi 聚合 finish_reason 为 stop")
    } else {
        failed += 1
        print("FAIL: Kimi 聚合 JSON 结构解析失败")
    }

    // 2) 客户端 stream=true → SSE 透传（含内容块与 [DONE]），且上游请求体仍强制 stream=true
    KimiMockState.shared.reset()
    let streamRequest = ChatRequest(
        model: "kimi-k3",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let stream = try await KimiProvider().chat(request: streamRequest, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hello""#), "Kimi SSE 透传应包含 Hello 内容块，实际: \(text)")
    expectTrue(text.contains("[DONE]"), "Kimi SSE 透传应包含 [DONE]")
    expectTrue(KimiMockState.shared.lastBody?.contains("\"stream\":true") ?? false, "Kimi 流式请求上游 body 也应强制 stream=true")

    // 3) developer 角色归一化：ChatRequest 路径 developer→system（Moonshot 上游不认 developer）
    KimiMockState.shared.reset()
    let devRequest = ChatRequest(
        model: "kimi-k3",
        messages: [
            ChatMessage(role: .developer, content: "be helpful"),
            ChatMessage(role: .user, content: "hi"),
        ],
        stream: true
    )
    let devStream = try await KimiProvider().chat(request: devRequest, rawBody: nil, credential: nil)
    for try await _ in devStream {}
    let devBody = KimiMockState.shared.lastBody ?? ""
    expectTrue(devBody.contains("\"role\":\"system\""), "Kimi ChatRequest 路径 developer→system，实际: \(devBody)")
    expectFalse(devBody.contains("developer"), "Kimi ChatRequest 路径不应残留 developer 角色，实际: \(devBody)")

    // 4) developer 角色归一化：rawBody 透传路径同样改写 developer→system
    KimiMockState.shared.reset()
    let devRaw = Data(#"{"model":"kimi-k3","messages":[{"role":"developer","content":"be helpful"},{"role":"user","content":"hi"}],"stream":false}"#.utf8)
    let rawStream = try await KimiProvider().chat(
        request: ChatRequest(model: "kimi-k3", messages: [], stream: true),
        rawBody: devRaw,
        credential: nil
    )
    for try await _ in rawStream {}
    let devRawBody = KimiMockState.shared.lastBody ?? ""
    expectTrue(devRawBody.contains("\"role\":\"system\""), "Kimi rawBody 路径 developer→system，实际: \(devRawBody)")
    expectFalse(devRawBody.contains("developer"), "Kimi rawBody 路径不应残留 developer 角色，实际: \(devRawBody)")

    await ModelCache.shared.invalidate("kimi")
}

// MARK: - Phase 13: testAllModels 串行 + modelsURL 动态模型

nonisolated(unsafe) var testAllOrder: [String] = []
nonisolated(unsafe) var testAllListCount = 0
nonisolated(unsafe) var dynamicModelsRequestCount = 0

/// 记录 listModels / testModel 调用顺序的测试 Provider。
private final class TestAllProvider: Provider {
    let id: String
    let models: [Model]
    init(id: String, models: [Model]) {
        self.id = id
        self.models = models
    }
    func listModels(credential: ProviderCredential?) async throws -> [Model] {
        testAllListCount += 1
        return models
    }
    func chat(request: ChatRequest, rawBody: Data?, credential: ProviderCredential?) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func testModel(_ modelID: String, credential: ProviderCredential?) async throws -> ConnectionTestResult {
        testAllOrder.append(modelID)
        return ConnectionTestResult(success: true, message: "ok-\(modelID)", latencyMS: 1)
    }
}

/// 使用默认 `listModels`（ModelCache → modelsURL → 静态兜底）的测试 Provider。
private final class DynamicModelsTestProvider: Provider {
    let id: String
    init(id: String = "test-dynamic") { self.id = id }
    func chat(request: ChatRequest, rawBody: Data?, credential: ProviderCredential?) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

func testAllModelsSuite() async {
    testAllOrder = []
    testAllListCount = 0
    let provider = TestAllProvider(
        id: "test-all",
        models: [Model(id: "m1"), Model(id: "m2"), Model(id: "m3")]
    )
    let outcomes = await provider.testAllModels(credential: nil)
    expectEqual(outcomes.map(\.modelID), ["m1", "m2", "m3"], "testAllModels 按 listModels 顺序返回")
    expectEqual(testAllOrder, ["m1", "m2", "m3"], "testModel 被串行调用且顺序一致")
    expectTrue(outcomes.allSatisfy(\.success), "全部模型测试成功")
    expectEqual(testAllListCount, 1, "testAllModels 只调一次 listModels")

    // 单个模型失败不中断后续
    testAllOrder = []
    let failing = TestAllProvider(id: "test-all-fail", models: [Model(id: "a"), Model(id: "b")])
    let failOutcomes = await failing.testAllModels(credential: nil)
    expectEqual(failOutcomes.count, 2, "失败模型不中断后续测试")
}

func dynamicModelsURLSuite() async throws {
    // 用 URLProtocol 全局拦截（ProviderHTTPClient.shared 走 URLSession.shared），
    // 验证默认 listModels 的「ModelCache → modelsURL → 静态兜底」链路，避免真实 socket 网络抖动。
    URLProtocol.registerClass(URLProtocolMock.self)
    defer { URLProtocol.unregisterClass(URLProtocolMock.self) }

    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { _ in
        dynamicModelsRequestCount += 1
        let response = HTTPURLResponse(
            url: URL(string: "https://mock.test/v1/models")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (response, Data(#"{"data":[{"id":"mock-dynamic-1","owned_by":"mock"},{"id":"mock-dynamic-2","owned_by":"mock"}]}"#.utf8))
    }
    URLProtocolMock.requestCount = 0
    dynamicModelsRequestCount = 0

    let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(id: "test-dynamic", alias: "td", displayName: "Test Dynamic", authType: .apiKey),
        baseURL: URL(string: "https://mock.test/v1"),
        models: [Model(id: "static-model")],
        modelsURL: URL(string: "https://mock.test/v1/models"),
        makeProvider: { DynamicModelsTestProvider() }
    )
    ProviderRegistry.shared.register(descriptor)
    await ModelCache.shared.invalidate("test-dynamic")

    let provider = DynamicModelsTestProvider()

    // 1. 无凭据 → 静态兜底（不打上游）
    let noCred = try await provider.listModels(credential: nil)
    expectEqual(noCred.map(\.id), ["static-model"], "modelsURL 无凭据时回退静态目录")
    expectEqual(dynamicModelsRequestCount, 0, "无凭据时不请求上游")

    // 2. 有凭据 → 命中上游
    let withCred = try await provider.listModels(credential: ProviderCredential(apiKey: "mock-key"))
    expectEqual(withCred.map(\.id), ["mock-dynamic-1", "mock-dynamic-2"], "modelsURL 有凭据时命中上游")
    expectEqual(dynamicModelsRequestCount, 1, "有凭据时请求上游一次")

    // 3. 缓存生效：二次调用不增加上游请求
    let cached = try await provider.listModels(credential: ProviderCredential(apiKey: "mock-key"))
    expectEqual(cached.map(\.id), ["mock-dynamic-1", "mock-dynamic-2"], "modelsURL 二次调用命中 ModelCache")
    expectEqual(dynamicModelsRequestCount, 1, "ModelCache 生效：上游只请求一次")

    await ModelCache.shared.invalidate("test-dynamic")
    URLProtocolMock.reset()
}

// MARK: - Phase 16: 用量查询器（URLProtocol 全局 mock）

/// 全局注册/清理 URLProtocolMock。
///
/// 用量查询器走 `ProviderHTTPClient.shared`（即 `URLSession.shared`），无法注入独立
/// session，因此必须全局注册 `URLProtocolMock` 拦截。已知此仓库混用本地 HTTPServer +
/// URLSession 会偶发崩溃（"Not enough bits to represent the passed value"），
/// 故用量测试只使用 URLProtocol，不启动本地 HTTPServer。
func withGlobalURLProtocolMock(_ body: () async throws -> Void) async throws {
    URLProtocol.registerClass(URLProtocolMock.self)
    defer {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }
    try await body()
}

/// 读取 URLRequest 的 body。URLSession 交给 URLProtocol 的请求可能把 body 放在
/// `httpBodyStream` 而非 `httpBody`（已知行为），测试需要两者都读。
func requestBodyString(_ request: URLRequest) -> String? {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8)
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return String(data: data, encoding: .utf8)
}

func deepSeekUsageFetcherTests() async throws {
    unsetenv("DEEPSEEK_API_KEY")
    unsetenv("DEEPSEEK_BASE_URL")
    defer {
        unsetenv("DEEPSEEK_API_KEY")
        unsetenv("DEEPSEEK_BASE_URL")
    }

    // 1) 正常解析：total_balance 为字符串、granted_balance 为数字，均容错为 Decimal
    try await withGlobalURLProtocolMock {
        setenv("DEEPSEEK_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(request.url?.absoluteString, "https://mock.test/v1/user/balance", "DeepSeek 余额请求 URL")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", "DeepSeek 鉴权头")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"120.50","granted_balance":20.5,"topped_up_balance":"100.00"}]}"#
            return (response, Data(body.utf8))
        }
        let snapshot = try await DeepSeekUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectEqual(snapshot.providerID, "deepseek", "DeepSeek 快照 providerID")
        expectEqual(snapshot.balance, Decimal(string: "120.50"), "DeepSeek 余额解析（字符串 → Decimal）")
        expectEqual(snapshot.currency, "CNY", "DeepSeek 币种")
        expectTrue(snapshot.rawJSON?.contains("balance_infos") == true, "DeepSeek rawJSON 保留原始 body")
        expectNil(snapshot.error, "DeepSeek 成功快照无 error")

        // 2) 非 2xx 抛 upstreamError
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("unauthorized".utf8))
        }
        await expectThrows({
            _ = try await DeepSeekUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "bad-key"))
        }, "DeepSeek 401 抛 upstreamError")
    }

    // 3) 无凭据抛 missingCredentials（不触发网络）
    await expectThrows({
        _ = try await DeepSeekUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "DeepSeek 无凭据抛 missingCredentials")

    // 4) 带标签令牌：余额展示用户配置的标签而非掩码（用量卡更直观）
    try await withGlobalURLProtocolMock {
        setenv("DEEPSEEK_BASE_URL", "https://mock.test/v1", 1)
        let labeled = RouteConfig(
            providers: [
                "deepseek": ProviderConfig(
                    enabled: true,
                    credential: ProviderCredential(),
                    apiKeys: [
                        KeyedToken(label: "主 Key", value: "sk-label-key"),
                        KeyedToken(label: "备用 Key", value: "sk-backup-key"),
                    ]
                ),
            ]
        )
        try ConfigStore.save(labeled)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.34"}]}"#.utf8))
        }
        let snapshot = try await DeepSeekUsageFetcher().fetchUsage(credential: ProviderCredential())
        expectEqual(snapshot.balances.count, 2, "带标签令牌逐 Key 展示余额")
        let labels = snapshot.balances.map(\.label)
        expectEqual(labels, ["主 Key", "备用 Key"], "用量卡展示用户配置的令牌标签")
        expectEqual(snapshot.balances.first?.balance, Decimal(string: "12.34"), "标签令牌余额解析")

        // 5) 真实链路：AppState 会把 config 首个 apiKey 填充进 credential.apiKey，
        //    同 value 时必须优先展示配置标签而非掩码（用户反馈 sk-ed65... 未显示标签的回归）
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"5.67"}]}"#.utf8))
        }
        let snapshot2 = try await DeepSeekUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "sk-label-key"))
        // AppState 用 config.credential(for:) 取凭据：会把 config 首个 apiKey 填充进 credential.apiKey。
        // 同 value 时按值去重，展示配置标签（主 Key / 备用 Key），而不是掩码。
        expectEqual(snapshot2.balances.count, 2, "config 两令牌均展示（credential 同 value 去重）")
        expectEqual(snapshot2.balances.first?.label, "主 Key", "credential 与 config 同 value 时展示配置标签而非掩码")
        expectEqual(snapshot2.balances.last?.label, "备用 Key", "第二个令牌标签保留")
        // 清理：删掉临时 config，避免影响后续测试
        try? FileManager.default.removeItem(atPath: ConfigStore.defaultPath())
    }
}

func antigravityUsageFetcherTests() async throws {
    unsetenv("ANTIGRAVITY_BASE_URL")
    unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
    unsetenv("ANTIGRAVITY_PROJECT_ID")
    unsetenv("ANTIGRAVITY_OAUTH_CLIENT_ID")
    unsetenv("ANTIGRAVITY_OAUTH_CLIENT_SECRET")
    defer {
        unsetenv("ANTIGRAVITY_BASE_URL")
        unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
        unsetenv("ANTIGRAVITY_PROJECT_ID")
        unsetenv("ANTIGRAVITY_OAUTH_CLIENT_ID")
        unsetenv("ANTIGRAVITY_OAUTH_CLIENT_SECRET")
    }

    // 1) 正常解析：retrieveUserQuota → modelQuotas；retrieveUserQuotaSummary → weekly windows
    try await withGlobalURLProtocolMock {
        setenv("ANTIGRAVITY_BASE_URL", "https://mock.test", 1)
        setenv("ANTIGRAVITY_PROJECT_ID", "proj-1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if path == "/v1internal:retrieveUserQuota" {
                expectEqual(
                    requestBodyString(request),
                    #"{"project":"proj-1"}"#,
                    "retrieveUserQuota 请求体"
                )
                expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer mock-token", "retrieveUserQuota 鉴权头")
                expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "antigravity/ide/2.1.1 darwin/arm64", "retrieveUserQuota User-Agent")
                // 第二个 bucket 缺 remainingFraction → 应被跳过
                return (response, Data(#"{"buckets":[{"modelId":"gemini-3.6-flash-high","remainingFraction":0.6,"resetTime":"2026-08-01T00:00:00Z"},{"modelId":"claude-sonnet-4-6"}]}"#.utf8))
            }
            if path == "/v1internal:retrieveUserQuotaSummary" {
                // 两组周窗口 + 一个 5h 窗口：只应保留 Gemini / Claude+GPT 两个周用量
                return (response, Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","displayName":"Weekly","remainingFraction":0.4,"resetTime":"2026-08-07T00:00:00Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"weekly","displayName":"Weekly","remainingFraction":0.7,"resetTime":"2026-08-07T00:00:00Z"}]},{"displayName":"OpenRouter 5h","buckets":[{"bucketId":"5h","displayName":"5h","remainingFraction":0.5}]}]}"#.utf8))
            }
            return (response, Data("not found".utf8))
        }

        let snapshot = try await AntigravityUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "mock-token"))
        expectEqual(snapshot.providerID, "antigravity", "Antigravity 快照 providerID")
        expectEqual(snapshot.balance, nil, "Antigravity 无余额字段")
        expectNil(snapshot.error, "Antigravity 成功快照无 error")

        // 用量展示只保留两个核心周用量（Gemini / Claude+GPT），per-model 配额不再展示
        expectEqual(snapshot.modelQuotas.count, 0, "Antigravity 不再展示 per-model 配额")
        expectEqual(snapshot.quotaWindows.count, 2, "只保留两个核心周用量窗口")
        if let gemini = snapshot.quotaWindows.first(where: { $0.label == "Gemini Models Weekly" }) {
            expectEqual(gemini.remainingFraction, 0.4, "Gemini Models Weekly remainingFraction")
            expectEqual(gemini.total, 1000, "Gemini Models Weekly 归一化 total=1000")
            expectEqual(gemini.used, 600, "Gemini Models Weekly 归一化 used=600")
            expectEqual(gemini.remainingPercentage, 40, "Gemini Models Weekly remainingPercentage")
        } else {
            expectTrue(false, "缺失 Gemini Models Weekly 窗口")
        }
        if let claude = snapshot.quotaWindows.first(where: { $0.label == "Claude and GPT models Weekly" }) {
            expectEqual(claude.remainingFraction, 0.7, "Claude and GPT models Weekly remainingFraction")
        } else {
            expectTrue(false, "缺失 Claude and GPT models Weekly 窗口")
        }
    }

    // 2) 无 token 抛 missingCredentials
    await expectThrows({
        _ = try await AntigravityUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "Antigravity 无 token 抛 missingCredentials")

    // 3) RPC 2 失败不影响快照（best-effort）：quotaWindows 为空，模型配额仍返回
    try await withGlobalURLProtocolMock {
        setenv("ANTIGRAVITY_BASE_URL", "https://mock.test", 1)
        setenv("ANTIGRAVITY_PROJECT_ID", "proj-1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            if path == "/v1internal:retrieveUserQuota" {
                return (response, Data(#"{"buckets":[{"modelId":"gemini-3.6-flash-high","remainingFraction":1,"resetTime":null}]}"#.utf8))
            }
            if path == "/v1internal:retrieveUserQuotaSummary" {
                let errorResponse = HTTPURLResponse(
                    url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil
                )!
                return (errorResponse, Data("boom".utf8))
            }
            return (response, Data("not found".utf8))
        }
        let snapshot = try await AntigravityUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "mock-token"))
        expectEqual(snapshot.quotaWindows, [], "RPC 2 失败时 quotaWindows 为空")
        expectEqual(snapshot.modelQuotas.count, 0, "RPC 2 失败时 modelQuotas 仍不展示")
    }
}

// MARK: - Phase 18: zai / minimax 集成（URLProtocol mock，无本地 HTTPServer）

/// OpenAI 兼容上游请求体记录器（锁保护），供 zai / minimax 测试断言。
private final class OpenAIPassthroughMockState: @unchecked Sendable {
    static let shared = OpenAIPassthroughMockState()
    private let lock = NSLock()
    private var bodies: [String] = []

    var lastBody: String? {
        lock.lock(); defer { lock.unlock() }
        return bodies.last
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bodies.count
    }

    func record(body: Data) {
        lock.lock(); defer { lock.unlock() }
        bodies.append(String(data: body, encoding: .utf8) ?? "")
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        bodies = []
    }
}

/// 构造 OpenAI 格式 SSE 数据事件。
func openAIEvent(_ json: String) -> String {
    "data: \(json)\n\n"
}

/// zai / minimax 共享集成测试（OpenAI 兼容透传模式）：
/// stream=true 透传 OpenAI SSE，stream=false 同样透传（客户端 stream 标志原样转发，
/// 上游返回单 JSON 时即单 JSON）；断言 Bearer 认证头 + rawBody 透传
/// `tools` / `tool_calls` / `tool_result` —— 工具调用正常的关键回归用例。
func runOpenAIPassthroughSuite(
    providerID: String,
    makeProvider: () -> any Provider,
    apiKeyEnv: String,
    baseURLEnv: String,
    chatModel: String
) async throws {
    OpenAIPassthroughMockState.shared.reset()
    unsetenv(apiKeyEnv)
    unsetenv(baseURLEnv)
    defer {
        unsetenv(apiKeyEnv)
        unsetenv(baseURLEnv)
    }
    setenv(apiKeyEnv, "mock-key", 1)
    setenv(baseURLEnv, "https://mock.test/v1", 1)

    URLProtocol.registerClass(URLProtocolMock.self)
    defer {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }

    let sse =
        openAIEvent(#"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"\#(chatModel)","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}"#)
        + openAIEvent(#"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"\#(chatModel)","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}"#)
        + openAIEvent(#"{"id":"chatcmpl-1","object":"chat.completion.chunk","created":1,"model":"\#(chatModel)","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#)
        + "data: [DONE]\n\n"

    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        expectEqual(
            request.url?.absoluteString,
            "https://mock.test/v1/chat/completions",
            "\(providerID) 请求 OpenAI 兼容 /chat/completions 端点"
        )
        expectEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer mock-key",
            "\(providerID) Bearer 认证头"
        )
        expectNil(request.value(forHTTPHeaderField: "x-api-key"), "\(providerID) 不应带 x-api-key 头")
        expectNil(request.value(forHTTPHeaderField: "anthropic-version"), "\(providerID) 不应带 anthropic-version 头")
        OpenAIPassthroughMockState.shared.record(body: Data((requestBodyString(request) ?? "").utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }

    // 1) 客户端 stream=true：OpenAI SSE 透传（内容 + role + finish_reason + [DONE]）
    let streamReq = ChatRequest(model: chatModel, messages: [ChatMessage(role: .user, content: "hi")], stream: true)
    let stream = try await makeProvider().chat(request: streamReq, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hello""#), "\(providerID) 透传内容块 Hello，实际: \(text)")
    expectTrue(text.contains(#""content":" world""#), "\(providerID) 透传内容块 world")
    expectTrue(text.contains(#""role":"assistant""#), "\(providerID) 透传 role")
    expectTrue(text.contains(#""finish_reason":"stop""#), "\(providerID) 透传 finish_reason stop")
    expectTrue(text.contains("[DONE]"), "\(providerID) 以 [DONE] 结束")

    // 2) 客户端 stream=false：透传（不聚合、不强制改 stream），stream 标志原样转发
    OpenAIPassthroughMockState.shared.reset()
    let nonStreamReq = ChatRequest(model: chatModel, messages: [ChatMessage(role: .user, content: "hi")], stream: false)
    let nonStream = try await makeProvider().chat(request: nonStreamReq, rawBody: nil, credential: nil)
    var raw = Data()
    for try await chunk in nonStream { raw.append(chunk) }
    let rawText = String(data: raw, encoding: .utf8) ?? ""
    expectTrue(rawText.contains(#""content":"Hello""#), "\(providerID) 非流式同样透传内容块 Hello")
    expectTrue(rawText.contains("[DONE]"), "\(providerID) 非流式同样透传 [DONE]")
    let nonStreamBody = OpenAIPassthroughMockState.shared.lastBody ?? ""
    expectTrue(nonStreamBody.contains("\"stream\":false"), "\(providerID) 非流式请求体透传 stream=false，实际: \(nonStreamBody)")

    // 3) 工具调用回归：rawBody 透传 tools / tool_calls / tool_result，上游原样收到
    OpenAIPassthroughMockState.shared.reset()
    let toolRequestJSON: [String: Any] = [
        "model": chatModel,
        "stream": true,
        "messages": [
            ["role": "user", "content": "查询北京天气"],
            [
                "role": "assistant",
                "content": NSNull(),
                "tool_calls": [
                    ["id": "call_1", "type": "function", "function": ["name": "get_weather", "arguments": "{\"city\":\"北京\"}"]],
                ],
            ],
            ["role": "tool", "tool_call_id": "call_1", "content": "晴，25°C"],
            ["role": "user", "content": "然后呢"],
        ],
        "tools": [
            ["type": "function", "function": ["name": "get_weather", "description": "查询天气", "parameters": ["type": "object", "properties": ["city": ["type": "string"]]]]],
        ],
    ]
    let toolRawBody = try JSONSerialization.data(withJSONObject: toolRequestJSON)
    let toolReq = ChatRequest(model: chatModel, messages: [], stream: true)
    let toolStream = try await makeProvider().chat(request: toolReq, rawBody: toolRawBody, credential: nil)
    _ = try? await toolStream.first(where: { _ in true })
    let toolBody = OpenAIPassthroughMockState.shared.lastBody ?? ""
    expectTrue(toolBody.contains(#""tools""#), "\(providerID) 透传请求体保留 tools，实际: \(toolBody)")
    expectTrue(toolBody.contains(#""get_weather""#), "\(providerID) 透传请求体保留工具定义，实际: \(toolBody)")
    expectTrue(toolBody.contains(#""tool_calls""#), "\(providerID) 透传请求体保留 tool_calls，实际: \(toolBody)")
    expectTrue(toolBody.contains(#""tool_call_id""#), "\(providerID) 透传请求体保留 tool 结果，实际: \(toolBody)")
    expectEqual(OpenAIPassthroughMockState.shared.requestCount, 1, "\(providerID) 工具请求上游一次")
}

func zaiIntegrationTests() async throws {
    unsetenv("ZAI_API_KEY")
    unsetenv("ZAI_BASE_URL")
    defer {
        unsetenv("ZAI_API_KEY")
        unsetenv("ZAI_BASE_URL")
    }

    // 0) 无凭据时 chat 同步抛 missingCredentials
    await expectThrows({
        _ = try await ZaiProvider().chat(
            request: ChatRequest(model: "glm-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true),
            rawBody: nil, credential: nil
        )
    }, "zai 无凭据时 chat 抛 missingCredentials")

    try await runOpenAIPassthroughSuite(
        providerID: "zai",
        makeProvider: { ZaiProvider() },
        apiKeyEnv: "ZAI_API_KEY",
        baseURLEnv: "ZAI_BASE_URL",
        chatModel: "glm-5.2"
    )

    // Phase 20: API 区域 → 上游 URL（region 在 credential 中，无 env 覆盖）
    setenv("ZAI_API_KEY", "mock-key", 1)
    URLProtocol.registerClass(URLProtocolMock.self)
    defer {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }
    let regionReq = ChatRequest(model: "glm-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true)

    func captureURL(_ credential: ProviderCredential?) async -> String {
        URLProtocolMock.reset()
        var url = ""
        URLProtocolMock.requestHandler = { request in
            url = request.url?.absoluteString ?? ""
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data("".utf8))
        }
        let stream = (try? await ZaiProvider().chat(request: regionReq, rawBody: nil, credential: credential)) ?? AsyncThrowingStream { $0.finish() }
        _ = try? await stream.first(where: { _ in true })
        return url
    }

    let globalURL = await captureURL(ProviderCredential(apiKey: "mock-key", region: "global"))
    expectTrue(
        globalURL.hasPrefix("https://api.z.ai/api/coding/paas/v4/chat/completions"),
        "zai region=global → api.z.ai/coding/paas/v4，实际: \(globalURL)")

    let cnURL = await captureURL(ProviderCredential(apiKey: "mock-key", region: "bigmodel-cn"))
    expectTrue(
        cnURL.hasPrefix("https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"),
        "zai region=bigmodel-cn → open.bigmodel.cn/coding/paas/v4，实际: \(cnURL)")

    let nilURL = await captureURL(ProviderCredential(apiKey: "mock-key"))
    expectTrue(
        nilURL.hasPrefix("https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"),
        "zai 缺省 region → 默认 BigModel CN，实际: \(nilURL)")
    unsetenv("ZAI_API_KEY")
}

func minimaxIntegrationTests() async throws {
    try await runOpenAIPassthroughSuite(
        providerID: "minimax",
        makeProvider: { MiniMaxProvider() },
        apiKeyEnv: "MINIMAX_API_KEY",
        baseURLEnv: "MINIMAX_BASE_URL",
        chatModel: "MiniMax-M3"
    )
}

// MARK: - Phase 18: OpenAI 兼容供应商集成（URLProtocol mock，无本地 HTTPServer）

/// opencode-go / xiaomi-mimo / qwen-cloud 共享集成测试：
/// listModels 命中 mock 上游，chat 透传 SSE（含内容与 [DONE]）。
func runOpenAICompatSuite(
    providerID: String,
    makeProvider: () -> any Provider,
    apiKeyEnv: String,
    baseURLEnv: String,
    chatModel: String
) async throws {
    unsetenv(apiKeyEnv)
    unsetenv(baseURLEnv)
    defer {
        unsetenv(apiKeyEnv)
        unsetenv(baseURLEnv)
    }
    setenv(apiKeyEnv, "mock-key", 1)
    setenv(baseURLEnv, "https://mock.test/v1", 1)
    await ModelCache.shared.invalidate(providerID)

    URLProtocol.registerClass(URLProtocolMock.self)
    defer {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }

    let sse =
        sseChunk(#"{"id":"chatcmpl-mock","model":"\#(chatModel)","created":1,"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-mock","model":"\#(chatModel)","created":1,"choices":[{"delta":{"content":" there"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-mock","model":"\#(chatModel)","created":1,"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        + sseChunk("[DONE]")

    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        if request.httpMethod == "GET" {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"id":"mock-1","owned_by":"mock"}]}"#.utf8))
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }

    // 1) listModels 命中 mock（默认实现：ModelCache → modelsURL → 静态兜底）
    let models = try await makeProvider().listModels(credential: nil)
    expectEqual(models.map(\.id), ["mock-1"], "\(providerID) listModels 命中 mock 上游")

    // 2) chat stream=true 透传 SSE（含内容块与 [DONE]）
    let request = ChatRequest(model: chatModel, messages: [ChatMessage(role: .user, content: "hi")], stream: true)
    let stream = try await makeProvider().chat(request: request, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hi""#), "\(providerID) SSE 透传包含 Hi，实际: \(text)")
    expectTrue(text.contains("[DONE]"), "\(providerID) SSE 透传含 [DONE]")

    await ModelCache.shared.invalidate(providerID)
}

func opencodeGoIntegrationTests() async throws {
    try await runOpenAICompatSuite(
        providerID: "opencode-go",
        makeProvider: { OpenCodeGoProvider() },
        apiKeyEnv: "OPENCODE_GO_API_KEY",
        baseURLEnv: "OPENCODE_GO_BASE_URL",
        chatModel: "glm-5.2"
    )
}

func xiaomiMimoIntegrationTests() async throws {
    try await runOpenAICompatSuite(
        providerID: "xiaomi-mimo",
        makeProvider: { XiaomiMimoProvider() },
        apiKeyEnv: "XIAOMI_MIMO_API_KEY",
        baseURLEnv: "XIAOMI_MIMO_BASE_URL",
        chatModel: "MiMo-V2.5"
    )
}

// MARK: - Phase 18: Kimi 用量查询（URLProtocol mock）

func kimiUsageFetcherTests() async throws {
    unsetenv("KIMI_API_KEY")
    unsetenv("KIMI_BASE_URL")
    unsetenv("MOONSHOT_API_KEY")
    unsetenv("MOONSHOT_BASE_URL")
    defer {
        unsetenv("KIMI_API_KEY")
        unsetenv("KIMI_BASE_URL")
        unsetenv("MOONSHOT_API_KEY")
        unsetenv("MOONSHOT_BASE_URL")
        try? FileManager.default.removeItem(atPath: ConfigStore.defaultPath())
    }

    // 1) 正常解析：data[0].available_balance（字符串）+ currency → Decimal；单 Key 掩码标签
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(request.url?.absoluteString, "https://mock.test/v1/users/me/balance", "Kimi 余额请求 URL")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", "Kimi 鉴权头")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"data":[{"available_balance":"88.50","voucher_balance":"0.00","currency":"CNY","is_available":true}]}"#.utf8))
        }
        let snapshot = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectEqual(snapshot.providerID, "kimi", "Kimi 快照 providerID")
        expectEqual(snapshot.balance, Decimal(string: "88.50"), "Kimi 余额解析（字符串 → Decimal）")
        expectEqual(snapshot.currency, "CNY", "Kimi 币种")
        expectNil(snapshot.error, "Kimi 成功快照无 error")
        // 对齐 DeepSeek：balances 逐 Key 展示（单 Key 时用掩码标签）
        expectEqual(snapshot.balances.count, 1, "Kimi 单 Key 也填充 balances")
        expectTrue(snapshot.balances[0].label.contains("••••"), "Kimi 未配置标签回退掩码，实际: \(snapshot.balances[0].label)")
        expectEqual(snapshot.balances[0].balance, Decimal(string: "88.50"), "Kimi balances 余额")
    }

    // 2) 现行响应：data 为字典（无 currency）→ 余额解析 + 币种默认 CNY
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}"#.utf8))
        }
        let snapshot = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectEqual(snapshot.balance, Decimal(string: "49.58894"), "Kimi 字典 data 的 available_balance 解析")
        expectEqual(snapshot.currency, "CNY", "Kimi 响应无 currency 时默认 CNY")
        expectNil(snapshot.error, "Kimi 字典 data 成功快照无 error")
    }

    // 3) 业务错误：code != 0 → 该 Key 查询失败 → 全部失败抛 upstreamError
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"code":401,"msg":"invalid token","status":false}"#.utf8))
        }
        await expectThrows({
            _ = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "bad-key"))
        }, "Kimi code!=0 全部 Key 失败抛 upstreamError")
    }

    // 4) 顶层 available_balance 回退
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"available_balance":"12.34"}"#.utf8))
        }
        let snapshot = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectEqual(snapshot.balance, Decimal(string: "12.34"), "Kimi 顶层 available_balance 回退")
    }

    // 5) 字段缺失 → 该 Key 失败 → 全部失败抛错
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"data":[]}"#.utf8))
        }
        await expectThrows({
            _ = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        }, "Kimi 字段缺失抛 upstreamError")
    }

    // 6) 非 2xx 抛 upstreamError
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("unauthorized".utf8))
        }
        await expectThrows({
            _ = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "bad-key"))
        }, "Kimi 401 抛 upstreamError")
    }

    // 7) 带标签令牌（对齐 DeepSeek）：config apiKeys 标签展示而非掩码
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        let labeled = RouteConfig(
            providers: [
                "kimi": ProviderConfig(
                    enabled: true,
                    credential: ProviderCredential(),
                    apiKeys: [
                        KeyedToken(label: "主 Key", value: "sk-label-key"),
                        KeyedToken(label: "备用 Key", value: "sk-backup-key"),
                    ]
                ),
            ]
        )
        try ConfigStore.save(labeled)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"code":0,"data":{"available_balance":12.34}}"#.utf8))
        }
        let snapshot = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential())
        expectEqual(snapshot.balances.count, 2, "Kimi config 两令牌均展示")
        let labels = snapshot.balances.map(\.label)
        expectEqual(labels, ["主 Key", "备用 Key"], "Kimi 用量卡展示用户配置的令牌标签")
        expectEqual(snapshot.balances.first?.balance, Decimal(string: "12.34"), "Kimi 标签令牌余额解析")
        // credential 同 value 时展示配置标签而非掩码
        let snapshot2 = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "sk-label-key"))
        expectEqual(snapshot2.balances.first?.label, "主 Key", "Kimi credential 与 config 同 value 时展示配置标签")
        // 清理临时 config，避免影响后续测试
        try? FileManager.default.removeItem(atPath: ConfigStore.defaultPath())
    }

    // 8) 无凭据抛 missingCredentials（不触发网络）
    await expectThrows({
        _ = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "Kimi 无凭据抛 missingCredentials")
}

// MARK: - Phase 25: 新用量查询器（URLProtocol mock）

/// OpenCode Go 用量查询器（参考 OmniRoute usage/opencode.ts + opencodeQuotaFetcher.ts）：
func openCodeGoUsageFetcherTests() async throws {
    unsetenv("OPENCODE_GO_API_KEY")
    unsetenv("OPENCODE_GO_QUOTA_URL")
    unsetenv("OPENCODE_GO_BASE_URL")
    defer {
        unsetenv("OPENCODE_GO_API_KEY")
        unsetenv("OPENCODE_GO_QUOTA_URL")
        unsetenv("OPENCODE_GO_BASE_URL")
    }

    // 1) 正常解析：quota 包三窗口（snake_case + 时间戳）
    try await withGlobalURLProtocolMock {
        setenv("OPENCODE_GO_QUOTA_URL", "https://mock.test/zen/go/v1/quota", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(request.url?.absoluteString, "https://mock.test/zen/go/v1/quota", "OpenCode Go 用量请求 URL")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key", "OpenCode Go 用量鉴权头")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let body = #"{"quota":{"window_5h":{"used":6,"limit":12,"reset_after_seconds":18000},"window_weekly":{"used":12,"limit":30,"reset_at":"2099-01-01T00:00:00Z"},"window_monthly":{"used":0,"limit":60}},"limit_reached":false}"#
            return (response, Data(body.utf8))
        }
        let snapshot = try await OpenCodeGoUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectNil(snapshot.error, "OpenCode Go 成功快照无 error")
        expectEqual(snapshot.quotaWindows.count, 3, "OpenCode Go 三个配额窗口")
        let fiveHour = snapshot.quotaWindows[0]
        expectEqual(fiveHour.label, "$12 / 5小时", "5h 窗口标签")
        expectEqual(fiveHour.used, 6, "5h 窗口 used = 6")
        expectEqual(fiveHour.total, 12, "5h 窗口 total = 12")
        expectTrue(abs(fiveHour.remainingFraction - 0.5) < 0.001, "5h 窗口剩余 50%")
        if let reset = fiveHour.resetAt {
            let diff = reset.timeIntervalSinceNow
            expectTrue(abs(diff - 18000) < 5, "5h 窗口 reset_after_seconds → now + 5h，实际差值 \(diff)")
        } else {
            expectTrue(false, "5h 窗口应有重置时间")
        }
        expectEqual(snapshot.quotaWindows[1].total, 30, "周窗口 total = 30")
        expectEqual(snapshot.quotaWindows[2].total, 60, "月窗口 total = 60")
    }

    // 2) 备用字段名（data 包 + used_amount/limit_amount + 毫秒时间戳）
    try await withGlobalURLProtocolMock {
        setenv("OPENCODE_GO_QUOTA_URL", "https://mock.test/zen/go/v1/quota", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            let futureMS = Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
            let body = #"{"data":{"5h":{"used_amount":"3","limit_amount":"12","reset_at":"\#(futureMS)"}}}"#
            return (response, Data(body.utf8))
        }
        let snapshot = try await OpenCodeGoUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectEqual(snapshot.quotaWindows.count, 1, "备用字段名解析 1 个窗口")
        let window = snapshot.quotaWindows[0]
        expectEqual(window.used, 3, "used_amount 字符串解析")
        expectEqual(window.total, 12, "limit_amount 字符串解析")
        if let reset = window.resetAt {
            let diff = reset.timeIntervalSinceNow
            expectTrue(abs(diff - 3600) < 5, "毫秒时间戳 → 重置时间，实际差值 \(diff)")
        } else {
            expectTrue(false, "应有重置时间")
        }
    }

    // 3) 404（配额 API 未公开）→ error 快照，不抛错
    try await withGlobalURLProtocolMock {
        setenv("OPENCODE_GO_QUOTA_URL", "https://mock.test/zen/go/v1/quota", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("not found".utf8))
        }
        let snapshot = try await OpenCodeGoUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectTrue(snapshot.error?.contains("404") == true, "OpenCode Go 404 → error 快照，实际: \(snapshot.error ?? "nil")")
    }

    // 4) 无凭据抛 missingCredentials（不触发网络）
    await expectThrows({
        _ = try await OpenCodeGoUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "OpenCode Go 无凭据抛 missingCredentials")
}

/// CodeBuddy CN 用量查询器（参考 OmniRoute usage/codebuddy-cn.ts）：
/// - OAuth 登录 token 调腾讯计费接口 → data.Response.Data.Accounts[]
/// - 循环包（CycleEndTime 远早于 DeductionEndTime）读 Cycle 字段，按周期标签；
///   赠送包读 Capacity 字段，按到期编号
/// - 401/403 → 错误快照；code != 0 → 错误快照；无凭据 → 抛错
func codeBuddyCnUsageFetcherTests() async throws {
    unsetenv("CODEBUDDY_CN_ACCESS_TOKEN")
    unsetenv("CODEBUDDY_CN_USAGE_URL")
    defer {
        unsetenv("CODEBUDDY_CN_ACCESS_TOKEN")
        unsetenv("CODEBUDDY_CN_USAGE_URL")
    }

    // 1) 正常解析：code=0 + data{credit, limitNum, cycleResetTime} → 单个积分窗口
    try await withGlobalURLProtocolMock {
        setenv("CODEBUDDY_CN_USAGE_URL", "https://mock.test/billing/meter/get-enterprise-user-usage", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(request.url?.absoluteString, "https://mock.test/billing/meter/get-enterprise-user-usage", "CodeBuddy CN 积分请求 URL")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token", "CodeBuddy CN 鉴权头")
            expectEqual(request.value(forHTTPHeaderField: "x-client-platform"), "web", "CodeBuddy CN 客户端平台头")
            expectEqual(request.value(forHTTPHeaderField: "x-enterprise-id"), "fjm1ce4mdxc0", "CodeBuddy CN 企业 ID 头")
            let body = #"{"code":0,"msg":"OK","data":{"credit":8988.44,"cycleStartTime":"2026-07-21 00:00:00","cycleEndTime":"2026-08-20 23:59:59","limitNum":13000,"cycleResetTime":"2026-08-21 00:00:00"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
        }
        let snapshot = try await CodeBuddyCnUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "test-token", workspaceId: "fjm1ce4mdxc0"))
        expectNil(snapshot.error, "CodeBuddy CN 成功快照无 error，实际: \(snapshot.error ?? "nil")")
        expectEqual(snapshot.quotaWindows.count, 1, "CodeBuddy CN 单个积分窗口")
        let window = snapshot.quotaWindows[0]
        expectEqual(window.label, "积分", "积分窗口标签")
        expectEqual(window.used, 8988, "已用积分 = credit = 8988.44")
        expectEqual(window.total, 13000, "周期总积分 = limitNum")
        expectTrue(abs(window.remainingFraction - 0.3086) < 0.001, "剩余比例 ≈ (13000-8988.44)/13000 ≈ 30.9%")
        if let reset = window.resetAt {
            let components = Calendar.current.dateComponents([.year, .month, .day], from: reset)
            expectEqual(components.year, 2026, "重置时间年份 2026")
            expectEqual(components.month, 8, "重置时间月份 8")
            expectEqual(components.day, 21, "重置时间日期 21")
        } else {
            expectTrue(false, "应有重置时间")
        }
    }

    // 2) 鉴权失败 401 → 错误快照（提示重新登录，不抛错）
    try await withGlobalURLProtocolMock {
        setenv("CODEBUDDY_CN_USAGE_URL", "https://mock.test/billing/meter/get-enterprise-user-usage", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data("unauthorized".utf8))
        }
        let snapshot = try await CodeBuddyCnUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "bad-token", workspaceId: "fjm1ce4mdxc0"))
        expectTrue(snapshot.error?.contains("重新登录") == true, "CodeBuddy CN 401 → 重新登录提示，实际: \(snapshot.error ?? "nil")")
    }

    // 3) 业务错误 code != 0 → 错误快照（带 msg）
    try await withGlobalURLProtocolMock {
        setenv("CODEBUDDY_CN_USAGE_URL", "https://mock.test/billing/meter/get-enterprise-user-usage", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"code":400,"msg":"bad request"}"#.utf8))
        }
        let snapshot = try await CodeBuddyCnUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "test-token", workspaceId: "fjm1ce4mdxc0"))
        expectTrue(snapshot.error?.contains("bad request") == true, "CodeBuddy CN code!=0 → 错误快照，实际: \(snapshot.error ?? "nil")")
    }

    // 4) 缺少 credit / limitNum → 错误快照
    try await withGlobalURLProtocolMock {
        setenv("CODEBUDDY_CN_USAGE_URL", "https://mock.test/billing/meter/get-enterprise-user-usage", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"code":0,"data":{}}"#.utf8))
        }
        let snapshot = try await CodeBuddyCnUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "test-token", workspaceId: "fjm1ce4mdxc0"))
        expectTrue(snapshot.error?.contains("credit") == true, "CodeBuddy CN 缺字段 → 错误快照，实际: \(snapshot.error ?? "nil")")
    }

    // 5) 缺少企业 ID → 错误快照（提示配置 x-enterprise-id，不发网络）
    try await withGlobalURLProtocolMock {
        URLProtocolMock.reset()
        let snapshot = try await CodeBuddyCnUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "test-token"))
        expectTrue(snapshot.error?.contains("企业 ID") == true, "CodeBuddy CN 缺企业 ID → 错误快照，实际: \(snapshot.error ?? "nil")")
        expectEqual(URLProtocolMock.requestCount, 0, "缺企业 ID 不发网络请求")
    }

    // 6) 无凭据抛 missingCredentials（不触发网络）
    await expectThrows({
        _ = try await CodeBuddyCnUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "CodeBuddy CN 无凭据抛 missingCredentials")
}

// MARK: - CodeBuddy OAuth 登录账号标识（纯单测）

/// 登录账号标识提取：token 响应字段优先，JWT payload 兜底。
func codeBuddyIdentityTests() {
    // 1) 从 token 响应 payload 提取（email 优先）
    let emailIdentity = CodeBuddyOAuthClient.identity(from: ["email": "user@example.com", "userName": "zhangsan"])
    expectEqual(emailIdentity, "user@example.com", "identity 优先 email")
    let userNameIdentity = CodeBuddyOAuthClient.identity(from: ["nickName": "张三", "phoneNumber": "13800138000"])
    expectEqual(userNameIdentity, "张三", "identity 回退 nickName")
    let phoneIdentity = CodeBuddyOAuthClient.identity(from: ["phone_number": "13800138000"])
    expectEqual(phoneIdentity, "13800138000", "identity 回退手机号")
    expectNil(CodeBuddyOAuthClient.identity(from: ["state": "abc"]), "无身份字段返回 nil")

    // 2) JWT payload 提取（base64url）
    func jwt(_ payload: [String: Any]) -> String {
        let header = "eyJhbGciOiJub25lIn0" // {"alg":"none"}
        let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let b64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(b64).sig"
    }
    let jwtIdentity = CodeBuddyOAuthClient.jwtIdentity(jwt(["email": "jwt@example.com", "sub": "u-123"]))
    expectEqual(jwtIdentity, "jwt@example.com", "JWT payload 提取 email")
    let jwtName = CodeBuddyOAuthClient.jwtIdentity(jwt(["name": "李四"]))
    expectEqual(jwtName, "李四", "JWT payload 回退 name")
    expectNil(CodeBuddyOAuthClient.jwtIdentity("not-a-jwt"), "非 JWT 返回 nil")
    expectNil(CodeBuddyOAuthClient.jwtIdentity("header.payload"), "payload 非 JSON 返回 nil")
}


// MARK: - 通用 OpenAI 兼容 Provider（自定义 provider，URLProtocol mock）

/// `GenericOpenAIProvider` 集成测试：
/// - listModels 返回不带 `<id>/` 前缀的模型，外层统一拼接
/// - chat 透传 SSE、设置 Bearer 头、剥前缀后转发上游
/// - 缺 key 抛 missingCredentials
func genericOpenAIProviderTests() async throws {
    URLProtocol.registerClass(URLProtocolMock.self)
    defer {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }

    let provider = GenericOpenAIProvider(
        id: "unisound",
        baseURL: URL(string: "https://mock.test/v1")!,
        models: ["glm-5.2"]
    )

    // 1) listModels 返回不带前缀的模型，避免外层拼接成双重前缀
    let models = try await provider.listModels(credential: nil)
    expectEqual(models.map(\.id), ["glm-5.2"], "GenericOpenAIProvider listModels 不带前缀")

    // 2) chat 缺 key 抛 missingCredentials
    await expectThrows({
        let req = ChatRequest(model: "unisound/glm-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true)
        _ = try await provider.chat(request: req, rawBody: nil, credential: nil)
    }, "GenericOpenAIProvider 缺 key 抛 missingCredentials")

    // 3) 不存在模型的 404 不能被当作“收到首个 chunk”而判定成功。
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 404, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(#"{"error":{"message":"model not found"}}"#.utf8))
    }
    await expectThrows({
        _ = try await provider.testModel("unisound/not-exists", credential: ProviderCredential(apiKey: "sk-test"))
    }, "GenericOpenAIProvider 不存在模型测试应失败")

    // 4) chat 透传 SSE + Bearer 头 + 剥前缀
    let sse =
        sseChunk(#"{"id":"chatcmpl-mock","model":"glm-5.2","choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        + sseChunk("[DONE]")

    // 用非闭包变量捕获请求（requestHandler 是 @Sendable 闭包）
    let captured = RequestCapture()
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        captured.auth = request.value(forHTTPHeaderField: "Authorization")
        captured.body = readRequestBody(request)
        captured.url = request.url
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }

    let request = ChatRequest(model: "unisound/glm-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true)
    let stream = try await provider.chat(request: request, rawBody: nil, credential: ProviderCredential(apiKey: "sk-test"))
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""

    expectEqual(captured.auth, "Bearer sk-test", "GenericOpenAIProvider Bearer 头")
    expectTrue(text.contains(#""content":"Hi""#), "GenericOpenAIProvider SSE 透传包含 Hi")
    expectTrue(text.contains("[DONE]"), "GenericOpenAIProvider SSE 透传含 [DONE]")

    // URL 应为 <baseURL>/chat/completions
    expectEqual(captured.url?.absoluteString, "https://mock.test/v1/chat/completions", "GenericOpenAIProvider chat URL")

    // 兼容用户误填完整 `/chat/completions` 的 Base URL，不应追加第二次。
    let fullPathProvider = GenericOpenAIProvider(
        id: "unisound",
        baseURL: URL(string: "https://mock.test/v1/chat/completions")!,
        models: ["glm-5.2"]
    )
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        captured.url = request.url
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }
    let fullPathStream = try await fullPathProvider.chat(
        request: request, rawBody: nil, credential: ProviderCredential(apiKey: "sk-test"))
    for try await chunk in fullPathStream { _ = chunk }
    expectEqual(captured.url?.absoluteString, "https://mock.test/v1/chat/completions", "完整 chat URL 兼容归一化")

    // 请求体里 model 应剥前缀（glm-5.2，不带 unisound/）
    if let body = captured.body,
       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let model = json["model"] as? String {
        expectEqual(model, "glm-5.2", "GenericOpenAIProvider chat 剥前缀后转发上游")
    } else {
        failed += 1
        print("FAIL: GenericOpenAIProvider 无法解析请求体 model 字段")
    }

    // 4) rawBody 透传路径也剥前缀
    let rawBody = Data(#"{"model":"unisound/glm-5.2","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
    let captured2 = RequestCapture()
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        captured2.body = readRequestBody(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }
    let stream2 = try await provider.chat(request: request, rawBody: rawBody, credential: ProviderCredential(apiKey: "sk-test"))
    for try await chunk in stream2 { _ = chunk }
    if let body = captured2.body,
       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let model = json["model"] as? String {
        expectEqual(model, "glm-5.2", "GenericOpenAIProvider rawBody 透传剥前缀")
    } else {
        failed += 1
        print("FAIL: GenericOpenAIProvider rawBody 路径无法解析 model 字段")
    }

    // 5) 双重前缀容错：用户误存 `unisound/glm-5.2` 时，构造归一化 + chat 全部剥掉
    let dupProvider = GenericOpenAIProvider(
        id: "unisound",
        baseURL: URL(string: "https://mock.test/v1")!,
        models: ["unisound/glm-5.2", "unisound/unisound/glm-5.2-flash"]
    )
    let dupModels = try await dupProvider.listModels(credential: nil)
    expectEqual(
        dupModels.map(\.id),
        ["glm-5.2", "glm-5.2-flash"],
        "GenericOpenAIProvider 构造时归一化双重前缀模型名"
    )

    let captured3 = RequestCapture()
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        captured3.body = readRequestBody(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }
    let dupRequest = ChatRequest(model: "unisound/unisound/glm-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true)
    let stream3 = try await dupProvider.chat(request: dupRequest, rawBody: nil, credential: ProviderCredential(apiKey: "sk-test"))
    for try await chunk in stream3 { _ = chunk }
    if let body = captured3.body,
       let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
       let model = json["model"] as? String {
        expectEqual(model, "glm-5.2", "GenericOpenAIProvider chat 剥掉全部重复前缀")
    } else {
        failed += 1
        print("FAIL: GenericOpenAIProvider 双重前缀路径无法解析 model 字段")
    }
}

/// 读取 URLRequest 的请求体：优先 `httpBody`，回退 `httpBodyStream`。
/// URLProtocol 拦截时 URLSession 常把 body 转成 stream，`httpBody` 为 nil。
func readRequestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data
}

/// 请求捕获器（绕过 @Sendable 闭包对捕获变量的限制）。
final class RequestCapture: @unchecked Sendable {
    var auth: String?
    var body: Data?
    var url: URL?
}

/// `ProviderRegistry.unregister` 测试：注册 → 注销 → 验证移除。
func registryUnregisterTests() {
    let registry = ProviderRegistry.shared
    let testID = "test-custom-prov"

    // 先确保不存在
    registry.unregister(testID)
    expectNil(registry.descriptor(for: testID), "注销前确认不存在")

    let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(id: testID, alias: testID, displayName: "Test Custom", authType: .apiKey),
        baseURL: URL(string: "https://example.com/v1"),
        models: [Model(id: "test-model")],
        isUserDefined: true,
        makeProvider: { GenericOpenAIProvider(id: testID, baseURL: URL(string: "https://example.com/v1")!, models: ["test-model"]) }
    )
    registry.register(descriptor)
    expectEqual(registry.descriptor(for: testID)?.id, testID, "注册后可查询")
    expectEqual(registry.canonicalProviderID(testID), testID, "alias 解析为 canonical id")
    expectEqual(registry.providers(forModel: "test-model"), [testID], "反向索引包含 test-model")

    registry.unregister(testID)
    expectNil(registry.descriptor(for: testID), "注销后查询返回 nil")
    expectNil(registry.canonicalProviderID(testID), "注销后 alias 不再解析")
    expectEqual(registry.providers(forModel: "test-model"), [], "注销后反向索引清空")
}

/// Router 对自定义 provider 的显式前缀解析测试。
func routerCustomProviderTests() {
    let registry = ProviderRegistry.shared
    let router = Router(registry: registry)
    let testID = "test-router-prov"

    registry.unregister(testID)
    let descriptor = ProviderDescriptor(
        metadata: ProviderMetadata(id: testID, alias: testID, displayName: "Test Router", authType: .apiKey),
        baseURL: URL(string: "https://example.com/v1"),
        models: [],
        isUserDefined: true,
        makeProvider: { GenericOpenAIProvider(id: testID, baseURL: URL(string: "https://example.com/v1")!, models: ["alpha"]) }
    )
    registry.register(descriptor)
    defer { registry.unregister(testID) }

    // 显式前缀解析（descriptor.models 为空也走 Stage 1）
    if let r = router.resolve("\(testID)/alpha") {
        expectEqual(r.providerID, testID, "自定义 provider 显式前缀解析 providerID")
        expectEqual(r.modelID, "alpha", "自定义 provider 显式前缀解析 modelID")
    } else {
        failed += 1
        print("FAIL: \(testID)/alpha 应解析成功")
    }

    // alias 前缀同样解析
    if let r = router.resolve("\(testID)/beta") {
        expectEqual(r.providerID, testID, "自定义 provider alias 前缀解析")
        expectEqual(r.modelID, "beta", "自定义 provider alias 前缀 modelID 透传")
    } else {
        failed += 1
        print("FAIL: \(testID)/beta 应解析成功")
    }

    // 裸模型不解析（静态目录为空，不参与裸名消歧）
    expectNil(router.resolve("alpha"), "自定义 provider 裸模型不参与消歧")
}

/// `CustomProviderDef` 配置编解码测试：snake_case 持久化 + 向后兼容（缺字段回退空数组）。
func customProviderConfigCodecTests() throws {
    let def = CustomProviderDef(id: "unisound", displayName: "Unisound", baseURL: "https://api.unisound.com/v1", models: ["glm-5.2", "glm-5.2-flash"])

    // 1) 通过 RouteConfig 完整编解码
    let config = RouteConfig(customProviderDefs: [def])
    let encoded = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(RouteConfig.self, from: encoded)
    expectEqual(decoded.customProviderDefs.count, 1, "编解码后 customProviderDefs 数量")
    expectEqual(decoded.customProviderDef(for: "unisound")?.displayName, "Unisound", "编解码后 displayName 保留")
    expectEqual(decoded.customProviderDef(for: "unisound")?.baseURL, "https://api.unisound.com/v1", "编解码后 baseURL 保留")
    expectEqual(decoded.customProviderDef(for: "unisound")?.models, ["glm-5.2", "glm-5.2-flash"], "编解码后 models 保留")

    // 2) 真实 ConfigStore snake_case 持久化：base_url 不能因 acronym 解码失败而丢失整个配置。
    let configPath = NSTemporaryDirectory() + "binvia-config-codec-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: configPath) }
    try ConfigStore.save(config, to: configPath)
    let persisted = try ConfigStore.load(path: configPath)
    expectEqual(persisted.customProviderDef(for: "unisound")?.baseURL, "https://api.unisound.com/v1", "ConfigStore base_url 解码")
    expectEqual(persisted.customProviderDef(for: "unisound")?.models, ["glm-5.2", "glm-5.2-flash"], "ConfigStore models 保留")

    // 3) 旧配置（无 customProviderDefs 字段）解码后回退空数组
    let legacyJSON = Data(#"{"version":2,"host":"localhost","port":20427,"apiKeys":[],"providers":{}}"#.utf8)
    let legacy = try JSONDecoder().decode(RouteConfig.self, from: legacyJSON)
    expectEqual(legacy.customProviderDefs, [], "旧配置无 customProviderDefs 字段时回退空数组")

    // 4) slug 生成
    expectEqual(CustomProviderDef.slug(for: "Unisound"), "unisound", "slug 基本生成")
    expectEqual(CustomProviderDef.slug(for: "My Provider!"), "my-provider", "slug 非字母数字替换为连字符")
    expectEqual(CustomProviderDef.slug(for: "我的API"), "api", "slug 非 ASCII 字母被剔除")
    expectEqual(CustomProviderDef.slug(for: "==="), "custom", "slug 全空回退 custom")

    // 5) uniqueSlug 冲突追加序号
    expectEqual(
        CustomProviderDef.uniqueSlug(for: "openai", excluding: ["openai", "openai-2"]),
        "openai-3",
        "uniqueSlug 冲突时追加序号"
    )
    expectEqual(
        CustomProviderDef.uniqueSlug(for: "fresh", excluding: ["openai"]),
        "fresh",
        "uniqueSlug 无冲突时直接返回 base"
    )
}

// MARK: - Phase 22: Token 用量提取器与聚合

/// ChatMessage/ChatContent 宽容解码测试（参考 OmniRoute 的宽松透传）。
/// 覆盖 `role: "developer"`、`content` 数组（含 image_url 对象）、未知 role 回退、字面量构造。
func chatMessageTolerantDecodeTests() throws {
    // 1) developer role：不再 400
    let devJSON = Data(#"{"model":"m","messages":[{"role":"developer","content":"be helpful"}]}"#.utf8)
    let devReq = try JSONDecoder().decode(ChatRequest.self, from: devJSON)
    expectEqual(devReq.messages.count, 1, "developer role 消息解析成功")
    expectEqual(devReq.messages[0].role, .developer, "developer role 保留")
    expectEqual(devReq.messages[0].content?.textValue, "be helpful", "developer 消息文本")

    // 2) content 数组（多模态 / file part），image_url 为对象形态
    let partsJSON = Data(#"{"model":"m","messages":[{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"https://x/y.png"}}]}]}"#.utf8)
    let partsReq = try JSONDecoder().decode(ChatRequest.self, from: partsJSON)
    expectEqual(partsReq.messages.count, 1, "content 数组消息解析成功")
    expectEqual(partsReq.messages[0].content, .parts([
        ChatContentPart(type: "text", text: "hi"),
        ChatContentPart(type: "image_url", imageURL: "https://x/y.png"),
    ]), "content 数组解析为 parts（image_url 对象取 url）")
    expectEqual(partsReq.messages[0].content?.textValue, "hi", "parts textValue 只拼文本块")

    // 3) 未知 role → 回退 .user，不 400
    let unknownJSON = Data(#"{"model":"m","messages":[{"role":"computer","content":"ok"}]}"#.utf8)
    let unknownReq = try JSONDecoder().decode(ChatRequest.self, from: unknownJSON)
    expectEqual(unknownReq.messages[0].role, .user, "未知 role 回退 user")

    // 4) 字符串字面量构造 + 编解码往返
    let msg = ChatMessage(role: .user, content: "hi")
    expectEqual(msg.content?.textValue, "hi", "字面量构造为 .text")
    let req = ChatRequest(model: "m", messages: [msg], stream: false)
    let data = try JSONEncoder().encode(req)
    let round = try JSONDecoder().decode(ChatRequest.self, from: data)
    expectEqual(round.messages[0].content, .text("hi"), "往返后 content 保留")
    expectEqual(round.messages[0].role, .user, "往返后 role 保留")

    // 5) content: null → nil
    let nullJSON = Data(#"{"model":"m","messages":[{"role":"assistant","content":null}]}"#.utf8)
    let nullReq = try JSONDecoder().decode(ChatRequest.self, from: nullJSON)
    expectNil(nullReq.messages[0].content, "content null → nil")

    // 6) content 为未知结构（对象）→ 兜底为空文本，不 400
    let objJSON = Data(#"{"model":"m","messages":[{"role":"user","content":{"weird":true}}]}"#.utf8)
    let objReq = try JSONDecoder().decode(ChatRequest.self, from: objJSON)
    expectEqual(objReq.messages[0].content?.textValue, "", "未知结构 content 兜底为空文本")
}

func tokenUsageExtractorTests() {
    // 1) 流式带 usage 的 chunk（完整 SSE 事件）
    let e1 = TokenUsageExtractor()
    let chunk1 = Data(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#.utf8)
    let out1 = e1.process(chunk1)
    expectEqual(out1, chunk1, "透传 chunk 原样返回（1）")
    e1.process(Data("\n\ndata: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":34,\"total_tokens\":46}}\n\n".utf8))
    if let tokens = e1.finish() {
        expectEqual(tokens.promptTokens, 12, "流式 usage prompt_tokens")
        expectEqual(tokens.completionTokens, 34, "流式 usage completion_tokens")
        expectEqual(tokens.totalTokens, 46, "流式 usage total_tokens")
    } else {
        failed += 1
        print("FAIL: 流式带 usage 的 chunk 应提取到 tokens")
    }

    // 2) 非流式整段 JSON（无 data: 前缀、无 \n\n）
    let e2 = TokenUsageExtractor()
    e2.process(Data(#"{"model":"x","usage":{"prompt_tokens":7,"completion_tokens":9,"total_tokens":16}}"#.utf8))
    if let tokens = e2.finish() {
        expectEqual(tokens.totalTokens, 16, "非流式整段 JSON usage 提取")
        expectEqual(tokens.promptTokens, 7, "非流式整段 JSON prompt_tokens")
    } else {
        failed += 1
        print("FAIL: 非流式整段 JSON 应提取到 tokens")
    }

    // 3) 无 usage 的响应 → nil
    let e3 = TokenUsageExtractor()
    e3.process(Data("data: {\"choices\":[]}\n\ndata: [DONE]\n\n".utf8))
    expectNil(e3.finish(), "无 usage 响应返回 nil")

    // 4) 多 usage chunk 取最后一个
    let e4 = TokenUsageExtractor()
    e4.process(Data("data: {\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}\n\ndata: {\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"total_tokens\":30}}\n\n".utf8))
    if let tokens = e4.finish() {
        expectEqual(tokens.promptTokens, 10, "多 usage 取最后一个 prompt")
        expectEqual(tokens.totalTokens, 30, "多 usage 取最后一个 total")
    } else {
        failed += 1
        print("FAIL: 多 usage chunk 应取最后一个")
    }

    // 5) chunk 跨事件边界（事件文本被拆到多个 process 调用）
    let e5 = TokenUsageExtractor()
    e5.process(Data("data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":6,\"total_tokens\":11}}".utf8))
    e5.process(Data("\n\n".utf8))
    if let tokens = e5.finish() {
        expectEqual(tokens.totalTokens, 11, "跨 chunk 边界 usage 提取")
    } else {
        failed += 1
        print("FAIL: 跨 chunk 边界应提取到 tokens")
    }

    // 6) total_tokens 缺失时回退 prompt+completion
    let e6 = TokenUsageExtractor()
    e6.process(Data("data: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\n".utf8))
    if let tokens = e6.finish() {
        expectEqual(tokens.totalTokens, 5, "total_tokens 缺失时回退 prompt+completion")
    } else {
        failed += 1
        print("FAIL: total_tokens 缺失时应回退")
    }
}

func requestLoggerTokenTests() {
    let logger = RequestLogger()
    let now = Date()
    let entry = RequestLogEntry(
        timestamp: now, method: "POST", path: "/v1/chat/completions",
        providerID: "deepseek", model: "deepseek-v4-pro",
        statusCode: 200, durationMS: 100)
    let id = entry.id
    logger.log(entry)
    // 流结束回填
    logger.updateTokens(id: id, tokens: TokenUsage(promptTokens: 10, completionTokens: 20, totalTokens: 30))
    // 无 token 的条目
    logger.log(RequestLogEntry(
        timestamp: now, method: "POST", path: "/v1/chat/completions",
        providerID: "deepseek", model: "deepseek-v4-pro",
        statusCode: 200, durationMS: 50))
    expectEqual(logger.allEntries().first?.tokens?.totalTokens, 30, "updateTokens 回填日志条目")

    let summary = logger.summary()
    let ds = summary.byProvider["deepseek"]
    expectEqual(ds?.requestCount, 2, "token 聚合后 requestCount 不变")
    expectEqual(ds?.totalPromptTokens, 10, "summary 聚合 prompt tokens")
    expectEqual(ds?.totalCompletionTokens, 20, "summary 聚合 completion tokens")
    expectEqual(ds?.totalTokens, 30, "summary 聚合 total tokens")

    // 找不到 id 时静默忽略，不影响已有回填
    logger.updateTokens(id: UUID(), tokens: TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2))
    expectEqual(logger.summary().byProvider["deepseek"]?.totalTokens, 30, "未知 id 回填被忽略")

    // 默认 id 自动生成：两条条目 id 不同
    let a = RequestLogEntry(timestamp: Date(), method: "GET", path: "/", providerID: nil, model: nil, statusCode: 200, durationMS: 1)
    let b = RequestLogEntry(timestamp: Date(), method: "GET", path: "/", providerID: nil, model: nil, statusCode: 200, durationMS: 1)
    expectFalse(a.id == b.id, "RequestLogEntry 默认 id 各自唯一")
}

// MARK: - 在线更新检查（UpdateChecker）

func updateCheckerTests() async {
    // 版本号比较
    expectTrue(UpdateChecker.isNewer("0.1.3", than: "0.1.2"), "0.1.3 > 0.1.2")
    expectTrue(UpdateChecker.isNewer("0.1.10", than: "0.1.9"), "0.1.10 > 0.1.9（数字分段比较）")
    expectTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.99"), "0.2.0 > 0.1.99（跨次版本）")
    expectFalse(UpdateChecker.isNewer("0.1.2", than: "0.1.2"), "相等不算更新")
    expectFalse(UpdateChecker.isNewer("0.1.2", than: "0.1.10"), "0.1.2 < 0.1.10")
    expectFalse(UpdateChecker.isNewer("0.1.3", than: "0.2.0"), "低版本不算更新")
    expectFalse(UpdateChecker.isNewer("0.1.2", than: "0.1.2-beta"), "非数字段退化比较")

    // 版本号从重定向 URL 提取
    expectEqual(UpdateChecker.extractVersion(from: "https://github.com/wangbin3162/Binvia/releases/tag/v0.1.3"),
                "0.1.3", "tag URL 提取版本")
    expectEqual(UpdateChecker.extractVersion(from: "https://github.com/wangbin3162/Binvia/releases/tag/v0.1.3/"),
                "0.1.3", "尾部斜杠容忍")
    expectEqual(UpdateChecker.extractVersion(from: "https://github.com/wangbin3162/Binvia/releases/tag/v0.1.3?foo=1"),
                "0.1.3", "查询参数剔除")
    expectNil(UpdateChecker.extractVersion(from: "https://github.com/wangbin3162/Binvia/releases"), "无 tag 返回 nil")

    // fetchLatestRelease：模拟 302 → 200 重定向（URLProtocolMock）
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        if request.url?.path == "/wangbin3162/Binvia/releases/latest" {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": "https://github.com/wangbin3162/Binvia/releases/tag/v0.1.3"])!
            return (response, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let checker = UpdateChecker(session: URLProtocolMock.makeSession())
    do {
        let info = try await checker.fetchLatestRelease()
        expectEqual(info.version, "0.1.3", "重定向解析出最新版本")
        expectEqual(info.htmlURL, "https://github.com/wangbin3162/Binvia/releases/tag/v0.1.3", "Release 页面")
        expectTrue(info.dmgDownloadURL?.hasSuffix(".dmg") == true, "DMG 直链按约定构造")
        expectTrue(UpdateChecker.isNewer(info.version, than: "0.1.2"), "0.1.3 更新于 0.1.2")
    } catch {
        expectEqual("\(error)", "不应抛错", "解析不应抛错")
    }

    // 404 → badResponse
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { _ in
        let response = HTTPURLResponse(url: URL(string: "https://github.com/wangbin3162/Binvia/releases/latest")!,
                                       statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    do {
        _ = try await checker.fetchLatestRelease()
        expectEqual("未抛错", "404 应抛错", "404 应抛错")
    } catch let error as UpdateCheckError {
        if case let .badResponse(code) = error {
            expectEqual(code, 404, "404 错误码透传")
        } else {
            expectEqual("\(error)", "badResponse", "应为 badResponse")
        }
    } catch {
        expectEqual("\(error)", "badResponse", "应为 badResponse")
    }
    URLProtocolMock.reset()
}

/// CodeBuddy 上游请求体卫生化测试（developer→system 角色改写，规避腾讯内容审核误报）。
func codeBuddySanitizeBodyTests() {
    let json: [String: Any] = [
        "model": "glm-5.2",
        "stream": true,
        "reasoning_effort": "high",
        "reasoning_summary": "auto",
        "max_completion_tokens": 131072,
        "messages": [
            ["role": "developer", "content": "be helpful"],
            ["role": "user", "content": "hi"],
        ],
    ]
    let out = CodeBuddyCNProvider.sanitizeBody(json)
    expectEqual(out["model"] as? String, "glm-5.2", "model 保留")
    expectEqual(out["stream"] as? Bool, true, "stream 保留")
    expectEqual(out["max_completion_tokens"] as? Int, 131072, "max_completion_tokens 保留")
    let messages = out["messages"] as! [[String: Any]]
    expectEqual(messages[0]["role"] as? String, "system", "developer 角色改写为 system")
    expectEqual(messages[1]["role"] as? String, "user", "user 角色不动")
    expectEqual(messages[0]["content"] as? String, "be helpful", "消息内容保留")
    expectEqual(messages.count, 2, "messages 保留")

    // ChatRequest 路径：normalizeRoles 同样改写 developer→system
    let dev = ChatMessage(role: .developer, content: "be helpful")
    let usr = ChatMessage(role: .user, content: "hi")
    let normalized = CodeBuddyCNProvider.normalizeRoles([dev, usr])
    expectEqual(normalized[0].role, .system, "ChatRequest 路径 developer→system")
    expectEqual(normalized[1].role, .user, "ChatRequest 路径 user 不动")
}

// MARK: - 入口

// 隔离本机真实配置文件，保证测试确定性（BINVIA_CONFIG 指向不存在的临时路径）
let checkConfigPath = "/tmp/binvia-check-config.json"
try? FileManager.default.removeItem(atPath: checkConfigPath)
unsetenv("BINVIA_CONFIG")
setenv("BINVIA_CONFIG", checkConfigPath, 1)

// 清理可能残留的环境变量
unsetenv("BINVIA_DEBUG_BODY")
unsetenv("DEEPSEEK_API_KEY")
unsetenv("DEEPSEEK_BASE_URL")
unsetenv("CODEBUDDY_CN_ACCESS_TOKEN")
unsetenv("ANTIGRAVITY_ACCESS_TOKEN")
unsetenv("ANTIGRAVITY_BASE_URL")
unsetenv("ANTIGRAVITY_PROJECT_ID")
unsetenv("OPENAI_API_KEY")
unsetenv("OPENAI_BASE_URL")
unsetenv("OPENCODE_API_KEY")
unsetenv("OPENCODE_BASE_URL")
unsetenv("KIMI_API_KEY")
unsetenv("MOONSHOT_API_KEY")
unsetenv("KIMI_BASE_URL")
unsetenv("MOONSHOT_BASE_URL")
unsetenv("ZAI_API_KEY")
unsetenv("ZAI_BASE_URL")
unsetenv("ZAI_QUOTA_URL")
unsetenv("CODEBUDDY_CN_BASE_URL")
unsetenv("MINIMAX_API_KEY")
unsetenv("MINIMAX_BASE_URL")
unsetenv("OPENCODE_GO_API_KEY")
unsetenv("OPENCODE_GO_BASE_URL")
unsetenv("XIAOMI_MIMO_API_KEY")
unsetenv("XIAOMI_MIMO_BASE_URL")
unsetenv("QWEN_CLOUD_API_KEY")
unsetenv("QWEN_CLOUD_BASE_URL")
unsetenv("DASHSCOPE_API_KEY")
unsetenv("CODEX_ACCESS_TOKEN")
unsetenv("CODEX_BASE_URL")
unsetenv("CODEX_OAUTH_CLIENT_ID")
unsetenv("CODEX_TOKEN_URL")
unsetenv("CODEX_AUTHORIZE_URL")
unsetenv("CODEX_REDIRECT_URI")

await run("Router 路由解析与消歧", routerTests)
await run("ProviderRegistry 反向索引", registryReverseIndexTests)
await run("Router 消歧升级", routerDisambiguationTests)
await run("配置 v1→v2 迁移", configMigrationTests)
await run("网关 key 白名单过滤", gatewayKeyWhitelistTests)
await run("供应商模型禁用过滤", providerModelDisableTests)
await run("SSE 解析与聚合", sseTests)
await run("APIKey 认证", apiKeyAuthenticatorTests)
await run("RouteConfig 配置", routeConfigTests)
await run("ModelCache 缓存", modelCacheTests)
await run("RequestLogger 日志聚合", requestLoggerTests)
await run("TokenUsageExtractor 提取", tokenUsageExtractorTests)
await run("RequestLogger token 聚合", requestLoggerTokenTests)
await run("ProviderHTTPClient 重试", httpRetryTests)
await run("RouteHandler 路由分发", routeHandlerTests)
await run("DeepSeek 集成（本地 mock 上游）", deepSeekIntegrationTests)
await run("Antigravity 集成（本地 mock 上游）", antigravityIntegrationTests)
await run("Antigravity 工具调用（翻译单测）", antigravityToolCallTests)
await run("Antigravity 工具调用集成（本地 mock 上游）", antigravityToolCallIntegrationTests)
await run("Antigravity token 刷新（URLProtocol mock）", antigravityTokenRefreshTests)
await run("opencode 集成（本地 mock 上游）", opencodeIntegrationTests)
await run("Kimi 集成（强制流式 + 聚合）", kimiIntegrationTests)
await run("testAllModels 串行批量测试", testAllModelsSuite)
await run("modelsURL 动态模型兜底", dynamicModelsURLSuite)
await run("DeepSeek 用量查询（URLProtocol mock）", deepSeekUsageFetcherTests)
await run("Antigravity 用量查询（URLProtocol mock）", antigravityUsageFetcherTests)
await run("zai 集成（OpenAI 兼容透传，URLProtocol mock）", zaiIntegrationTests)
await run("minimax 集成（OpenAI 兼容透传，URLProtocol mock）", minimaxIntegrationTests)
await run("opencode-go 集成（URLProtocol mock）", opencodeGoIntegrationTests)
await run("xiaomi-mimo 集成（URLProtocol mock）", xiaomiMimoIntegrationTests)
await run("Kimi 用量查询（URLProtocol mock）", kimiUsageFetcherTests)
await run("OpenCode Go 用量查询（URLProtocol mock）", openCodeGoUsageFetcherTests)
await run("CodeBuddy CN 用量查询（URLProtocol mock）", codeBuddyCnUsageFetcherTests)
await run("CodeBuddy OAuth 登录账号标识", codeBuddyIdentityTests)
await run("GenericOpenAIProvider 集成（URLProtocol mock）", genericOpenAIProviderTests)
await run("ProviderRegistry unregister", registryUnregisterTests)
await run("Router 自定义 provider 前缀解析", routerCustomProviderTests)
await run("CustomProviderDef 配置编解码", customProviderConfigCodecTests)
await run("ChatMessage 宽容解码（developer/content 数组）", chatMessageTolerantDecodeTests)
await run("CodeBuddy 角色改写 developer→system", codeBuddySanitizeBodyTests)
await run("在线更新检查（版本比较 + GitHub API 解析）", updateCheckerTests)

print("")
print("========================================")
print("BinviaCheck 完成: passed=\(passed), failed=\(failed)")
if failed > 0 {
    print("存在 \(failed) 个失败断言")
    exit(1)
}
print("全部通过")
exit(0)
