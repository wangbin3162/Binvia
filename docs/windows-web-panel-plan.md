# Binvia Windows 支持 + 内置 Web 管理面板计划

> 制定日期：2026-08-03
> 决策：**方案 B**——Windows 端以无头方式运行 `BinviaServer`/`BinviaCLI`，由服务器自带 Web 管理面板承担监控/配置/测试，取代 macOS 菜单栏 GUI。
> 覆盖范围：Windows 平台编译打通、Web 管理面板（后端 + 前端）、无头运行形态、打包分发。

## 1. 背景与目标

当前 Binvia 是纯 Swift + 原生 POSIX socket 的 macOS 工程（`swift-tools-version 6.2`，5 个 target）。为扩展到 Windows 平台，采用**无头服务器 + 内置 Web 面板**的形态：

- Windows 不移植 SwiftUI/AppKit 菜单栏 GUI（成本高、收益低），GUI 保留在 macOS 条件编译。
- Windows 用户通过浏览器访问 `http://localhost:<port>/` 完成监控、凭据配置、连通性测试、网关 Key 管理。
- 核心路由功能（`/v1/chat/completions` 等 OpenAI 兼容 API）在 Windows 上与 macOS 完全一致。

目标产物：

1. `BinviaCore` / `BinviaServer` / `BinviaCLI` / `BinviaCheck` 在 Windows Swift 工具链上编译通过、测试通过。
2. 服务器自带 Web 管理面板（零外部依赖，单 HTML 文件内嵌），覆盖现有 macOS GUI 的监控与配置能力。
3. `BinviaCLI serve` 在 Windows 一键启动服务器并打开默认浏览器。
4. 提供 Windows 打包与分发方案（zip / NSIS），README 增加 Windows 章节。

## 2. 现状分析与迁移路线

### 2.1 已具备的跨平台条件（无需改动）

| 组件 | 现状 |
|---|---|
| BinviaCore（47 文件） | 44 个仅 `import Foundation`，与平台无关 |
| HTTPServer socket 层 | 已有 `canImport(Darwin)/canImport(Glibc)` 条件编译，改动面已隔离在 `SocketUtil` |
| BinviaCLI | `NSWorkspace` 已用 `#if canImport(AppKit)` 守卫（`BinviaCLI/main.swift:3-5,39-43`） |
| ConfigStore | 已支持 `XDG_CONFIG_HOME` 与 `BINVIA_CONFIG` 覆盖 |
| 并发原语 | `NSLock` / actor / `Task.detached` / `DispatchSource` 均跨平台 |

### 2.2 Windows 编译阻塞点（必须修改）

| # | 位置 | 问题 | 方案 |
|---|---|---|---|
| 1 | `Package.swift` | 仅声明 `.macOS(.v14)` | 增加 `.windows(.v10)`；Windows 上排除 `BinviaApp` target |
| 2 | `Providers/Cursor/CursorRPC.swift:2`、`Providers/Antigravity/AntigravityOAuthClient.swift:1` | `import CryptoKit`（SHA256）Apple 专属 | 自实现 SHA256，新增 `Networking/SHA256.swift` |
| 3 | `Providers/Antigravity/AntigravityEnvelopeTranslator.swift:341`、`AntigravityOAuthClient.swift:338` | `arc4random_buf` Darwin 专属 | 改用 `SystemRandomNumberGenerator` |
| 4 | `Server/HTTPServer.swift` | 无 Winsock2 分支（`SOCKET` 类型、`WSAStartup`、`closesocket`、`WSAPoll`、`SO_RCVTIMEO` 语义） | 增加 `canImport(WinSDK)` 分支，fd 类型抽象为 `SocketFD` |
| 5 | `Providers/Cursor/CursorCredentialStore.swift:155` | 硬编码 `~/Library/Application Support/...` | `#if os(Windows)` 走 `%APPDATA%\Cursor\...`；`CURSOR_STATE_DB_PATH` 兜底 |
| 6 | `Config/ConfigStore.swift:10` | 回退 `NSHomeDirectory()`，Windows 无 `HOME` | `USERPROFILE` 优先；0600 权限写入条件编译 |

