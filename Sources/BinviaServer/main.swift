import Foundation
import BinviaCore

// Binvia 本地代理服务器入口。
// 用法：BinviaServer [--port 8231] [--config /path/to/config.json]

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
    Usage: BinviaServer [--port 8231] [--config /path/to/config.json]
    Endpoints:
      GET  /v1/health
      GET  /v1/models
      POST /v1/chat/completions
      GET  /v1/usage
    """)
    exit(0)
}

let configPath = value(for: "--config")
let config = try ConfigStore.load(path: configPath)

let port: Int
if let portStr = value(for: "--port"), let p = Int(portStr) {
    port = p
} else {
    port = config.port
}

ProviderCatalog.registerAll()

let handler = RouteHandler(config: config)
let server = HTTPServer { request in
    try await handler.handle(request)
}

try server.start(host: config.host, port: port)

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
