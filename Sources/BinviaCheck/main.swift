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

// MARK: - Phase 19: cursor 集成（URLProtocol mock，OpenAI 兼容）

func cursorIntegrationTests() async throws {
    try await runOpenAICompatSuite(
        providerID: "cursor",
        makeProvider: { CursorProvider() },
        apiKeyEnv: "CURSOR_API_KEY",
        baseURLEnv: "CURSOR_BASE_URL",
        chatModel: "claude-sonnet-4-5"
    )
}

// MARK: - Phase 24: Codex OAuth（chatgpt.com 后端，Responses API）

/// 构造 JWT id_token（header.payload.signature，payload 为 JSON）。
func codexJWT(_ payload: [String: Any]) -> String {
    let header = "eyJhbGciOiJub25lIn0" // {"alg":"none"}
    let payloadData = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    let b64 = payloadData.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "\(header).\(b64).sig"
}

/// Codex OAuth 客户端：exchangeCode / refresh（旋转 token）/ 不可恢复刷新错误 / id_token 解析。
func codexOAuthClientTests() async throws {
    unsetenv("CODEX_OAUTH_CLIENT_ID")
    unsetenv("CODEX_TOKEN_URL")
    unsetenv("CODEX_AUTHORIZE_URL")
    defer {
        unsetenv("CODEX_OAUTH_CLIENT_ID")
        unsetenv("CODEX_TOKEN_URL")
        unsetenv("CODEX_AUTHORIZE_URL")
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }
    setenv("CODEX_TOKEN_URL", "https://mock.test/oauth/token", 1)

    URLProtocol.registerClass(URLProtocolMock.self)
    URLProtocolMock.reset()

    // 1) id_token 解析（纯单测）：team org 非 default 且 plan free → 用 team org id
    let teamPayload: [String: Any] = [
        "email": "me@example.com",
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "acct_personal",
            "chatgpt_plan_type": "free",
            "organizations": [
                ["id": "org_team", "is_default": false, "title": "Team X", "role": "member"],
                ["id": "org_default", "is_default": true, "title": "Personal", "role": "owner"],
            ],
        ],
    ]
    let teamInfo = CodexOAuthClient.parseIdToken(codexJWT(teamPayload))
    expectEqual(teamInfo?.email, "me@example.com", "id_token 解析 email")
    expectEqual(teamInfo?.workspaceId, "org_team", "free plan + team org 时用 team workspace")
    expectEqual(teamInfo?.planType, "free", "id_token 解析 plan type")

    // team plan → 保持 chatgpt_account_id
    let teamPlanPayload: [String: Any] = [
        "https://api.openai.com/auth": [
            "chatgpt_account_id": "acct_team1",
            "chatgpt_plan_type": "chatgptteam",
            "organizations": [
                ["id": "org_a", "is_default": false, "title": "Team A", "role": "member"],
            ],
        ],
    ]
    let teamPlanInfo = CodexOAuthClient.parseIdToken(codexJWT(teamPlanPayload))
    expectEqual(teamPlanInfo?.workspaceId, "acct_team1", "team plan 保持 chatgpt_account_id")

    // 2) exchangeCode：返回 token + id_token → workspace 绑定
    URLProtocolMock.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = #"""
        {"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,
         "id_token":"\#(codexJWT(teamPayload))"}
        """#
        return (response, Data(body.utf8))
    }
    let client = CodexOAuthClient(config: .live())
    let exchanged = try await client.exchangeCode(code: "auth-code", verifier: "verifier-43chars", redirectURI: "http://localhost:1455/auth/callback")
    expectEqual(exchanged.accessToken, "at-1", "exchangeCode 返回 access_token")
    expectEqual(exchanged.refreshToken, "rt-1", "exchangeCode 返回 refresh_token")
    expectEqual(exchanged.workspaceId, "org_team", "exchangeCode 解析 workspace")
    expectEqual(exchanged.email, "me@example.com", "exchangeCode 解析 email")

    // 3) refresh：请求体无 scope；返回旋转后的 refresh_token
    var refreshBody = ""
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        if let body = requestBodyString(request) { refreshBody = body }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(#"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600}"#.utf8))
    }
    let refreshed = try await client.refreshAccessToken(refreshToken: "rt-1")
    expectEqual(refreshed.accessToken, "at-2", "refresh 返回新 access_token")
    expectEqual(refreshed.refreshToken, "rt-2", "refresh 旋转 refresh_token")
    expectFalse(refreshBody.contains("scope"), "refresh 请求体不含 scope（避免 Auth0 re-scope）")
    expectTrue(refreshBody.contains("grant_type=refresh_token"), "refresh 请求体含 grant_type")
    expectTrue(refreshBody.contains("client_id="), "refresh 请求体含 client_id")

    // 4) 不可恢复错误（invalid_grant）→ reauthRequired
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { _ in
        let response = HTTPURLResponse(
            url: URL(string: "https://mock.test/oauth/token")!, statusCode: 400, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(#"{"error":"invalid_grant","error_description":"token already used"}"#.utf8))
    }
    var threwReauth = false
    do {
        _ = try await client.refreshAccessToken(refreshToken: "rt-consumed")
    } catch CodexOAuthError.reauthRequired {
        threwReauth = true
    } catch {}
    expectTrue(threwReauth, "invalid_grant 刷新抛 reauthRequired")

    // 5) 401 → reauthRequired（瞬时 5xx 仍抛 httpStatus）
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { _ in
        let response = HTTPURLResponse(
            url: URL(string: "https://mock.test/oauth/token")!, statusCode: 401, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data("unauthorized".utf8))
    }
    var threwReauth401 = false
    do {
        _ = try await client.refreshAccessToken(refreshToken: "rt-x")
    } catch CodexOAuthError.reauthRequired {
        threwReauth401 = true
    } catch {}
    expectTrue(threwReauth401, "401 刷新抛 reauthRequired")
}

/// Codex 双向翻译器（纯单测）。
func codexTranslatorTests() async throws {
    /// 解析 translatedChunk 产出的 SSE 块（`data:` 行）为 JSON。
    func chunkJSON(_ chunk: Data?) -> [String: Any]? {
        guard let chunk, let text = String(data: chunk, encoding: .utf8),
              let value = SSEEvent.dataValue(from: text),
              let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            return nil
        }
        return json
    }

    // 1) 请求翻译：system→developer、effort 后缀剥离、tools 透传、白名单过滤
    let rawBody: [String: Any] = [
        "model": "gpt-5.6-sol-high",
        "messages": [
            ["role": "system", "content": "You are a coding agent."],
            ["role": "user", "content": "hi"],
            ["role": "tool", "tool_call_id": "call_1", "content": "ok"],
        ],
        "tools": [["type": "function", "name": "shell", "parameters": ["type": "object"]]],
        "temperature": 0.7,
        "max_tokens": 100,
        "stream": true,
    ]
    let bodyData = try JSONSerialization.data(withJSONObject: rawBody)
    let highRequest = ChatRequest(
        model: "gpt-5.6-sol-high",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let requestData = try CodexResponsesTranslator.makeRequestBody(request: highRequest, rawBody: bodyData)
    let requestJSON = (try JSONSerialization.jsonObject(with: requestData) as? [String: Any]) ?? [:]

    expectEqual(requestJSON["model"] as? String, "gpt-5.6-sol", "effort 后缀剥离后 model 为基础名")
    let reasoning = requestJSON["reasoning"] as? [String: Any]
    expectEqual(reasoning?["effort"] as? String, "high", "effort 写入 reasoning.effort")
    expectEqual(requestJSON["stream"] as? Bool, true, "强制 stream=true")
    expectEqual(requestJSON["store"] as? Bool, false, "store=false")
    expectNil(requestJSON["temperature"], "temperature 被白名单过滤")
    expectNil(requestJSON["max_tokens"], "max_tokens 被白名单过滤")

    let input = requestJSON["input"] as? [[String: Any]] ?? []
    expectEqual(input.count, 3, "3 条消息 → 3 个 input item")
    let developer = input[0]
    expectEqual(developer["role"] as? String, "developer", "system → developer")
    let toolOutput = input[2]
    expectEqual(toolOutput["type"] as? String, "function_call_output", "tool → function_call_output")
    expectEqual(toolOutput["call_id"] as? String, "call_1", "function_call_output 带 call_id")
    let tools = requestJSON["tools"] as? [[String: Any]] ?? []
    expectEqual(tools.count, 1, "tools 透传")

    // rawBody 为 nil 时回退编码 ChatRequest（testModel 默认实现走此路径）
    let fallbackData = try CodexResponsesTranslator.makeRequestBody(
        request: highRequest,
        rawBody: nil
    )
    let fallbackJSON = (try JSONSerialization.jsonObject(with: fallbackData) as? [String: Any]) ?? [:]
    expectEqual(fallbackJSON["model"] as? String, "gpt-5.6-sol", "nil rawBody 回退编码 ChatRequest 后剥离 effort")
    let fallbackInput = fallbackJSON["input"] as? [[String: Any]] ?? []
    expectEqual((fallbackInput.first?["content"] as? [[String: Any]])?.first?["text"] as? String, "hi", "nil rawBody 回退保留消息内容")

    // 无 effort 后缀模型
    let plainBody: [String: Any] = [
        "model": "gpt-5.5",
        "messages": [["role": "user", "content": "hi"]],
    ]
    let plainRequest = ChatRequest(
        model: "gpt-5.5",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let plainData = try CodexResponsesTranslator.makeRequestBody(
        request: plainRequest,
        rawBody: try JSONSerialization.data(withJSONObject: plainBody)
    )
    let plainJSON = (try JSONSerialization.jsonObject(with: plainData) as? [String: Any]) ?? [:]
    expectEqual(plainJSON["model"] as? String, "gpt-5.5", "无后缀模型保持原样")
    expectNil((plainJSON["reasoning"] as? [String: Any])?["effort"], "无后缀模型不带 effort")

    // 2) 响应翻译：output_text.delta → content chunk
    var state = CodexResponsesTranslator.CodexResponseState(model: "gpt-5.6-sol")
    let deltaBlock = """
    event: response.output_text.delta
    data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello"}

    """
    let deltaJSON = chunkJSON(CodexResponsesTranslator.translatedChunk(Data(deltaBlock.utf8), state: &state))
    let deltaChoices = deltaJSON?["choices"] as? [[String: Any]] ?? []
    let deltaObj = deltaChoices.first?["delta"] as? [String: Any] ?? [:]
    expectEqual(deltaObj["content"] as? String, "Hello", "output_text.delta → delta.content")
    expectEqual(deltaObj["role"] as? String, "assistant", "首个 content delta 带 role")

    // function_call added → tool_calls chunk
    let toolBlock = """
    event: response.output_item.added
    data: {"type":"response.output_item.added","item":{"id":"fc_1","type":"function_call","call_id":"call_2","name":"shell","arguments":""}}

    """
    let toolJSON = chunkJSON(CodexResponsesTranslator.translatedChunk(Data(toolBlock.utf8), state: &state))
    let toolChoices = toolJSON?["choices"] as? [[String: Any]] ?? []
    let toolCalls = (toolChoices.first?["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]] ?? []
    expectEqual(toolCalls.first?["id"] as? String, "call_2", "function_call 首 chunk 带 call_id")
    expectEqual((toolCalls.first?["function"] as? [String: Any])?["name"] as? String, "shell", "function_call 带 name")

    // completed + usage → 最终 chunk
    let completedBlock = """
    event: response.completed
    data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}

    """
    let finalJSON = chunkJSON(CodexResponsesTranslator.translatedChunk(Data(completedBlock.utf8), state: &state))
    let finalChoices = finalJSON?["choices"] as? [[String: Any]] ?? []
    expectEqual(finalChoices.first?["finish_reason"] as? String, "tool_calls", "有 tool_calls 时 finish_reason=tool_calls")
    let usage = finalJSON?["usage"] as? [String: Any] ?? [:]
    expectEqual(usage["prompt_tokens"] as? Int, 10, "input_tokens → prompt_tokens")
    expectEqual(usage["completion_tokens"] as? Int, 5, "output_tokens → completion_tokens")
    expectEqual(usage["total_tokens"] as? Int, 15, "total_tokens 透传")
}

/// Codex Provider 集成（URLProtocol mock 当上游 + token 刷新）：翻译 + 401 refresh 重试。
func codexProviderIntegrationTests() async throws {
    unsetenv("CODEX_BASE_URL")
    unsetenv("CODEX_TOKEN_URL")
    unsetenv("CODEX_ACCESS_TOKEN")
    defer {
        unsetenv("CODEX_BASE_URL")
        unsetenv("CODEX_TOKEN_URL")
        unsetenv("CODEX_ACCESS_TOKEN")
        URLProtocol.unregisterClass(URLProtocolMock.self)
        URLProtocolMock.reset()
    }
    setenv("CODEX_BASE_URL", "https://mock.test", 1)
    setenv("CODEX_TOKEN_URL", "https://mock.test/oauth/token", 1)
    await ModelCache.shared.invalidate("codex")

    // 记录每次 responses 请求的 Authorization 与请求体，供断言。
    nonisolated(unsafe) var upstreamAuthorizations: [String] = []
    nonisolated(unsafe) var capturedRequestBody = ""
    nonisolated(unsafe) var capturedAccountID = ""

    URLProtocol.registerClass(URLProtocolMock.self)
    URLProtocolMock.reset()
    URLProtocolMock.requestHandler = { request in
        let url = request.url!
        // token 刷新端点：返回新 access + 旋转 refresh
        if url.path == "/oauth/token" {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"access_token":"refreshed-at","refresh_token":"refreshed-rt","expires_in":3600}"#.utf8))
        }
        // 上游 responses 端点：首次 401 触发刷新，重试后返回 SSE
        if url.path == "/backend-api/codex/responses" {
            upstreamAuthorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if let body = requestBodyString(request) { capturedRequestBody = body }
            capturedAccountID = request.value(forHTTPHeaderField: "chatgpt-account-id") ?? ""
            if upstreamAuthorizations.count == 1 {
                let err = HTTPURLResponse(
                    url: url, statusCode: 401, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (err, Data(#"{"error":{"message":"token expired"}}"#.utf8))
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            let sse = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"Hello"}

            event: response.completed
            data: {"type":"response.completed","response":{"id":"resp_1","status":"completed","usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}}

            """
            return (response, Data(sse.utf8))
        }
        let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (notFound, Data("not found".utf8))
    }

    let request = ChatRequest(
        model: "gpt-5.6-sol",
        messages: [ChatMessage(role: .user, content: "hi")],
        stream: true
    )
    let rawBody = try JSONEncoder().encode(request)
    let credential = ProviderCredential(
        accessToken: "expired-at",
        refreshToken: "rt-1",
        workspaceId: "ws-1"
    )
    let stream = try await CodexProvider().chat(request: request, rawBody: rawBody, credential: credential)
    var collected = Data()
    for try await chunk in stream { collected.append(chunk) }
    let text = String(data: collected, encoding: .utf8) ?? ""

    // 1) 401 刷新重试：首次用旧 token，重试用刷新后的 token
    expectEqual(upstreamAuthorizations.count, 2, "401 后重试一次")
    expectEqual(upstreamAuthorizations.first, "Bearer expired-at", "首次请求用旧 access token")
    expectEqual(upstreamAuthorizations.last, "Bearer refreshed-at", "重试用刷新后的 access token")
    expectEqual(capturedAccountID, "ws-1", "chatgpt-account-id 头带 workspaceId")
    expectTrue(capturedRequestBody.contains("\"stream\":true"), "上游请求体 stream=true")
    expectTrue(capturedRequestBody.contains("\"model\":\"gpt-5.6-sol\""), "上游请求体 model")

    // 2) 翻译输出：内容 + 最终 chunk usage + [DONE]
    expectTrue(text.contains(#""content":"Hello""#), "翻译后的 SSE 包含内容，实际: \(text)")
    expectTrue(text.contains(#""prompt_tokens":7"#), "最终 chunk 含 usage.prompt_tokens")
    expectTrue(text.contains(#""completion_tokens":3"#), "最终 chunk 含 usage.completion_tokens")
    expectTrue(text.contains("[DONE]"), "流结束含 [DONE]")

    // 3) 无凭据抛 missingCredentials
    await expectThrows({
        _ = try await CodexProvider().chat(
            request: request, rawBody: rawBody, credential: nil
        )
    }, "Codex 无凭据 chat 抛 missingCredentials")

    // 4) testModel（默认实现 rawBody=nil）：回退编码 ChatRequest，正常拿首个 chunk
    upstreamAuthorizations = []
    let testResult = try await CodexProvider().testModel("gpt-5.6-sol", credential: credential)
    expectTrue(testResult.success, "testModel 应成功（nil rawBody 回退编码），实际: \(testResult.message)")
}

/// Codex 用量查询（URLProtocol mock）：5h/7d 双窗口 + code_review + 401 刷新重试 + 时长标注。
func codexUsageFetcherTests() async throws {
    // 1) 标准双窗口解析（used_percent 为 0-100 量纲）+ code_review 窗口 + latent 窗口跳过
    try await withGlobalURLProtocolMock {
        setenv("CODEX_BASE_URL", "https://mock.test", 1)
        defer { unsetenv("CODEX_BASE_URL") }
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {"plan_type":"chatgptteam","rate_limit":{"primary_window":{"used_percent":40,"reset_at":2000000000},"secondary_window":{"used_percent":80,"reset_after_seconds":3600},"limit_reached":false},"code_review_rate_limit":{"primary_window":{"used_percent":25,"reset_after_seconds":45},"secondary_window":{"used_percent":55,"reset_after_seconds":6000}},"additional_rate_limits":[{"limit_name":"Spark","metered_feature":"spark","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000}}}]}
            """
            return (response, Data(body.utf8))
        }
        let snapshot = try await CodexUsageFetcher().fetchUsage(
            credential: ProviderCredential(accessToken: "at", workspaceId: "ws-1")
        )
        expectNil(snapshot.error, "Codex 成功快照无 error")
        expectEqual(snapshot.quotaWindows.count, 4, "5h + Weekly + Code Review + Code Review Weekly 四个窗口")
        if let fiveHour = snapshot.quotaWindows.first(where: { $0.label == "5h" }) {
            expectEqual(fiveHour.remainingFraction, 0.6, "5h 窗口 remainingFraction = 1 - 40/100")
            expectEqual(fiveHour.used, 40, "5h 窗口 used=40")
            expectEqual(fiveHour.total, 100, "5h 窗口 total=100")
            expectEqual(fiveHour.remainingPercentage, 60, "5h 窗口 remainingPercentage")
            expectEqual(fiveHour.resetAt, Date(timeIntervalSince1970: 2000000000), "5h 窗口 reset_at 解析")
        } else {
            expectTrue(false, "缺失 5h 窗口")
        }
        if let weekly = snapshot.quotaWindows.first(where: { $0.label == "Weekly" }) {
            expectEqual(weekly.remainingFraction, 0.2, "Weekly 窗口 remainingFraction = 1 - 80/100")
            expectTrue(weekly.resetAt != nil, "Weekly 窗口 reset_after_seconds 解析")
        } else {
            expectTrue(false, "缺失 Weekly 窗口")
        }
        if let review = snapshot.quotaWindows.first(where: { $0.label == "Code Review" }) {
            expectEqual(review.remainingFraction, 0.75, "Code Review 窗口 remainingFraction = 1 - 25/100")
        } else {
            expectTrue(false, "缺失 Code Review 窗口")
        }
        if let reviewWeekly = snapshot.quotaWindows.first(where: { $0.label == "Code Review Weekly" }) {
            expectEqual(reviewWeekly.remainingFraction, 0.45, "Code Review Weekly 窗口 remainingFraction = 1 - 55/100")
        } else {
            expectTrue(false, "缺失 Code Review Weekly 窗口")
        }
        // latent（从未使用的 spark 隐性上限）窗口不渲染
        expectFalse(snapshot.quotaWindows.contains { $0.label.contains("Spark") }, "latent spark 窗口跳过")
    }

    // 2) 401 刷新重试
    try await withGlobalURLProtocolMock {
        setenv("CODEX_BASE_URL", "https://mock.test", 1)
        setenv("CODEX_TOKEN_URL", "https://mock.test/oauth/token", 1)
        defer {
            unsetenv("CODEX_BASE_URL")
            unsetenv("CODEX_TOKEN_URL")
        }
        nonisolated(unsafe) var usageCalls = 0
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let url = request.url!
            if url.path == "/oauth/token" {
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"access_token":"refreshed-at","refresh_token":"new-rt","expires_in":3600}"#.utf8))
            }
            if url.path == "/backend-api/wham/usage" {
                usageCalls += 1
                if usageCalls == 1 {
                    let err = HTTPURLResponse(
                        url: url, statusCode: 401, httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!
                    return (err, Data("expired".utf8))
                }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let body = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":2000000000},"secondary_window":{"used_percent":20,"reset_at":2000000000}}}"#
                return (response, Data(body.utf8))
            }
            let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (notFound, Data("not found".utf8))
        }
        let snapshot = try await CodexUsageFetcher().fetchUsage(
            credential: ProviderCredential(accessToken: "expired-at", refreshToken: "rt-1", workspaceId: "ws-1")
        )
        expectEqual(usageCalls, 2, "401 后用量请求重试一次")
        expectEqual(snapshot.quotaWindows.count, 2, "刷新重试后仍解析两个窗口")
    }

    // 3) 时长标注（参考 OmniRoute `windowDurationLabel`）：30 天月度窗口 → "Monthly"（免费版现状）
    try await withGlobalURLProtocolMock {
        setenv("CODEX_BASE_URL", "https://mock.test", 1)
        defer { unsetenv("CODEX_BASE_URL") }
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            // 免费版 wham/usage 现返回 30 天月度窗口（limit_window_seconds=2592000），
            // 此前被位置标签错标为 "5h"，导致「重置一个月后」的月度总额显示在 5h 行上。
            let body = """
            {"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":2592000,"reset_after_seconds":2592000},"limit_reached":false}}
            """
            return (response, Data(body.utf8))
        }
        let snapshot = try await CodexUsageFetcher().fetchUsage(
            credential: ProviderCredential(accessToken: "at", workspaceId: "ws-1")
        )
        expectEqual(snapshot.quotaWindows.count, 1, "免费版月度窗口 payload 解析一个窗口")
        if let monthly = snapshot.quotaWindows.first(where: { $0.label == "Monthly" }) {
            expectEqual(monthly.remainingFraction, 0.58, "Monthly 窗口 remainingFraction = 1 - 42/100")
            expectEqual(monthly.used, 42, "Monthly 窗口 used=42")
            expectTrue(monthly.resetAt != nil, "Monthly 窗口 reset_after_seconds 解析")
        } else {
            expectTrue(false, "30 天窗口应标注为 Monthly，实际: \(snapshot.quotaWindows.map(\.label))")
        }
    }

    // 3b) 7 天 primary 窗口 → "Weekly"（时长优先于位置，OmniRoute 同款场景）
    try await withGlobalURLProtocolMock {
        setenv("CODEX_BASE_URL", "https://mock.test", 1)
        defer { unsetenv("CODEX_BASE_URL") }
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = """
            {"rate_limit":{"primary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_after_seconds":100000},"secondary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_after_seconds":3600},"limit_reached":false}}
            """
            return (response, Data(body.utf8))
        }
        let snapshot = try await CodexUsageFetcher().fetchUsage(
            credential: ProviderCredential(accessToken: "at", workspaceId: "ws-1")
        )
        if let weekly = snapshot.quotaWindows.first(where: { $0.label == "Weekly" }) {
            expectEqual(weekly.remainingFraction, 0.7, "7 天 primary 窗口标注 Weekly，remainingFraction = 1 - 30/100")
        } else {
            expectTrue(false, "7 天 primary 窗口应标注 Weekly，实际: \(snapshot.quotaWindows.map(\.label))")
        }
        if let fiveHour = snapshot.quotaWindows.first(where: { $0.label == "5h" }) {
            expectEqual(fiveHour.remainingFraction, 0.9, "5h 窗口标注 5h，remainingFraction = 1 - 10/100")
        } else {
            expectTrue(false, "5h 窗口缺失，实际: \(snapshot.quotaWindows.map(\.label))")
        }
    }

    // 4) 无 token 抛 missingCredentials
    await expectThrows({
        _ = try await CodexUsageFetcher().fetchUsage(credential: ProviderCredential())
    }, "Codex 无 token 抛 missingCredentials")
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

/// Cursor 官方模型目录静态断言（防回归：auto 存在、无重复、数量与 OmniRoute 同步）。
func cursorModelsCatalogTests() async throws {
    let models = CursorModels.all
    let ids = models.map(\.id)
    // 1. 关键模型存在（用户报告缺失的）
    for required in ["auto", "composer-2.5", "composer-2", "gpt-5.5-extra-high", "gpt-5.2-xhigh", "claude-opus-4-8-thinking-max", "claude-sonnet-5-thinking-max", "grok-4.5-xhigh", "kimi-k2.5"] {
        expectTrue(ids.contains(required), "Cursor 目录应含 \(required)")
    }
    // 2. auto 排最前
    expectEqual(ids.first, "auto", "auto 应排在最前")
    // 3. 无重复 id
    expectEqual(Set(ids).count, ids.count, "Cursor 目录无重复模型 id")
    // 4. 数量与 OmniRoute 官方目录一致（2026-05 快照 123 个）
    expectEqual(ids.count, 123, "Cursor 目录共 123 个模型（对齐 OmniRoute）")
    // 5. 每个模型都有非空展示名
    for m in models {
        expectTrue(!(m.name ?? "").isEmpty, "模型 \(m.id) 应有展示名")
    }
}

func cursorUsageFetcherTests() async throws {
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEyMyJ9.sig"
    setenv("CURSOR_USAGE_URL", "https://mock.test/api/dashboard/get-current-period-usage", 1)
    setenv("CURSOR_TOKEN", token, 1)
    defer {
        unsetenv("CURSOR_USAGE_URL")
        unsetenv("CURSOR_TOKEN")
    }

    try await withGlobalURLProtocolMock {
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(
                request.url?.absoluteString,
                "https://mock.test/api/dashboard/get-current-period-usage",
                "Cursor 用量请求 URL")
            expectEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                "WorkosCursorSessionToken=user-123::\(token)",
                "Cursor 用量 WorkOS Cookie")
            expectEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com", "Cursor 用量 Origin")
            expectEqual(request.value(forHTTPHeaderField: "Referer"), "https://cursor.com/dashboard/spending", "Cursor 用量 Referer")
            expectEqual(requestBodyString(request), "{}", "Cursor 用量 POST body")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = #"{"planUsage":{"totalPercentUsed":46.5,"autoPercentUsed":93,"apiPercentUsed":0,"totalSpend":93},"billingCycleEnd":1893456000000}"#
            return (response, Data(body.utf8))
        }

        let snapshot = try await CursorUsageFetcher().fetchUsage(credential: ProviderCredential())
        expectEqual(snapshot.providerID, "cursor", "Cursor 用量快照 providerID")
        expectEqual(snapshot.quotaWindows.count, 3, "Cursor 用量含三个窗口")
        expectEqual(snapshot.quotaWindows[0].label, "总用量", "Cursor 总用量窗口")
        expectEqual(snapshot.quotaWindows[1].label, "Auto + Composer", "Cursor Auto + Composer 窗口")
        expectEqual(snapshot.quotaWindows[2].label, "API", "Cursor API 窗口")
        expectEqual(snapshot.quotaWindows[0].remainingFraction, 0.535, "Cursor 总用量剩余比例")
        expectEqual(snapshot.quotaWindows[1].remainingFraction, 0.07, "Cursor Auto + Composer 剩余比例")
        expectEqual(snapshot.quotaWindows[2].remainingFraction, 1.0, "Cursor API 剩余比例")
        expectEqual(snapshot.quotaWindows[0].resetAt, Date(timeIntervalSince1970: 1_893_456_000), "Cursor 计费周期重置时间")
    }
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

    // 5) 手动导入账号优先：credential.accessToken + machineId → IDE 请求（不走 CursorCredentialStore）
    setenv("CURSOR_BASE_URL", "https://mock.test", 1)
    setenv("CURSOR_STATE_DB_PATH", "/nonexistent/state.vscdb", 1)  // 确保 IDE 自动发现不可用
    await CursorCredentialStore.shared.clearCache()
    defer {
        unsetenv("CURSOR_BASE_URL")
        unsetenv("CURSOR_STATE_DB_PATH")
    }
    let manualCred = ProviderCredential(accessToken: "manual-account-token", machineId: "manual-mid-123")
    try await withGlobalURLProtocolMock {
        URLProtocolMock.reset()
        URLProtocolMock.requestHandler = { request in
            expectEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer manual-account-token",
                "手动账号 Bearer 用 credential.accessToken")
            expectEqual(request.value(forHTTPHeaderField: "x-cursor-checksum"),
                       CursorChecksum.generate(machineId: "manual-mid-123"),
                       "手动账号 machineId 生成 checksum")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/connect+proto"]
            )!
            return (response, cursorTextFrame("manual ok") + cursorEndFrame())
        }
        let stream = try await provider.chat(
            request: ChatRequest(model: "gpt-5.2", messages: [ChatMessage(role: .user, content: "hi")], stream: true),
            rawBody: nil,
            credential: manualCred)
        var text = ""
        for try await chunk in stream { text += String(data: chunk, encoding: .utf8) ?? "" }
        expectTrue(text.contains("manual ok"), "手动账号模式 SSE 透传，实际: \(text)")
    }

    // 6) listModels：IDE 模式（无 API key）返回官方静态目录，含 auto / composer-*
    unsetenv("CURSOR_API_KEY")
    let models = try await provider.listModels(credential: nil)
    let ids = models.map(\.id)
    expectTrue(ids.contains("auto"), "listModels 含 auto")
    expectTrue(ids.contains("composer-2.5"), "listModels 含 composer-2.5")
    expectTrue(ids.contains("claude-opus-4-8-thinking-max"), "listModels 含 effort 变体")
    expectEqual(models.count, CursorModels.all.count, "listModels 返回完整官方目录")
    expectEqual(ids.first, "auto", "auto 排在最前")
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
await run("codex OAuth 客户端（URLProtocol mock）", codexOAuthClientTests)
await run("codex 翻译器（纯单测）", codexTranslatorTests)
await run("codex Provider 集成（URLProtocol mock + 401 刷新）", codexProviderIntegrationTests)
await run("codex 用量查询（URLProtocol mock）", codexUsageFetcherTests)
await run("cursor 集成（URLProtocol mock）", cursorIntegrationTests)
await run("Cursor IDE 凭据发现", cursorCredentialStoreTests)
await run("Cursor 官方模型目录", cursorModelsCatalogTests)
await run("Cursor 用量查询（URLProtocol mock）", cursorUsageFetcherTests)
await run("cursor IDE 模式（URLProtocol mock）", cursorIDEModeTests)
await run("Kimi 用量查询（URLProtocol mock）", kimiUsageFetcherTests)
await run("OpenCode Go 用量查询（URLProtocol mock）", openCodeGoUsageFetcherTests)
await run("CodeBuddy CN 用量查询（URLProtocol mock）", codeBuddyCnUsageFetcherTests)
await run("CodeBuddy OAuth 登录账号标识", codeBuddyIdentityTests)
await run("GenericOpenAIProvider 集成（URLProtocol mock）", genericOpenAIProviderTests)
await run("ProviderRegistry unregister", registryUnregisterTests)
await run("Router 自定义 provider 前缀解析", routerCustomProviderTests)
await run("CustomProviderDef 配置编解码", customProviderConfigCodecTests)
await run("ChatMessage 宽容解码（developer/content 数组）", chatMessageTolerantDecodeTests)
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