### 2.3 需实测验证（非必然阻塞）

- `URLSession` 的 async `data(for:)` / `bytes(for:)` 在 Windows Swift 工具链上的可用性（历史上有 `FoundationNetworking` 缺失问题）。若不可用，需在 `ProviderHTTPClient` 增加一层同步/回调适配。
- zlib / SQLite3 的 Windows 模块映射（仅 Cursor provider 使用；可用 `CURSOR_STATE_DB_PATH` 环境变量绕过）。

### 2.4 迁移路线总览

```
Phase 1  Core 跨平台化（Windows 编译打通）
   ↓
Phase 2  管理面板后端（admin API + 配置热更新 + 认证）
   ↓
Phase 3  Web 前端页面（单 HTML 文件）
   ↓
Phase 4  Windows 无头运行形态（serve 命令、自动开浏览器、信号处理）
   ↓
Phase 5  打包分发与文档
```

## 3. 总体架构

### 3.1 模块关系

```
BinviaCore (library, 无 UI)
  ├── Provider / Router / Config / Monitoring    现有逻辑，不动
  ├── Server/HTTPServer.swift                    增加 WinSDK 分支（Phase 1）
  ├── Server/WebPanel.swift                      新增：内嵌 HTML + admin API 编排（Phase 2）
  └── Server/ServerState.swift                   新增：可变配置盒 + 热更新回调（Phase 2）
        ↑
BinviaServer (Windows 无头入口)                  复用现有 main.swift + ServerState
BinviaCLI   (serve 子命令)                       新增：启动 + 自动开浏览器（Phase 4）
BinviaApp   (macOS GUI，Windows 不构建)          保持现状，Package.swift 条件排除
BinviaCheck (自包含测试)                         新增 Web 面板测试（Phase 2）
```

### 3.2 管理面板数据流

```
浏览器 (HTML+JS) ──fetch──> HTTPServer ──> RouteHandler
                                            ├── GET /              → 内嵌 HTML
                                            ├── GET|POST /admin/*   → WebPanel admin API
                                            └── /v1/*               → 现有路由（不变）
admin API ──> ServerState(配置盒) ──> ConfigStore.save ──> onConfigChanged ──> HTTPServer.setHandler(热更新)
admin API ──> ProviderRegistry / UsageCache / RequestLogger（监控与测试）
```

### 3.3 管理面板认证模型

- **默认安全模型**：管理面板与网关 API 共用同一个监听 socket，默认绑定 `127.0.0.1`（`config.host == "localhost"` 即映射到 loopback），外部不可达。
- **可选加固**：配置 `admin_password` 后，管理面板要求登录（`POST /admin/api/login` 换 token），后续请求带 `Authorization: Bearer <token>`。token 为内存随机串，保存在 `ServerState`。
- **网关 API（`/v1/*`）认证不变**：沿用 gateway key 白名单机制，与管理面板独立。

## 4. 分阶段实施计划

---

### Phase 1：Core 跨平台化（Windows 编译打通）

**目标**：`BinviaCore` / `BinviaServer` / `BinviaCLI` / `BinviaCheck` 在 Windows 上编译通过，现有测试全部通过。

**改动文件清单**：

| 文件 | 改动 |
|---|---|
| `Package.swift` | `platforms` 增加 `.windows(.v10)`；用 `#if os(Windows)` 条件排除 `BinviaApp` target |
| `Sources/BinviaCore/Networking/SHA256.swift` | **新增**：自实现 SHA256（`static func hash(_ data: Data) -> Data`，约 60 行） |
| `Sources/BinviaCore/Providers/Cursor/CursorRPC.swift` | `import CryptoKit` → `SHA256` 自实现 |
| `Sources/BinviaCore/Providers/Antigravity/AntigravityOAuthClient.swift` | 同上；`arc4random_buf` → `SystemRandomNumberGenerator` |
| `Sources/BinviaCore/Providers/Antigravity/AntigravityEnvelopeTranslator.swift` | `OAuthRandom` 的 `arc4random_buf` → `SystemRandomNumberGenerator` |
| `Sources/BinviaCore/Server/HTTPServer.swift` | 增加 `canImport(WinSDK)` 分支，`SocketUtil` 适配 Winsock2 |
| `Sources/BinviaCore/Providers/Cursor/CursorCredentialStore.swift` | Windows 路径分支 |
| `Sources/BinviaCore/Config/ConfigStore.swift` | Windows 配置目录 + 权限条件编译 |

