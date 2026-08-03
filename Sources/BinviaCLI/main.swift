import Foundation
import BinviaCore
#if canImport(AppKit)
import AppKit
#endif

// Binvia CLI。
// 用法：
//   BinviaCLI providers list
//   BinviaCLI test <provider>
//   BinviaCLI oauth login <codebuddy-cn|antigravity>
//   BinviaCLI cursor status
//   BinviaCLI config path
//   BinviaCLI serve [--port N] [--config PATH]

let args = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    Binvia CLI
    Usage:
      BinviaCLI providers list
      BinviaCLI test <provider|alias>
      BinviaCLI oauth login <codebuddy-cn|antigravity>
      BinviaCLI cursor status
      BinviaCLI config path
      BinviaCLI serve [--port N] [--config PATH]
    """)
}

func value(for flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag) else { return nil }
    let valueIdx = args.index(after: idx)
    guard valueIdx < args.count else { return nil }
    return args[valueIdx]
}

func openInBrowser(_ url: URL) {
    #if canImport(AppKit)
    NSWorkspace.shared.open(url)
    #else
    print("请手动在浏览器打开：\(url.absoluteString)")
    #endif
}

/// 从用户粘贴的重定向 URL 或 authorization code 中提取 code。
func extractAuthorizationCode(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed),
       let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
       let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
       !code.isEmpty {
        return code
    }
    return trimmed
}

/// 把登录得到的凭据写回 config。
func saveCredential(_ credential: ProviderCredential, for providerID: String, configPath: String?) throws {
    var config = try ConfigStore.load()
    var providerConfig = config.providers[providerID] ?? ProviderConfig()
    providerConfig.enabled = true
    providerConfig.credential = credential
    config.providers[providerID] = providerConfig
    try ConfigStore.save(config, to: nil)
    print("已保存凭据到 \(configPath ?? ConfigStore.defaultPath())")
}

guard let command = args.first else {
    usage()
    exit(0)
}

switch command {
case "providers":
    guard args.count >= 2, args[1] == "list" else {
        print("usage: BinviaCLI providers list")
        exit(1)
    }
    ProviderCatalog.registerAll()
    let registry = ProviderRegistry.shared
    for descriptor in registry.allDescriptors() {
        let auth = descriptor.metadata.authType.rawValue
        let alias = descriptor.alias.map { " (alias: \($0))" } ?? ""
        print("- \(descriptor.id)\(alias) [\(auth)] — \(descriptor.displayName)")
        for model in descriptor.models {
            print("    - \(model.id)")
        }
    }

case "test":
    guard args.count >= 2 else {
        print("usage: BinviaCLI test <provider|alias>")
        exit(1)
    }
    ProviderCatalog.registerAll()
    let registry = ProviderRegistry.shared
    guard let providerID = registry.canonicalProviderID(args[1]),
          let provider = registry.provider(for: providerID) else {
        print("Unknown provider: \(args[1])")
        exit(1)
    }
    let config = try ConfigStore.load()
    let credential = config.credential(for: providerID)
    print("Testing \(providerID) ...")
    let result = try await provider.testConnection(credential: credential)
    if result.success {
        print("OK — \(result.message) (\(String(format: "%.1f", result.latencyMS ?? 0))ms)")
    } else {
        print("FAILED — \(result.message)")
        exit(1)
    }

case "oauth":
    guard args.count >= 3, args[1] == "login" else {
        print("usage: BinviaCLI oauth login <codebuddy-cn|antigravity>")
        exit(1)
    }
    let providerName = args[2]
    switch providerName {
    case "codebuddy-cn", "cbcn":
        let client = CodeBuddyOAuthClient()
        let credential = try await client.login { url in
            print("请在浏览器中打开授权地址…")
            openInBrowser(url)
        }
        try saveCredential(credential, for: "codebuddy-cn", configPath: value(for: "--config"))
        print("CodeBuddy CN 登录成功。可用 `BinviaCLI test codebuddy-cn` 验证。")
    case "antigravity", "agy":
        let client = AntigravityOAuthClient(config: .live())
        let credentials = try await client.login(
            openURL: { url in
                print("请在浏览器中打开授权地址…")
                openInBrowser(url)
            },
            codeProvider: { _ in
                print("请在浏览器完成授权后，把重定向地址（或 authorization code）粘贴到这里：")
                guard let line = readLine(), let code = extractAuthorizationCode(from: line) else {
                    throw ProviderError.missingCredentials("未提供 authorization code")
                }
                return code
            }
        )
        let credential = ProviderCredential(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken
        )
        try saveCredential(credential, for: "antigravity", configPath: value(for: "--config"))
        if let projectId = credentials.projectId {
            print("Antigravity 登录成功（projectId: \(projectId)）。可用 `BinviaCLI test antigravity` 验证。")
        } else {
            print("Antigravity 登录成功（未获取到 projectId，运行时将自动发现）。")
        }
    default:
        print("未知供应商：\(providerName)（支持 codebuddy-cn / antigravity）")
        exit(1)
    }

case "cursor":
    guard args.count >= 2 else {
        print("usage: BinviaCLI cursor <status|add|list|remove>")
        exit(1)
    }
    switch args[1] {
    case "status":
        let detection = await CursorCredentialStore.shared.refresh()
        switch detection {
        case .found(let identity):
            print("✅ 已检测到 Cursor IDE 登录")
            print("accessToken: \(identity.accessToken.prefix(16))•••（长度 \(identity.accessToken.count)）")
            if let expiresAt = identity.expiresAt {
                print("过期时间: \(expiresAt.formatted())（IDE 会自动轮换）")
            } else {
                print("过期时间: 未知（JWT 不含 exp 或格式异常）")
            }
            if let machineId = identity.machineId {
                print("machineId: \(machineId)")
            }
        case .noInstallation:
            print("❌ 未检测到 Cursor IDE（未找到 state.vscdb）")
            print("查找路径:")
            for path in await CursorCredentialStore().candidatePaths() {
                print("  \(path)")
            }
        case .notSignedIn:
            print("❌ Cursor 已安装但未登录（state.vscdb 中无 cursorAuth/accessToken）")
            print("请先打开 Cursor IDE 并登录账号。")
        case .unreadable(let message):
            print("❌ 无法读取 Cursor 数据库: \(message)")
        }
    case "add":
        // 手动导入账号：BinviaCLI cursor add <accessToken> [machineId]
        guard args.count >= 3 else {
            print("usage: BinviaCLI cursor add <accessToken> [machineId]")
            exit(1)
        }
        let token = args[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            print("❌ accessToken 不能为空")
            exit(1)
        }
        let machineId = args.count >= 4
            ? args[3].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        var config = try ConfigStore.load()
        var providerConfig = config.providers["cursor"] ?? ProviderConfig()
        providerConfig.enabled = true
        var credential = providerConfig.credential
        if credential.accessToken == nil || credential.accessToken!.isEmpty {
            // 首次添加：写入主账号（credential）
            credential.accessToken = token
            credential.machineId = machineId.isEmpty ? credential.machineId : machineId
        } else {
            // 追加为轮换账号（apiKeys[]，machineId 编码进标签前缀 `mid:`）
            var tokens = providerConfig.apiKeys
            let label = machineId.isEmpty ? KeyedToken.defaultLabel(for: token) : "mid:\(machineId)"
            tokens.append(KeyedToken(label: label, value: token))
            providerConfig.apiKeys = tokens
        }
        providerConfig.credential = credential
        config.providers["cursor"] = providerConfig
        try ConfigStore.save(config, to: nil)
        print("✅ 已添加 Cursor 账号（token 长度 \(token.count)）")
    case "list":
        let config = try ConfigStore.load()
        guard let pc = config.providers["cursor"] else {
            print("未配置 Cursor 账号")
            exit(0)
        }
        var index = 1
        if let access = pc.credential.accessToken, !access.isEmpty {
            print("\(index). 主账号: \(access.prefix(16))•••（长度 \(access.count)）")
            if let mid = pc.credential.machineId {
                print("   machineId: \(mid)")
            }
            index += 1
        }
        for token in pc.apiKeys where !token.value.isEmpty {
            var label = token.label
            if label.hasPrefix("mid:") { label = "账号" }
            print("\(index). \(label): \(token.value.prefix(16))•••（长度 \(token.value.count)）")
            index += 1
        }
        if index == 1 {
            print("未配置 Cursor 账号")
        }
    case "remove":
        // 清空全部手动导入账号：BinviaCLI cursor remove
        var config = try ConfigStore.load()
        var providerConfig = config.providers["cursor"] ?? ProviderConfig()
        providerConfig.credential.accessToken = nil
        providerConfig.credential.machineId = nil
        providerConfig.apiKeys = []
        config.providers["cursor"] = providerConfig
        try ConfigStore.save(config, to: nil)
        print("✅ 已移除全部 Cursor 手动账号（IDE 自动发现仍可用）")
    default:
        print("usage: BinviaCLI cursor <status|add|list|remove>")
        exit(1)
    }

case "config":
    switch args.count > 1 ? args[1] : "path" {
    case "path":
        print(ConfigStore.defaultPath())
    default:
        print("usage: BinviaCLI config path")
        exit(1)
    }

case "serve":
    let configPath = value(for: "--config")
    let config = try ConfigStore.load()
    let port = value(for: "--port").flatMap(Int.init) ?? config.port
    ProviderCatalog.registerAll()
    let handler = RouteHandler(config: config)
    let server = HTTPServer { request in
        try await handler.handle(request)
    }
    try server.start(host: config.host, port: port)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    src.setEventHandler { exit(0) }
    src.resume()
    dispatchMain()

case "help", "--help", "-h":
    usage()

default:
    usage()
    exit(1)
}
