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

case "config":
    switch args.count > 1 ? args[1] : "path" {
    case "path":
        print(ConfigStore.defaultPath())
    default:
        print("usage: BinviaCLI config path")
        exit(1)
    }

case "serve":
    // 注：serve 固定使用默认配置路径（ConfigStore.load() 内部处理 BINVIA_CONFIG 覆盖）
    _ = value(for: "--config") // --config 参数预留；当前与 BinviaServer 行为保持一致
    let config = try ConfigStore.load()
    let port = value(for: "--port").flatMap(Int.init) ?? config.port
    ProviderCatalog.registerAll()
    let handler = RouteHandler(config: config)
    let server = HTTPServer { request in
        try await handler.handle(request)
    }
    try server.start(host: config.host, port: port)
    // 全局忽略 SIGPIPE：流式响应客户端提前断开不杀进程（与 HTTPServer SO_NOSIGPIPE 双保险）
    signal(SIGPIPE, SIG_IGN)
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