**实现细节**：

1. **Package.swift**（`#if os(Windows)` 排除 GUI target）：

```swift
let targets: [Target] = [
    .library(name: "BinviaCore", ...),
    .executableTarget(name: "BinviaServer", ...),
    .executableTarget(name: "BinviaCLI", ...),
    .executableTarget(name: "BinviaCheck", ...),
    #if !os(Windows)
    .executableTarget(name: "BinviaApp", ...),  // macOS GUI
    #endif
]
```

2. **SHA256**：参考 FIPS 180-4，纯 Swift 实现（常量 K、消息调度 W、8 个状态变量、padding 0x80 + 64-bit 位长）。仅暴露 `SHA256.hash(_ data: Data) -> Data`，`Sendable`。放入 `Networking/` 与 `SSEParser` 并列，符合「新增功能优先 Foundation 自实现」约束。

3. **随机数**：统一替换为：

```swift
var generator = SystemRandomNumberGenerator()
let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
```

删除 `OAuthRandom` 枚举，调用点改用自封装 `RandomBytes.secure(count:)`（放 `Networking/`，供 OAuth client 复用）。

4. **HTTPServer Winsock2 适配**（改动集中在 `SocketUtil`）：

```swift
#if os(Windows)
import WinSDK
typealias SocketFD = UInt_PTR            // SOCKET，与 Int32 区分
#else
typealias SocketFD = Int32
#endif
```

要点：
- 进程启动时（`HTTPServer.start` 或全局 `@main` 前）调用一次 `WSAStartup(0x0202, &data)`；`WSACleanup` 于退出时。
- `socket/bind/listen/accept/setsockopt/recv/send` 签名返回类型适配 `SocketFD`；`close(fd)` → `closesocket(fd)`。
- `poll` → `WSAPoll`（`POLLIN` 常量相同，`pollfd` 结构兼容）。
- `errno` → `WSAGetLastError()`；`EAGAIN/EWOULDBLOCK` → `WSAEWOULDBLOCK`。
- `SO_RCVTIMEO` 在 Windows 是 **DWORD 毫秒**（非 `timeval`），需条件编译分开设置。
- `socklen_t` Windows 为 `Int32`（POSIX 为 `UInt32`），用 `Int32(MemoryLayout<sockaddr_in>.size)` 处注意类型转换。
- `SocketError` 增加错误码上下文，便于 Windows 排障。
- `HTTPServer.stop()` 里的 `close(fd)` 同步替换为统一封装 `SocketUtil.close(fd)`。

5. **Cursor 路径**（`CursorCredentialStore.swift`）：

```swift
#if os(Windows)
let stateDB = "%APPDATA%\\Cursor\\User\\globalStorage\\state.vscdb"
let stateDBInsiders = "%APPDATA%\\Cursor - Insiders\\User\\globalStorage\\state.vscdb"
#else
let home = FileManager.default.homeDirectoryForCurrentUser.path
let stateDB = "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
// ... 现有两条
#endif
```

Windows 路径通过 `ProcessInfo.environment["APPDATA"]` 拼接；`CURSOR_STATE_DB_PATH` 环境变量优先级不变（最优先）。

6. **ConfigStore Windows 路径**：

```swift
// defaultDirectory()
if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { return xdg + "/binvia" }
#if os(Windows)
let base = env["APPDATA"] ?? env["USERPROFILE"] ?? NSHomeDirectory()
return (base as NSString).appendingPathComponent("binvia")
#else
let home = env["HOME"] ?? NSHomeDirectory()
return (home as NSString).appendingPathComponent(".config/binvia")
#endif
```

0600 权限：

```swift
#if !os(Windows)
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolved)
#endif
```

