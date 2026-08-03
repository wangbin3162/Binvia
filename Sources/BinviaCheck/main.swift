import Foundation
import BinviaCore
import SQLite3
import zlib

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

// MARK: - OpenAI 集成（本地 HTTPServer 当 mock 上游，Phase 14）

/// OpenAI mock 上游：GET /v1/models 返回模型列表；POST /v1/chat/completions 返回 SSE。
private let openaiMockHandler: @Sendable (HTTPRequest) async throws -> HTTPResponse = { request in
    if request.method == "GET", request.path == "/v1/models" {
        return HTTPResponse.text(
            200,
            #"{"data":[{"id":"mock-gpt-1","owned_by":"mock"}]}"#,
            contentType: "application/json"
        )
    }
    let sse =
        sseChunk(#"{"id":"chatcmpl-openai","model":"gpt-4o","created":1,"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-openai","model":"gpt-4o","created":1,"choices":[{"delta":{"content":" there"},"finish_reason":null}]}"#)
        + sseChunk(#"{"id":"chatcmpl-openai","model":"gpt-4o","created":1,"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
        + sseChunk("[DONE]")
    return HTTPResponse.text(200, sse, contentType: "text/event-stream")
}

func openaiIntegrationTests() async throws {
    // 0) 无凭据时 chat 应同步抛 missingCredentials
    unsetenv("OPENAI_API_KEY")
    unsetenv("OPENAI_BASE_URL")
    let noCredRequest = ChatRequest(
        model: "gpt-4o",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    await expectThrows({ _ = try await OpenAIProvider().chat(request: noCredRequest, rawBody: nil, credential: nil) },
        "无凭据时 OpenAI chat 抛 missingCredentials")

    // 启动本地 mock 上游（真实 socket + HTTP）
    let server = HTTPServer(handler: openaiMockHandler)
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
        print("FAIL: OpenAI 无法启动 mock 上游端口: \(String(describing: lastError))")
        return
    }
    defer {
        server.stop()
        unsetenv("OPENAI_API_KEY")
        unsetenv("OPENAI_BASE_URL")
    }

    setenv("OPENAI_API_KEY", "mock-key", 1)
    setenv("OPENAI_BASE_URL", "http://127.0.0.1:\(port)/v1", 1)
    await ModelCache.shared.invalidate("openai")

    // 1) listModels 命中 mock 上游（默认实现：ModelCache → modelsURL → 静态兜底）
    let models = try await OpenAIProvider().listModels(credential: nil)
    expectEqual(models.map(\.id), ["mock-gpt-1"], "OpenAI listModels 命中 mock 上游")

    // 2) chat stream=true 透传 SSE（含内容块与 [DONE]）
    let streamRequest = ChatRequest(
        model: "gpt-4o",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let stream = try await OpenAIProvider().chat(request: streamRequest, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hi""#), "OpenAI SSE 应包含 Hi 内容块，实际: \(text)")
    expectTrue(text.contains("[DONE]"), "OpenAI SSE 应包含 [DONE]")

    // 3) chat stream=false 透传上游数据（不强制流式，原样转发）
    let nonStreamRequest = ChatRequest(
        model: "gpt-4o",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: false
    )
    let nonStream = try await OpenAIProvider().chat(request: nonStreamRequest, rawBody: nil, credential: nil)
    var raw = Data()
    for try await chunk in nonStream { raw.append(chunk) }
    expectFalse(raw.isEmpty, "OpenAI 非流式请求也应透传上游数据")
    let rawText = String(data: raw, encoding: .utf8) ?? ""
    expectTrue(rawText.contains(#""content":"Hi""#), "OpenAI 非流式透传 SSE 应包含 Hi")

    await ModelCache.shared.invalidate("openai")
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
                return (response, Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","displayName":"Weekly","remainingFraction":0.4,"resetTime":"2026-08-07T00:00:00Z"}]}]}"#.utf8))
            }
            return (response, Data("not found".utf8))
        }

        let snapshot = try await AntigravityUsageFetcher().fetchUsage(credential: ProviderCredential(accessToken: "mock-token"))
        expectEqual(snapshot.providerID, "antigravity", "Antigravity 快照 providerID")
        expectEqual(snapshot.balance, nil, "Antigravity 无余额字段")
        expectNil(snapshot.error, "Antigravity 成功快照无 error")

        // modelQuotas
        expectEqual(snapshot.modelQuotas.count, 1, "retrieveUserQuota 只解析带 remainingFraction 的 bucket")
        if let quota = snapshot.modelQuotas.first {
            expectEqual(quota.modelID, "gemini-3.6-flash-high", "ModelQuota modelID")
            expectEqual(quota.remainingFraction, 0.6, "ModelQuota remainingFraction")
            expectFalse(quota.unlimited, "有 resetTime 时非 unlimited")
            expectEqual(quota.remainingPercentage, 60, "ModelQuota remainingPercentage")
        }

        // quotaWindows
        expectEqual(snapshot.quotaWindows.count, 1, "retrieveUserQuotaSummary 解析出 weekly 窗口")
        if let window = snapshot.quotaWindows.first {
            expectEqual(window.label, "Gemini Models Weekly", "QuotaWindow label")
            expectEqual(window.remainingFraction, 0.4, "QuotaWindow remainingFraction")
            expectEqual(window.total, 1000, "QuotaWindow 归一化 total=1000")
            expectEqual(window.used, 600, "QuotaWindow 归一化 used=600")
            expectEqual(window.remainingPercentage, 40, "QuotaWindow remainingPercentage")
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
        expectEqual(snapshot.modelQuotas.count, 1, "RPC 2 失败不影响 modelQuotas")
        expectTrue(snapshot.modelQuotas[0].unlimited, "resetTime null + fraction>=1 视为 unlimited")
    }
}

// MARK: - Phase 18: Anthropic 信封翻译器（纯单测）

/// Anthropic 兼容上游请求体记录器（锁保护），供 zai / minimax 测试断言。
private final class AnthropicMockState: @unchecked Sendable {
    static let shared = AnthropicMockState()
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

/// 构造带 `event:` 行的 Anthropic SSE 事件。
func anthropicEvent(_ type: String, _ payload: String) -> String {
    "event: \(type)\ndata: \(payload)\n\n"
}

func anthropicTranslatorTests() {
    // —— 请求方向 ——
    let requestMessages: [ChatMessage] = [
        ChatMessage(role: .system, content: "You are helpful"),
        ChatMessage(role: .user, content: "Hello"),
        ChatMessage(role: .assistant, content: "Hi there"),
        ChatMessage(role: .tool, content: "tool result"),
        ChatMessage(role: .user, content: "again"),
    ]
    let body = AnthropicEnvelopeTranslator.makeAnthropicRequest(
        model: "glm-5.2", messages: requestMessages, system: "sys", maxTokens: nil, stream: true
    )
    expectEqual(body["model"] as? String, "glm-5.2", "Anthropic body model")
    expectEqual(body["max_tokens"] as? Int, 4096, "Anthropic max_tokens 未传时默认 4096")
    expectEqual(body["stream"] as? Bool, true, "Anthropic stream 透传")
    expectEqual(body["system"] as? String, "sys", "Anthropic system 独立提取")
    if let msgs = body["messages"] as? [[String: Any]] {
        expectEqual(msgs.count, 4, "Anthropic messages 排除 system 且保留顺序")
        expectEqual(msgs[0]["role"] as? String, "user", "user role 映射")
        expectEqual(msgs[0]["content"] as? String, "Hello", "user content 保留")
        expectEqual(msgs[1]["role"] as? String, "assistant", "assistant role 映射")
        expectEqual(msgs[2]["role"] as? String, "user", "tool role 映射为 user")
        expectEqual(msgs[3]["role"] as? String, "user", "尾部 user 保留")
    } else {
        failed += 1
        print("FAIL: Anthropic messages 结构解析失败")
    }

    // 显式 max_tokens；无 system 时省略 system 字段
    let body2 = AnthropicEnvelopeTranslator.makeAnthropicRequest(
        model: "m", messages: [ChatMessage(role: .user, content: "hi")], system: nil, maxTokens: 128, stream: false
    )
    expectEqual(body2["max_tokens"] as? Int, 128, "Anthropic max_tokens 显式值")
    expectEqual(body2["stream"] as? Bool, false, "Anthropic stream=false 透传")
    expectNil(body2["system"], "无 system 消息时省略 system 字段")

    // —— 响应方向 ——
    var hasRole = false
    var lastStop: String?

    // message_start 忽略
    let start = AnthropicEnvelopeTranslator.translateSSEPayload(
        ["type": "message_start", "message": ["id": "msg_1"]],
        model: "glm-5.2", id: "msg_1", created: 1,
        hasEmittedRole: &hasRole, lastStopReason: &lastStop
    )
    expectNil(start, "message_start 忽略")

    // content_block_delta → 内容块（首个带 role）
    let delta1 = AnthropicEnvelopeTranslator.translateSSEPayload(
        ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello"]],
        model: "glm-5.2", id: "msg_1", created: 1,
        hasEmittedRole: &hasRole, lastStopReason: &lastStop
    )
    expectTrue(delta1 != nil, "text_delta 产出 chunk")
    if let delta1 {
        expectEqual(delta1["object"] as? String, "chat.completion.chunk", "chunk object")
        expectEqual(delta1["model"] as? String, "glm-5.2", "chunk model")
        if let choices = delta1["choices"] as? [[String: Any]], let first = choices.first {
            let d = first["delta"] as? [String: Any]
            expectEqual(d?["role"] as? String, "assistant", "首个内容块发射 role")
            expectEqual(d?["content"] as? String, "Hello", "内容块 content")
        } else {
            failed += 1
            print("FAIL: chunk choices 结构")
        }
    }

    // 第二个内容块不再发射 role
    let delta2 = AnthropicEnvelopeTranslator.translateSSEPayload(
        ["type": "content_block_delta", "delta": ["type": "text_delta", "text": " world"]],
        model: "glm-5.2", id: "msg_1", created: 1,
        hasEmittedRole: &hasRole, lastStopReason: &lastStop
    )
    if let delta2, let choices = delta2["choices"] as? [[String: Any]], let first = choices.first {
        let d = first["delta"] as? [String: Any]
        expectNil(d?["role"], "第二个内容块不再发射 role")
        expectEqual(d?["content"] as? String, " world", "第二个内容块 content")
    } else {
        failed += 1
        print("FAIL: 第二个内容块结构")
    }

    // message_delta end_turn → finish_reason stop
    let stop = AnthropicEnvelopeTranslator.translateSSEPayload(
        ["type": "message_delta", "delta": ["stop_reason": "end_turn"]],
        model: "glm-5.2", id: "msg_1", created: 1,
        hasEmittedRole: &hasRole, lastStopReason: &lastStop
    )
    if let stop, let choices = stop["choices"] as? [[String: Any]], let first = choices.first {
        expectEqual(first["finish_reason"] as? String, "stop", "end_turn → stop")
        expectEqual((first["delta"] as? [String: Any])?.isEmpty, true, "finish chunk delta 为空")
    } else {
        failed += 1
        print("FAIL: message_delta chunk 结构")
    }
    expectEqual(lastStop, "stop", "lastStopReason 记录 stop")

    // message_delta max_tokens → length
    var hasRole2 = true
    var lastStop2: String?
    let length = AnthropicEnvelopeTranslator.translateSSEPayload(
        ["type": "message_delta", "delta": ["stop_reason": "max_tokens"]],
        model: "m", id: "x", created: 1, hasEmittedRole: &hasRole2, lastStopReason: &lastStop2
    )
    if let length, let choices = length["choices"] as? [[String: Any]], let first = choices.first {
        expectEqual(first["finish_reason"] as? String, "length", "max_tokens → length")
    } else {
        failed += 1
        print("FAIL: max_tokens chunk 结构")
    }
    expectEqual(lastStop2, "length", "lastStopReason 记录 length")

    // message_stop 忽略
    var hasRole3 = false
    var lastStop3: String?
    let stopEvent = AnthropicEnvelopeTranslator.translateSSEPayload(
        ["type": "message_stop"], model: "m", id: "x", created: 1,
        hasEmittedRole: &hasRole3, lastStopReason: &lastStop3
    )
    expectNil(stopEvent, "message_stop 忽略")
}

// MARK: - Phase 18: zai / minimax 集成（URLProtocol mock，无本地 HTTPServer）

/// zai / minimax 共享集成测试：stream=true 透传 OpenAI SSE，stream=false 聚合，
/// 并断言上游请求体（恒 stream:true + max_tokens + 正确 roles）。
func runAnthropicCompatSuite(
    providerID: String,
    makeProvider: () -> any Provider,
    apiKeyEnv: String,
    baseURLEnv: String,
    chatModel: String
) async throws {
    AnthropicMockState.shared.reset()
    unsetenv(apiKeyEnv)
    unsetenv(baseURLEnv)
    defer {
        unsetenv(apiKeyEnv)
        unsetenv(baseURLEnv)
    }
    setenv(apiKeyEnv, "mock-key", 1)
    setenv(baseURLEnv, "https://mock.test/anthropic/v1/messages", 1)

    URLProtocol.registerClass(URLProtocolMock.self)
    defer {
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }

    let sse =
        anthropicEvent("message_start", #"{"type":"message_start","message":{"id":"msg_\#(providerID)_1","role":"assistant","content":[],"model":"\#(chatModel)","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":0}}}"#)
        + anthropicEvent("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        + anthropicEvent("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
        + anthropicEvent("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}"#)
        + anthropicEvent("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":9}}"#)
        + anthropicEvent("message_stop", #"{"type":"message_stop"}"#)

    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        expectEqual(
            request.url?.absoluteString,
            "https://mock.test/anthropic/v1/messages?beta=true",
            "\(providerID) 请求 URL 带 ?beta=true"
        )
        expectEqual(request.value(forHTTPHeaderField: "x-api-key"), "mock-key", "\(providerID) x-api-key 头")
        expectEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01", "\(providerID) anthropic-version 头")
        AnthropicMockState.shared.record(body: Data((requestBodyString(request) ?? "").utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(sse.utf8))
    }

    // 1) 客户端 stream=true：OpenAI 格式 SSE 透传（内容 + role + finish_reason + [DONE]）
    let streamReq = ChatRequest(model: chatModel, messages: [ChatMessage(role: .user, content: "hi")], stream: true)
    let stream = try await makeProvider().chat(request: streamReq, rawBody: nil, credential: nil)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""
    expectTrue(text.contains(#""content":"Hello""#), "\(providerID) 流式翻译内容块 Hello，实际: \(text)")
    expectTrue(text.contains(#""content":" world""#), "\(providerID) 流式翻译内容块 world")
    expectTrue(text.contains(#""role":"assistant""#), "\(providerID) 首个内容块带 role")
    expectTrue(text.contains(#""finish_reason":"stop""#), "\(providerID) 流式 finish_reason stop")
    expectTrue(text.contains("[DONE]"), "\(providerID) 流式以 [DONE] 结束")

    // 上游请求体断言：恒 stream:true + max_tokens + messages 正确 roles
    expectEqual(AnthropicMockState.shared.requestCount, 1, "\(providerID) chat 请求上游一次")
    let upstreamBody = AnthropicMockState.shared.lastBody ?? ""
    expectTrue(upstreamBody.contains("\"stream\":true"), "\(providerID) 上游请求体恒 stream=true，实际: \(upstreamBody)")
    expectTrue(upstreamBody.contains("\"max_tokens\":4096"), "\(providerID) 上游请求体默认 max_tokens=4096，实际: \(upstreamBody)")
    expectTrue(upstreamBody.contains("\"model\":\"\(chatModel)\""), "\(providerID) 上游请求体 model")
    expectTrue(upstreamBody.contains("\"role\":\"user\""), "\(providerID) 上游请求体 user role，实际: \(upstreamBody)")

    // 2) 客户端 stream=false：聚合成单个 OpenAI JSON
    AnthropicMockState.shared.reset()
    let nonStreamReq = ChatRequest(model: chatModel, messages: [ChatMessage(role: .user, content: "hi")], stream: false)
    let nonStream = try await makeProvider().chat(request: nonStreamReq, rawBody: nil, credential: nil)
    var chunks: [Data] = []
    for try await chunk in nonStream { chunks.append(chunk) }
    expectEqual(chunks.count, 1, "\(providerID) 非流式客户端拿单个聚合 JSON 块")
    if let json = try? JSONSerialization.jsonObject(with: chunks[0]) as? [String: Any],
       let choices = json["choices"] as? [[String: Any]],
       let first = choices.first,
       let message = first["message"] as? [String: Any] {
        expectEqual(message["content"] as? String, "Hello world", "\(providerID) 聚合内容")
        expectEqual(first["finish_reason"] as? String, "stop", "\(providerID) 聚合 finish_reason")
        expectEqual(json["model"] as? String, chatModel, "\(providerID) 聚合 model")
    } else {
        failed += 1
        print("FAIL: \(providerID) 聚合 JSON 结构解析失败")
    }
    expectEqual(AnthropicMockState.shared.requestCount, 1, "\(providerID) 非流式也请求一次（恒 stream:true）")
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

    try await runAnthropicCompatSuite(
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
        globalURL.hasPrefix("https://api.z.ai/api/anthropic/v1/messages?beta=true"),
        "zai region=global → api.z.ai，实际: \(globalURL)")

    let cnURL = await captureURL(ProviderCredential(apiKey: "mock-key", region: "bigmodel-cn"))
    expectTrue(
        cnURL.hasPrefix("https://open.bigmodel.cn/api/anthropic/v1/messages?beta=true"),
        "zai region=bigmodel-cn → open.bigmodel.cn，实际: \(cnURL)")

    let nilURL = await captureURL(ProviderCredential(apiKey: "mock-key"))
    expectTrue(
        nilURL.hasPrefix("https://open.bigmodel.cn/api/anthropic/v1/messages?beta=true"),
        "zai 缺省 region → 默认 BigModel CN，实际: \(nilURL)")
    unsetenv("ZAI_API_KEY")
}

func minimaxIntegrationTests() async throws {
    try await runAnthropicCompatSuite(
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

func qwenCloudIntegrationTests() async throws {
    try await runOpenAICompatSuite(
        providerID: "qwen-cloud",
        makeProvider: { QwenCloudProvider() },
        apiKeyEnv: "QWEN_CLOUD_API_KEY",
        baseURLEnv: "QWEN_CLOUD_BASE_URL",
        chatModel: "qwen3.7-max"
    )
}

// MARK: - Phase 19: codex / cursor 集成（URLProtocol mock，OpenAI 兼容）

func codexIntegrationTests() async throws {
    try await runOpenAICompatSuite(
        providerID: "codex",
        makeProvider: { CodexProvider() },
        apiKeyEnv: "CODEX_API_KEY",
        baseURLEnv: "CODEX_BASE_URL",
        chatModel: "gpt-5.1-codex-mini"
    )
}

func cursorIntegrationTests() async throws {
    try await runOpenAICompatSuite(
        providerID: "cursor",
        makeProvider: { CursorProvider() },
        apiKeyEnv: "CURSOR_API_KEY",
        baseURLEnv: "CURSOR_BASE_URL",
        chatModel: "claude-sonnet-4-5"
    )
}

// MARK: - Phase 20: Cursor IDE 接入（凭据发现 + IDE 模式 Provider）

/// 造一个临时的 Cursor state.vscdb fixture（itemTable + 指定键值）。
func makeCursorFixtureDB(at path: String, token: String?, machineId: String?) {
    try? FileManager.default.removeItem(atPath: path)
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS itemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil)
    func insert(_ key: String, _ value: String) {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO itemTable (key, value) VALUES (?1, ?2);", -1, &stmt, nil) == SQLITE_OK else { return }
        value.withCString { v in
            sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_step(stmt)
    }
    if let token { insert("cursorAuth/accessToken", token) }
    if let machineId { insert("storage.serviceMachineId", machineId) }
}

func cursorCredentialStoreTests() async throws {
    // 环境隔离：清掉可能影响本机真实凭据的变量
    unsetenv("CURSOR_STATE_DB_PATH")
    unsetenv("CURSOR_TOKEN")
    let dir = NSTemporaryDirectory() + "binvia-cursor-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let dbPath = dir + "/state.vscdb"
    defer {
        unsetenv("CURSOR_STATE_DB_PATH")
        unsetenv("CURSOR_TOKEN")
        try? FileManager.default.removeItem(atPath: dir)
    }

    // 1) 正常读取：token + machineId
    setenv("CURSOR_STATE_DB_PATH", dbPath, 1)
    makeCursorFixtureDB(at: dbPath, token: "eyJ.payload.sig", machineId: "MACHINE-1")
    let d1 = await CursorCredentialStore().detect()
    guard case .found(let id1) = d1 else {
        expectTrue(false, "正常 fixture 应检测到凭据")
        return
    }
    expectEqual(id1.accessToken, "eyJ.payload.sig", "accessToken 解析")
    expectEqual(id1.machineId, "MACHINE-1", "machineId 解析")

    // 2) `{userId}::{jwt}` 双段格式 → 剥离前缀
    makeCursorFixtureDB(at: dbPath, token: "user-123::eyJ.payload.sig", machineId: nil)
    let d2 = await CursorCredentialStore().detect()
    guard case .found(let id2) = d2 else {
        expectTrue(false, "双段格式应检测到凭据")
        return
    }
    expectEqual(id2.accessToken, "eyJ.payload.sig", "剥离 userId:: 前缀")

    // 3) `"..."` JSON 字符串包裹 → 解包
    makeCursorFixtureDB(at: dbPath, token: #""eyJ.payload.sig""#, machineId: nil)
    let d3 = await CursorCredentialStore().detect()
    guard case .found(let id3) = d3 else {
        expectTrue(false, "JSON 包裹格式应检测到凭据")
        return
    }
    expectEqual(id3.accessToken, "eyJ.payload.sig", "JSON 字符串包裹解包")

    // 4) JWT exp 解析（payload 段含 exp 秒级时间戳）
    // base64url("{\"exp\": 1893456000}") = eyJleHAiOiAxODkzNDU2MDAwfQ
    makeCursorFixtureDB(at: dbPath, token: "eyJhbGciOiJIUzI1NiJ9.eyJleHAiOiAxODkzNDU2MDAwfQ.sig", machineId: nil)
    let d4 = await CursorCredentialStore().detect()
    guard case .found(let id4) = d4 else {
        expectTrue(false, "JWT fixture 应检测到凭据")
        return
    }
    expectEqual(id4.expiresAt, Date(timeIntervalSince1970: 1_893_456_000), "JWT exp 解析")

    // 5) 无 accessToken → notSignedIn
    makeCursorFixtureDB(at: dbPath, token: nil, machineId: "M")
    let d5 = await CursorCredentialStore().detect()
    expectEqual(d5, .notSignedIn, "无 accessToken → notSignedIn")

    // 6) 路径不存在 → noInstallation
    setenv("CURSOR_STATE_DB_PATH", dir + "/missing.vscdb", 1)
    let d6 = await CursorCredentialStore().detect()
    expectEqual(d6, .noInstallation, "路径不存在 → noInstallation")

    // 7) CURSOR_TOKEN 环境覆盖（跳过 DB 读取）
    setenv("CURSOR_TOKEN", "env-user::env-jwt", 1)
    let d7 = await CursorCredentialStore().detect()
    guard case .found(let id7) = d7 else {
        expectTrue(false, "CURSOR_TOKEN 覆盖应生效")
        return
    }
    expectEqual(id7.accessToken, "env-jwt", "CURSOR_TOKEN 规范化（双段剥离）")
    unsetenv("CURSOR_TOKEN")

    // 8) 缓存 TTL：fresh 缓存命中，过期后重新探测
    setenv("CURSOR_STATE_DB_PATH", dbPath, 1)
    makeCursorFixtureDB(at: dbPath, token: "tok-a", machineId: nil)
    let store = CursorCredentialStore()
    _ = await store.refresh()  // 缓存 tok-a
    makeCursorFixtureDB(at: dbPath, token: "tok-b", machineId: nil)  // DB 更新为 tok-b
    let cached = await store.identity()
    expectEqual(cached?.accessToken, "tok-a", "缓存命中：返回缓存 token")
    await store.setCacheTTL(0)  // 缓存立即过期
    let refreshed = await store.identity()
    expectEqual(refreshed?.accessToken, "tok-b", "缓存过期后重新探测")
}

func cursorIDEModeTests() async throws {
    // IDE 模式：无 API key，走 CursorCredentialStore（CURSOR_TOKEN 注入）+ protobuf RPC 端点
    unsetenv("CURSOR_API_KEY")
    setenv("CURSOR_BASE_URL", "https://mock.test", 1)
    setenv("CURSOR_TOKEN", "ide-jwt-token", 1)
    defer {
        unsetenv("CURSOR_API_KEY")
        unsetenv("CURSOR_BASE_URL")
        unsetenv("CURSOR_TOKEN")
        unsetenv("CURSOR_STATE_DB_PATH")
    }
    await ModelCache.shared.invalidate("cursor")

    try await withGlobalURLProtocolMock {
        // 构造 Cursor 二进制响应：protobuf 帧（text="Hi"）+ JSON 空帧（流结束）
        let mockBody = cursorTextFrame("Hi") + cursorEndFrame()
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(
                request.url?.absoluteString,
                "https://mock.test/aiserver.v1.ChatService/StreamUnifiedChatWithTools",
                "IDE 模式请求 URL（Connect-RPC 端点）")
            expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/connect+proto", "IDE 模式 Content-Type")
            expectEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1", "IDE 模式 connect-protocol-version")
            expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ide-jwt-token", "IDE 模式 Bearer 用 IDE 令牌")
            expectEqual(request.value(forHTTPHeaderField: "x-cursor-client-type"), "ide", "IDE 头 x-cursor-client-type")
            expectEqual(request.value(forHTTPHeaderField: "x-cursor-client-os"), "macos", "IDE 头 x-cursor-client-os")
            expectEqual(request.value(forHTTPHeaderField: "x-cursor-client-arch"), CursorArch.current, "IDE 头 x-cursor-client-arch")
            expectTrue(request.value(forHTTPHeaderField: "x-client-key") != nil, "IDE 头 x-client-key")
            expectTrue(request.value(forHTTPHeaderField: "x-session-id") != nil, "IDE 头 x-session-id")
            expectTrue(request.value(forHTTPHeaderField: "x-cursor-checksum") == nil, "CURSOR_TOKEN 注入时无 machineId → 无 checksum")
            // 请求体：帧头 0x00 + 4 字节大端长度 + protobuf，且含模型名
                if let body = requestBodyData(request) {
                    expectEqual(body.first, 0x00, "IDE 请求帧类型未压缩")
                    if body.count >= 5 {
                        let len = Int(body[1]) << 24 | Int(body[2]) << 16 | Int(body[3]) << 8 | Int(body[4])
                        expectEqual(len, body.count - 5, "IDE 请求帧长度字段")
                    }
                    // 二进制 protobuf 不能整体转 String，直接在原始字节中搜模型名
                    expectTrue(body.range(of: Data("claude-sonnet-4-5".utf8)) != nil, "IDE 请求含模型名")
                } else {
                    expectTrue(false, "IDE 请求应有二进制 body")
                }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/connect+proto"]
            )!
            return (response, mockBody)
        }

        let provider = CursorProvider()
        let request = ChatRequest(model: "claude-sonnet-4-5", messages: [ChatMessage(role: .user, content: "hi")], stream: true)

        // 1) IDE 模式：protobuf 帧 → SSE 透传（含 [DONE]）
        let stream = try await provider.chat(request: request, rawBody: nil, credential: nil)
        var text = ""
        for try await chunk in stream { text += String(data: chunk, encoding: .utf8) ?? "" }
        expectTrue(text.contains(#""content":"Hi""#), "IDE 模式 SSE 透传 text，实际: \(text)")
        expectTrue(text.contains("[DONE]"), "IDE 模式 SSE 含 [DONE]")

        // 2) gzip 帧解压 + 多消息转换（system 合并进 user）
        let gzipMock = cursorTextFrame("gzip ok", gzipped: true) + cursorEndFrame()
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/connect+proto"]
            )!
            return (response, gzipMock)
        }
        let rawBody = Data(#"{"model":"old","messages":[{"role":"system","content":"你是助手"},{"role":"user","content":"hi"}]}"#.utf8)
        let stream2 = try await provider.chat(request: request, rawBody: rawBody, credential: nil)
        var text2 = ""
        for try await chunk in stream2 { text2 += String(data: chunk, encoding: .utf8) ?? "" }
        expectTrue(text2.contains("gzip ok"), "IDE 模式 gzip 帧解压，实际: \(text2)")

        // 3) 非流式客户端：聚合为 OpenAI 单 JSON
        let nonStream = ChatRequest(model: "claude-sonnet-4-5", messages: [ChatMessage(role: .user, content: "hi")], stream: false)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/connect+proto"]
            )!
            return (response, mockBody)
        }
        let stream3 = try await provider.chat(request: nonStream, rawBody: nil, credential: nil)
        var aggregated = ""
        for try await chunk in stream3 { aggregated += String(data: chunk, encoding: .utf8) ?? "" }
        expectTrue(aggregated.contains(#""content":"Hi""#), "IDE 模式非流式聚合 content，实际: \(aggregated)")
        expectTrue(aggregated.contains(#"chat.completion"#), "IDE 模式非流式聚合为 OpenAI JSON")
    }

    // 4) 无任何凭据（无 API key、无 IDE 令牌、无 DB）→ 抛 missingCredentials
    unsetenv("CURSOR_TOKEN")
    setenv("CURSOR_STATE_DB_PATH", "/nonexistent/state.vscdb", 1)
    await CursorCredentialStore.shared.clearCache()  // 清掉前面用例留下的缓存
    let provider = CursorProvider()
    let request = ChatRequest(model: "claude-sonnet-4-5", messages: [ChatMessage(role: .user, content: "hi")], stream: true)
    do {
        _ = try await provider.chat(request: request, rawBody: nil, credential: nil)
        expectTrue(false, "无任何凭据时应抛 missingCredentials")
    } catch {
        expectTrue(error is ProviderError, "抛 ProviderError")
    }
}

// MARK: - Cursor IDE 测试辅助（手搓 Cursor 响应帧）

/// 构造 Cursor protobuf 文本帧：`StreamUnifiedChatResponseWithTools.field2.text = text`。
/// `gzipped` 时用 zlib 压缩（type=0x01，测试 gunzip 路径）。
func cursorTextFrame(_ text: String, gzipped: Bool = false) -> Data {
    let content = [UInt8](text.utf8)
    // StreamUnifiedChatResponse: field 1 (string) = content
    var chatResp = Data([0x0a, UInt8(content.count)])
    chatResp.append(contentsOf: content)
    // StreamUnifiedChatResponseWithTools: field 2 (message) = chatResp
    var payload = Data([0x12, UInt8(chatResp.count)])
    payload.append(chatResp)
    if gzipped, let compressed = zlibCompress(payload) {
        return Data([0x01]) + cursorLengthBytes(compressed) + compressed
    }
    return Data([0x00]) + cursorLengthBytes(payload) + payload
}

/// zlib 压缩（`compress2`，产生 RFC1950 zlib 流，供 gunzip 测试）。
func zlibCompress(_ data: Data) -> Data? {
    let src = [UInt8](data)
    guard !src.isEmpty else { return nil }
    var dst = [UInt8](repeating: 0, count: Int(compressBound(uLong(src.count))))
    var dstLen = uLong(dst.count)
    let status = src.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Int32 in
        guard let base = srcPtr.baseAddress else { return Z_DATA_ERROR }
        return compress2(&dst, &dstLen, base.assumingMemoryBound(to: Bytef.self), uLong(src.count), Z_BEST_SPEED)
    }
    guard status == Z_OK else { return nil }
    return Data(dst.prefix(Int(dstLen)))
}

/// Cursor 流结束帧：JSON 空对象 `{}`（type=0x02）。
func cursorEndFrame() -> Data {
    Data([0x02, 0x00, 0x00, 0x00, 0x02]) + Data("{}".utf8)
}

/// 4 字节大端长度。
func cursorLengthBytes(_ data: Data) -> Data {
    let n = data.count
    return Data([
        UInt8((n >> 24) & 0xff),
        UInt8((n >> 16) & 0xff),
        UInt8((n >> 8) & 0xff),
        UInt8(n & 0xff),
    ])
}

/// 读取 URLRequest 的原始 body 字节（httpBody 或 httpBodyStream）。
func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
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
    return data
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
    }

    // 1) 正常解析：data[0].available_balance（字符串）→ Decimal
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
    }

    // 2) 顶层 available_balance 回退
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

    // 3) 字段缺失 → error 快照（不抛错）
    try await withGlobalURLProtocolMock {
        setenv("KIMI_BASE_URL", "https://mock.test/v1", 1)
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(#"{"data":[]}"#.utf8))
        }
        let snapshot = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential(apiKey: "test-key"))
        expectNil(snapshot.balance, "字段缺失时 balance 为 nil")
        expectTrue(snapshot.error != nil, "字段缺失时返回 error 快照")
    }

    // 4) 非 2xx 抛 upstreamError
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

    // 5) 无凭据抛 missingCredentials（不触发网络）
    await expectThrows({
        _ = try await KimiUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "Kimi 无凭据抛 missingCredentials")
}

// MARK: - 通用 OpenAI 兼容 Provider（自定义 provider，URLProtocol mock）

/// `GenericOpenAIProvider` 集成测试：
/// - listModels 返回带 `<id>/` 前缀的模型
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

    // 1) listModels 返回带前缀的模型
    let models = try await provider.listModels(credential: nil)
    expectEqual(models.map(\.id), ["unisound/glm-5.2"], "GenericOpenAIProvider listModels 带前缀")

    // 2) chat 缺 key 抛 missingCredentials
    await expectThrows({
        let req = ChatRequest(model: "unisound/glm-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true)
        _ = try await provider.chat(request: req, rawBody: nil, credential: nil)
    }, "GenericOpenAIProvider 缺 key 抛 missingCredentials")

    // 3) chat 透传 SSE + Bearer 头 + 剥前缀
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

    // 2) 旧配置（无 customProviderDefs 字段）解码后回退空数组
    let legacyJSON = Data(#"{"version":2,"host":"localhost","port":20427,"apiKeys":[],"providers":{}}"#.utf8)
    let legacy = try JSONDecoder().decode(RouteConfig.self, from: legacyJSON)
    expectEqual(legacy.customProviderDefs, [], "旧配置无 customProviderDefs 字段时回退空数组")

    // 3) slug 生成
    expectEqual(CustomProviderDef.slug(for: "Unisound"), "unisound", "slug 基本生成")
    expectEqual(CustomProviderDef.slug(for: "My Provider!"), "my-provider", "slug 非字母数字替换为连字符")
    expectEqual(CustomProviderDef.slug(for: "我的API"), "api", "slug 非 ASCII 字母被剔除")
    expectEqual(CustomProviderDef.slug(for: "==="), "custom", "slug 全空回退 custom")

    // 4) uniqueSlug 冲突追加序号
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
await run("TokenUsageExtractor 提取", tokenUsageExtractorTests)
await run("RequestLogger token 聚合", requestLoggerTokenTests)
await run("ProviderHTTPClient 重试", httpRetryTests)
await run("RouteHandler 路由分发", routeHandlerTests)
await run("DeepSeek 集成（本地 mock 上游）", deepSeekIntegrationTests)
await run("Antigravity 集成（本地 mock 上游）", antigravityIntegrationTests)
await run("Antigravity token 刷新（URLProtocol mock）", antigravityTokenRefreshTests)
await run("OpenAI 集成（本地 mock 上游）", openaiIntegrationTests)
await run("opencode 集成（本地 mock 上游）", opencodeIntegrationTests)
await run("Kimi 集成（强制流式 + 聚合）", kimiIntegrationTests)
await run("testAllModels 串行批量测试", testAllModelsSuite)
await run("modelsURL 动态模型兜底", dynamicModelsURLSuite)
await run("DeepSeek 用量查询（URLProtocol mock）", deepSeekUsageFetcherTests)
await run("Antigravity 用量查询（URLProtocol mock）", antigravityUsageFetcherTests)
await run("Anthropic 信封翻译器", anthropicTranslatorTests)
await run("zai 集成（Anthropic SSE→OpenAI，URLProtocol mock）", zaiIntegrationTests)
await run("minimax 集成（Anthropic SSE→OpenAI，URLProtocol mock）", minimaxIntegrationTests)
await run("opencode-go 集成（URLProtocol mock）", opencodeGoIntegrationTests)
await run("xiaomi-mimo 集成（URLProtocol mock）", xiaomiMimoIntegrationTests)
await run("qwen-cloud 集成（URLProtocol mock）", qwenCloudIntegrationTests)
await run("codex 集成（URLProtocol mock）", codexIntegrationTests)
await run("cursor 集成（URLProtocol mock）", cursorIntegrationTests)
await run("Cursor IDE 凭据发现", cursorCredentialStoreTests)
await run("cursor IDE 模式（URLProtocol mock）", cursorIDEModeTests)
await run("Kimi 用量查询（URLProtocol mock）", kimiUsageFetcherTests)
await run("GenericOpenAIProvider 集成（URLProtocol mock）", genericOpenAIProviderTests)
await run("ProviderRegistry unregister", registryUnregisterTests)
await run("Router 自定义 provider 前缀解析", routerCustomProviderTests)
await run("CustomProviderDef 配置编解码", customProviderConfigCodecTests)

print("")
print("========================================")
print("BinviaCheck 完成: passed=\(passed), failed=\(failed)")
if failed > 0 {
    print("存在 \(failed) 个失败断言")
    exit(1)
}
print("全部通过")
exit(0)
