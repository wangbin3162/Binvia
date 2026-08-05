import Foundation
import BinviaCore

// Binvia 本地代理服务器入口。
// 用法：BinviaServer [--port 20427] [--config /path/to/config.json]

let args = Array(CommandLine.arguments.dropFirst())

func value(for flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag) else { return nil }
    let valueIdx = args.index(after: idx)
    guard valueIdx < args.count else { return nil }
    return args[valueIdx]
}

if args.contains("--help") || args.contains("-h") {
    print("""
    Binvia Server
    Usage: BinviaServer [--port 20427] [--config /path/to/config.json]
    Endpoints:
      GET  /v1/health
      GET  /v1/models
      POST /v1/chat/completions
      GET  /v1/usage
      GET  /                  Web 管理面板
      GET  /admin/api/*       Web 管理 API
    """)
    exit(0)
}

let configPath = value(for: "--config")
let config = try ConfigStore.load(path: configPath)

// 全局忽略 SIGPIPE：流式响应时客户端提前断开会触发 SIGPIPE，默认动作是终止进程。
// 配合 HTTPServer 对 client fd 设置 SO_NOSIGPIPE（per-socket 双保险）。
signal(SIGPIPE, SIG_IGN)

let port: Int
if let portStr = value(for: "--port"), let p = Int(portStr) {
    port = p
} else {
    port = config.port
}

ProviderCatalog.registerAll()
ProviderCatalog.registerCustomProviders(from: config)

let state = ServerState(config: config)
var handler = RouteHandler(config: config, state: state)
let server = HTTPServer { request in
    try await handler.handle(request)
}

// 热更新：配置变更后替换 RouteHandler（复用 HTTPServer.setHandler）
state.onConfigChanged = { newConfig in
    let newHandler = RouteHandler(config: newConfig, state: state)
    server.setHandler { request in
        try await newHandler.handle(request)
    }
}

try server.start(host: config.host, port: port)

if config.webPanelEnabled {
    print("[Binvia] Web 管理面板: http://\(config.host):\(port)/")
}

// 常驻运行，等待信号退出
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    print("\n[Binvia] shutting down")
    exit(0)
}
sigintSrc.resume()
let sigtermSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSrc.setEventHandler {
    print("\n[Binvia] shutting down")
    exit(0)
}
sigtermSrc.resume()

RunLoop.main.run()