7. **URLSession 验证**（先行冒烟）：Windows 上写最小 demo 调用 `URLSession.shared.data(for:)` / `bytes(for:)`。若不可用，在 `ProviderHTTPClient` 增加协议适配层（方案见「风险」节）。

**验收标准**：
- Windows 上 `swift build --target BinviaCore BinviaServer BinviaCLI BinviaCheck` 全部成功。
- Windows 上 `swift run BinviaCheck` 全部通过（现有套件）。
- macOS 构建与测试不受影响（回归）。

---

### Phase 2：管理面板后端（admin API + 热更新）

**目标**：服务器提供 `GET /`（HTML）与 `/admin/*`（JSON API）；配置保存后热更新无需重启；管理面板认证可用。

**改动文件清单**：

| 文件 | 改动 |
|---|---|
| `Sources/BinviaCore/Server/ServerState.swift` | **新增**：NSLock 保护的可变配置盒 + 保存/热更新回调 |
| `Sources/BinviaCore/Server/WebPanel.swift` | **新增**：admin API 编排（复用 Registry/Logger/UsageCache） |
| `Sources/BinviaCore/Server/RouteHandler.swift` | `handle` 增加 `/` 与 `/admin/*` 分支；持有 `ServerState` |
| `Sources/BinviaCore/Config/RouteConfig.swift` | 新增 `webPanelEnabled` / `adminPassword` / `autoOpenBrowser` 字段（snake_case，带默认值回退） |
| `Sources/BinviaServer/main.swift` | 创建 `ServerState`，接热更新回调 |
| `Sources/BinviaApp/AppState.swift` | `RouteHandler(config:state:)` 构造适配（若初始化签名变更） |

**实现细节**：

1. **`ServerState`**（配置盒）：

```swift
public final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var config: RouteConfig
    /// 配置变更后的重建回调（由 HTTPServer 宿主注入，重建 RouteHandler 并 setHandler）
    private var onConfigChanged: (@Sendable (RouteConfig) -> Void)?
    /// 管理面板登录 token（admin_password 启用时非空）
    private var adminToken: String?

    public func get() -> RouteConfig
    public func update(_ mutate: (inout RouteConfig) -> Void)  // 变更 → onConfigChanged?(config)
    public func saveAndReload() throws                       // ConfigStore.save + update
    public func verifyPassword(_ password: String) -> Bool   // 成功则生成/轮换 token
    public func isAuthorized(_ token: String?) -> Bool       // 未设密码 → true；设了 → 比较 token
}
```

- `HTTPServer.setHandler` 已支持运行时热替换，`ServerState.onConfigChanged` 即把新 `RouteHandler` 注入 `HTTPServer.setHandler`，与 `AppState.applyConfigHotReload` 同机制。

2. **路由分发**（`RouteHandler.handle` 增加）：

```swift
switch (request.method, request.path) {
case ("GET", "/"):                     return WebPanel.htmlResponse()          // 管理页面
case ("GET", "/admin/api/overview"):   return await admin.overview()            // 需认证
case ("GET", "/admin/api/entries"):    return await admin.entries(request)      // 需认证
case ("GET", "/admin/api/providers"):  return await admin.providers()           // 需认证
case ("GET", "/admin/api/snapshots"):  return await admin.snapshots()           // 需认证
case ("POST", "/admin/api/login"):     return await admin.login(request)        // 无需认证
case ("POST", "/admin/api/usage/refresh"):      return await admin.refreshUsage(request)   // 需认证
case ("POST", "/admin/api/providers/*/test"):   return await admin.testProvider(request)   // 需认证
case ("GET", "/admin/api/config"):      return await admin.getConfig()          // 需认证
case ("POST", "/admin/api/config"):     return await admin.saveConfig(request)  // 需认证
case ("POST", "/admin/api/keys"):       return await admin.addKey(request)      // 需认证
case ("DELETE", "/admin/api/keys/*"):   return await admin.deleteKey(request)   // 需认证
...
}
```

> 注意：`normalizePath` 会把 `/` 之外的裸路径补 `/v1` 前缀。`GET /` 已在 case 首行精确匹配，不受影响；`/admin/*` 路径以 `/admin` 开头，需在 `normalizePath` 中放行（`hasPrefix("/v1") || hasPrefix("/admin")` 时不加前缀）。**这是必须处理的回归点。**

3. **admin API 端点规格**：

| 端点 | 方法 | 请求 | 响应（JSON） |
|---|---|---|---|
| `/` | GET | — | `text/html`，内嵌管理页面 |
| `/admin/api/login` | POST | `{"password":"..."}` | `{"token":"..."}` / 401 |
| `/admin/api/overview` | GET | — | `{ server: {running, host, port}, summary: UsageSummary, totals: {requests, errors, activeProviders, promptTokens, completionTokens, totalTokens} }` |
| `/admin/api/entries` | GET | `?limit=50` | `{ entries: [RequestLogEntry] }`（倒序） |
| `/admin/api/providers` | GET | — | `{ providers: [ {id, alias, displayName, authType, configured, enabled, region, modelCount} ] }` |
| `/admin/api/snapshots` | GET | — | `{ snapshots: [String: ProviderUsageSnapshot] }` |
| `/admin/api/usage/refresh` | POST | — | 触发全量 `refreshAllUsage` 等价逻辑，返回新快照 |
| `/admin/api/providers/{id}/test` | POST | `{"model": "可选"}` | `{ success, message }` |
| `/admin/api/config` | GET | — | 完整 `RouteConfig`（凭据脱敏：apiKey/accessToken 只回掩码） |
| `/admin/api/config` | POST | 完整或部分 config | 校验 + `ConfigStore.save` + 热更新 |
| `/admin/api/keys` | POST | `{}` 或 `{"key":"sk-bv-...", "enabledModels":[...]}` | 新建/更新网关 key |
| `/admin/api/keys/{key}` | DELETE | — | 删除网关 key |

- **凭据脱敏**：`getConfig` 返回前把 `apiKeys[].value` / `credential.apiKey` / `accessToken` / `refreshToken` 替换为掩码（复用 `KeyedToken.defaultLabel` 的掩码格式）。前端提交完整凭据时原样保存——**脱敏只影响回显，不影响保存**。
- **复用现有能力**：overview 聚合逻辑与 `AppState.totalRequests/totalErrors/totalTokens` 一致，从 `RequestLogger.shared.summary()` 推导；snapshots 用 `UsageCache`；test 用 `Provider.testConnection/testModel`；refresh 复用 Phase 16 的 `UsageCache` 缓存语义（`force: true` 语义放 admin 手动刷新路径）。
- 管理面板的 provider 凭据/启用态修改复用 `RouteConfig` 现有 `providers[providerID]` 结构，写入路径与 `AppState.saveCredential/setTokens/setProviderEnabled` 等价。

4. **认证接入**：每个 `/admin/api/*`（除 login、静态 `/` 由 JS 自行弹登录）先经 `ServerState.isAuthorized` 校验 `Authorization: Bearer` 头。未设密码时全部放行（仅 loopback 监听即安全）。

5. **`BinviaServer/main.swift` 热更新接线**：

```swift
let state = ServerState(config: config)
var handler = RouteHandler(config: config, state: state)
let server = HTTPServer { request in try await handler.handle(request) }
state.onConfigChanged = { newConfig in
    let newHandler = RouteHandler(config: newConfig, state: state)
    server.setHandler { request in try await newHandler.handle(request) }
}
```

（Swift 6 StrictConcurrency 下需处理闭包捕获；`ServerState` 为 `@unchecked Sendable`，回调在 `HTTPServer` 的 handler 调用点同步执行，无跨线程问题。）

6. **BinviaCheck 新增 `WebPanelTests`**（详见第 6 节测试计划）。

**验收标准**：
- macOS 上 `GET /` 返回 200 + `text/html`。
- `/admin/api/overview` 返回完整 JSON；配置 `admin_password` 后未带 token 401、登录后 200。
- `POST /admin/api/config` 改 provider enabled 后 `/v1/models` 立即生效（热更新）。
- BinviaCheck 新增套件全绿；现有套件不回归。

---

### Phase 3：Web 前端页面

**目标**：单 HTML 文件（内嵌 CSS/JS，无构建工具、无外部 CDN 依赖）覆盖 macOS GUI 的主要能力。

**改动文件清单**：

| 文件 | 改动 |
|---|---|
| `Sources/BinviaCore/Server/WebPanel.swift` | **新增**：内嵌 `admin.html` 字符串（或独立 `Resources/admin.html` 读取） |
| `Package.swift` | 若用独立 HTML 文件：`resources` 声明（需确认可移植性，优先**字符串内嵌**避免资源拷贝问题） |

**实现细节**：

1. **页面结构**（对齐 `MenuPanelView` / `OverviewTabView` / `ProviderTabView` 的信息架构）：
   - 顶部状态栏：服务器状态灯、监听地址 `http://<host>:<port>`、版本号。
   - Tab 导航：**概览 / Provider / 请求日志 / 网关 Keys / 设置**。
   - **概览**：Summary 卡片（总请求 / 总错误 / 活跃 Provider / Prompt / Completion / 总 Token）+ Provider 健康度列表（对齐 `ProviderHealthRow`）。
   - **Provider**：每 provider 卡片——认证类型、配置状态、用量快照（余额/配额窗口/模型配额，对齐 `ProviderUsageCard`）、「测试连通性」按钮、凭据编辑（API Key / 多 Key 列表 / Access Token）、启用开关、region 选择（z.ai 等）。
   - **请求日志**：表格（时间 / 方法 / 路径 / provider / 模型 / 状态码 / 耗时 / error / token），倒序，2s 轮询。
   - **网关 Keys**：Key 列表 + 掩码展示 + 「生成新 Key」+ 删除 + enabledModels 白名单编辑（对齐 `SettingsGatewayKeysPane`）。
   - **设置**：host / port / webPanelEnabled / adminPassword / autoOpenBrowser + 保存按钮。

2. **数据刷新节奏**（对齐 `AppState`）：overview + entries **2s** 轮询；snapshots **5min**（`UsageCache.ttl`）轮询 + 手动刷新按钮；Provider 凭据保存、测试、Key 管理为操作触发。

3. **交互约定**：
   - 未配置 `admin_password`：直接加载；配置了：JS 先检查 token（存 `localStorage`），无则显示密码输入框，`POST /admin/api/login` 成功后写入并重载。
   - 所有写操作（保存配置 / 测试 / 刷新用量）成功后 toast 提示；失败显示服务端 message。
   - 页面使用系统字体栈，浅色为主，无外部资源；`<script>` 内使用原生 `fetch` + 模板字符串渲染（不引入任何框架）。

4. **HTML 存放方式**：优先**多行字符串字面量**内嵌在 `WebPanel.swift`（`WebPanel.html` 静态属性），避免 SPM 资源拷贝在 Windows 上的兼容性风险。若 HTML 超过合理维护长度（>1500 行），再评估独立文件 + `resources`。

**验收标准**：
- 浏览器打开 `http://127.0.0.1:20427/` 可完成：查看概览与健康度、查看请求日志、配置 provider 凭据并测试、生成/删除网关 Key、保存设置且热更新生效。
- 无外部 CDN/资源请求（断网可用）。

---

### Phase 4：Windows 无头运行形态

**目标**：Windows 上 `BinviaCLI serve` 一键启动服务器 + 自动打开浏览器；`BinviaServer` 常驻；优雅退出。

**改动文件清单**：

| 文件 | 改动 |
|---|---|
| `Sources/BinviaCLI/main.swift` | 增强 `serve` 子命令：启动 + `autoOpenBrowser` 时打开默认浏览器 + 阻塞等待 |
| `Sources/BinviaServer/main.swift` | 打印管理面板地址；Windows 信号语义适配 |

**实现细节**：

1. **`BinviaCLI serve` 增强**：
   - 现有 serve 逻辑保留；增加启动后打印：

   ```
   [Binvia] listening on http://localhost:20427
   [Binvia] Web panel: http://localhost:20427/
   ```

   - `autoOpenBrowser`（默认 true）时自动打开浏览器：
     - macOS：现有 `NSWorkspace.shared.open`（已守卫）。
     - Windows：`Process` 执行 `cmd /c start http://localhost:<port>/`（或 `rundll32 url.dll,FileProtocolHandler <url>`，更稳）。
   - 阻塞等待逻辑沿用 `RunLoop.main.run()`。

2. **Windows 信号处理**：`SIGINT/SIGTERM` 的 `DispatchSource` 在 Windows 可用但行为不同；`BinviaServer/main.swift` 保持现有代码，Windows 上补充：控制台 Ctrl+C 由 `DispatchSource` 处理或退化为 `while true { sleep }`。实测验证后决定。

3. **常驻形态选择**：v1 提供两种：
   - 前台 exe 常驻（`BinviaServer.exe`），适合手动/任务计划程序启动。
   - 可选 `--daemon`（Windows 用 `START /B` 或后续 NSIS 服务包装），列入 Phase 5 可选。

**验收标准**：
- Windows 上 `binvia serve` 启动服务器并打开浏览器到管理面板。
- Ctrl+C 优雅退出，端口释放。

---

### Phase 5：打包分发与文档

**目标**：Windows 发布产物 + README 说明。

**改动文件清单**：

| 文件 | 改动 |
|---|---|
| `Scripts/build-windows.ps1` | **新增**：`swift build -c release` → 收集 exe → 打包 zip |
| `README.md` | 增加 Windows 章节：安装、运行、防火墙、Web 面板说明 |
| `docs/windows-web-panel-plan.md` | 本计划（实施后回填实际决策差异） |

**实现细节**：

1. **`build-windows.ps1`**：

```powershell
swift build -c release
# 产物：.build\release\BinviaServer.exe、BinviaCLI.exe
# 收集 → bin-windows\binvia.zip（含 README-Windows.md、示例 config.json）
```

2. **Windows 防火墙**：仅监听 `127.0.0.1` 时无需防火墙规则；若用户配置 `host=0.0.0.0` 暴露局域网，README 提供放行命令：

```powershell
New-NetFirewallRule -DisplayName "Binvia" -Direction Inbound -Protocol TCP -LocalPort 20427 -Action Allow
```

3. **README Windows 章节**：安装 Swift 6.2+（Windows）、`swift build -c release` 或下载 zip、`binvia.exe serve`、访问 `http://localhost:20427/`、配置文件位置 `%APPDATA%\binvia\config.json`。

**验收标准**：
- Windows 干净环境按 README 操作可完成安装 → 运行 → 打开管理面板。
- 发布 zip 内 exe 可独立运行（无依赖 Xcode/终端环境变量依赖）。

---

## 5. 配置细节

### 5.1 新增 RouteConfig 字段（全部带默认值回退，兼容旧配置）

```jsonc
{
  "version": 2,
  "host": "localhost",
  "port": 20427,
  "web_panel_enabled": true,        // 是否开启 GET / 管理页面
  "admin_password": null,           // 非 null 时管理面板需登录（JSON 为字符串）
  "auto_open_browser": true,        // serve 启动后自动打开浏览器
  "api_keys": [],
  "providers": {}
}
```

实现位置：`RouteConfig` 增加 `webPanelEnabled: Bool = true`、`adminPassword: String? = nil`、`autoOpenBrowser: Bool = true`。`init(from:)` 用 `decodeIfPresent` 回退默认值，与既有 `region` 字段模式一致（`RouteConfig.swift:198-211`）。

### 5.2 配置路径（Windows）

| 优先级 | 值 |
|---|---|
| 1 | `BINVIA_CONFIG` 环境变量（不变） |
| 2 | `XDG_CONFIG_HOME\binvia\config.json`（不变，兼容） |
| 3 | Windows：`%APPDATA%\binvia\config.json` |
| 4 | 其他平台：`~/.config/binvia/config.json`（不变） |

### 5.3 环境变量

| 变量 | 作用 | 状态 |
|---|---|---|
| `BINVIA_CONFIG` | 配置文件路径覆盖 | 已有 |
| `CURSOR_STATE_DB_PATH` | Cursor 数据库覆盖（Windows zlib/SQLite 不可用时兜底） | 已有 |
| `BINVIA_WEB_PANEL` | `0` 禁用管理面板（覆盖 config，服务端返回 404） | 新增（可选） |

### 5.4 安全说明

- 管理面板默认仅监听 `127.0.0.1`，与网关 API 同端口。不要在生产/公网环境设置 `host=0.0.0.0` 且不设 `admin_password`。
- `admin_password` 存明文于 config（与现有凭据一致），文件权限 0600（Windows 上依赖用户目录 ACL）。
- admin API 返回的配置做凭据脱敏，但 `POST /admin/api/config` 提交的是完整凭据——仅在 loopback 可信场景使用。

---

## 6. 测试计划

### 6.1 新增 BinviaCheck 套件 `WebPanelTests`

| 用例 | 断言 |
|---|---|
| `GET /` 返回 200 + `Content-Type: text/html` + 包含 `admin` 关键词 | expectEqual(200) |
| `GET /admin/api/overview` 返回 200 + JSON 含 `summary` 字段 | decode 成功 |
| 配置 `admin_password` 后：无 token → 401；`/admin/api/login` 正确密码 → 200 + token；带 token → 200 | 三态 |
| `POST /admin/api/config` 保存后 `/v1/models` 热更新生效 | enabled=false 的 provider 从列表消失 |
| `POST /admin/api/keys` 新增后网关 key 可鉴权 | 401 → 200 |
| `GET /admin/api/config` 凭据掩码 | 返回值不含明文 apiKey |
| `POST /admin/api/providers/*/test`（URLProtocol mock 上游） | 返回 `{success}` |

> 沿用现有「本地真实 HTTPServer 当 mock 上游」测试模式（见 CODEBUDDY.md 测试一节）。

### 6.2 跨平台验证矩阵

| 平台 | 构建 | 测试 | 冒烟 |
|---|---|---|---|
| macOS | `make release` | `make test` | `BinviaApp --smoke-test` |
| Windows | `swift build -c release` | `swift run BinviaCheck` | `binvia serve` + 浏览器访问面板 |

### 6.3 回归风险点

- `RouteHandler.normalizePath` 对 `/admin` 前缀的放行（详见 Phase 2 注意事项）。
- `RouteHandler` 初始化签名变更对 `BinviaApp` / `BinviaServer` / BinviaCheck 所有调用点的适配。
- HTTPServer fd 类型抽象对全部现有调用的影响（类型别名避免大规模改动）。

---

## 7. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| Windows Swift 工具链 `URLSession` async API 不可用 | 高 | Phase 1 冒烟先行；不可用则在 `ProviderHTTPClient` 加适配层（同步 `dataTask` + `withCheckedContinuation` 包装），改动集中在 1 个文件 |
| Swift on Windows 版本滞后（工具链需 ≥ 6.2） | 中 | README 明确安装要求；必要时 `swift-tools-version` 降级为 6.0/5.10 验证 |
| `SO_RCVTIMEO` 等 socket 语义差异 | 中 | Phase 1 逐项适配并在 BinviaCheck 补 Windows 专属连接超时用例 |
| zlib / SQLite3 Windows 模块映射缺失 | 低 | 仅 Cursor provider；`CURSOR_STATE_DB_PATH` 兜底 + README 说明 Cursor 集成在 Windows 可能受限 |
| 内嵌 HTML 维护成本 | 低 | 单文件内聚；前端只依赖原生 JS，未来如需拆分可移 `Resources/` + SPM resources |
| admin API 扩大攻击面 | 中 | 默认 loopback + 可选密码；文档明示安全边界 |

## 8. 实施顺序建议

1. 先落 **Phase 1**（跨平台化），Windows 冒烟通过后合入——macOS 无副作用。
2. 再落 **Phase 2 + 3**（Web 面板），在 macOS 上开发调试（浏览器即调试器），交付时可同时覆盖 macOS 无 GUI 场景。
3. Phase 4/5 在拿到 Windows 环境后并行推进。

> 备注：Phase 2 的 Web 面板对 macOS 用户同样是增量收益（无头/CI 场景可脱离菜单栏 GUI 看监控）。
