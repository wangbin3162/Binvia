# Binvia GUI 实现指南

> 制定日期：2026-08-01
> 参考：CodexBar（[codexbar-analysis.md](codexbar-analysis.md)）、工程 A（my-token-route2）GUI 原型

## 1. 目标

为 Binvia 增加 macOS 菜单栏 GUI 应用，实现以下功能：

- 通过 GUI 启动/停止本地代理服务器
- 在 GUI 面板绑定 DeepSeek API Key
- 在 GUI 面板发起 CodeBuddy / Antigravity 的 OAuth 登录流程
- 在 GUI 面板创建和管理网关 API Key
- 在 GUI 面板测试各 Provider / Model 的连通性
- 实时展示请求统计与 Provider 健康状态

## 2. 架构原则

### 2.1 Core 与 UI 解耦

BinviaCore 是纯库，不含任何 UI 依赖。GUI 应用作为一个新的可执行目标 `BinviaApp`，仅依赖 `BinviaCore`，不反向引入 UI 依赖到 Core。

```
BinviaCore (library, 无 UI)
    ↑
BinviaApp (executable, SwiftUI + AppKit)
```

### 2.2 借鉴 CodexBar 的 UI 模式

CodexBar 的 UI 架构是经过验证的 macOS 菜单栏应用模式，核心组件如下：

| CodexBar 组件 | 作用 | Binvia 对应 |
|---|---|---|
| `CodexbarApp.swift` | SwiftUI `@main` 入口，`MenuBarExtra` | `BinviaApp.swift` |
| `StatusItemController.swift` | `NSStatusItem` 管理，图标渲染 | `StatusItemController.swift`（或 SwiftUI 原生 `MenuBarExtra`） |
| `MenuCardView.swift` | 弹出面板主视图 | `MenuPanelView.swift` |
| `PreferencesView.swift` | 设置窗口（`NSWindow` + SwiftUI） | `SettingsView.swift` |

### 2.3 状态管理

采用 SwiftUI 的 `@Observable`（macOS 14+）或 `ObservableObject` + `@Published` 模式。一个 `AppState` 类持有全部 UI 状态，通过 `Timer` 或 `Task` 定期刷新 metrics。

CodexBar 的 `AppState` 管理服务器生命周期和 metrics 轮询的模式可以直接复用，但要注意 Swift 6 StrictConcurrency 下的线程安全：`@MainActor` 标注 UI 类，metrics 轮询通过 `Task` 在后台执行，结果回主线程更新。

## 3. 新增 Target 结构

### 3.1 Package.swift 变更

在 `Package.swift` 中新增一个 executable target：

```swift
.executableTarget(
    name: "BinviaApp",
    dependencies: ["BinviaCore"],
    path: "Sources/BinviaApp",
    swiftSettings: [
        .enableUpcomingFeature("StrictConcurrency"),
    ]),
```

并在 products 中增加：

```swift
.executable(name: "BinviaApp", targets: ["BinviaApp"]),
```

### 3.2 目录结构

```
Sources/BinviaApp/
├── BinviaApp.swift           # @main 入口，MenuBarExtra
├── AppState.swift               # 全局状态管理（服务器生命周期、配置、metrics）
├── Views/
│   ├── MenuPanelView.swift       # 菜单栏弹出面板主视图
│   ├── ServerStatusView.swift     # 服务器状态区（启停按钮、端口、指示灯）
│   ├── ProviderListView.swift     # Provider 列表（状态、请求计数、操作按钮）
│   ├── ProviderDetailView.swift   # 单个 Provider 详情（绑定 Key / OAuth 登录 / 测试）
│   ├── APIKeyManagerView.swift    # 网关 API Key 创建与管理
│   ├── UsageView.swift             # 用量统计展示
│   └── SettingsView.swift          # 设置窗口（端口配置、高级选项）
└── Components/
    ├── StatusBadge.swift           # 状态指示灯组件
    ├── APIKeyInputField.swift      # API Key 输入框（支持密码遮蔽）
    └── OAuthLoginButton.swift       # OAuth 登录按钮（封装设备码/PKCE 流程）
```

## 4. 界面设计（参考 CodexBar）

### 4.1 菜单栏图标

CodexBar 使用 `NSStatusItem` 动态绘制图标，Binvia 可以简化为使用 SF Symbols：

```swift
MenuBarExtra("Binvia", systemImage: appState.isServerRunning ? "bolt.shield.fill" : "bolt.shield") {
    MenuPanelView()
        .environmentObject(appState)
}
```

运行时图标为彩色填充状态，停止时为灰色描边状态。可选：在图标旁显示请求计数（类似 CodexBar 的动态数字），但初期可不加。

### 4.2 弹出面板布局（MenuPanelView）

面板宽度 320pt，从上到下分为四个区域：

```
┌───────────────────────────────────┐
│  Binvia                        │  ← 标题区
│  ● Running on :8231    [Stop]     │  ← 服务器状态区
├───────────────────────────────────┤
│  Providers                        │  ← Provider 列表区
│  ┌─────────────────────────────┐  │
│  │ DeepSeek        ●  42 reqs │  │
│  │   sk-...a3f1   [Test] [⚙]  │  │
│  ├─────────────────────────────┤  │
│  │ CodeBuddy CN    ●  15 reqs │  │
│  │   OAuth ✓       [Test] [⚙]  │  │
│  ├─────────────────────────────┤  │
│  │ Antigravity     ●   8 reqs │  │
│  │   OAuth ✓       [Test] [⚙]  │  │
│  └─────────────────────────────┘  │
├───────────────────────────────────┤
│  Gateway API Keys         [+ New] │  ← API Key 管理区
│  sk-tg-...x7e2         [Copy]     │
│  sk-tg-...f9a3         [Copy]     │
├───────────────────────────────────┤
│  Usage: 65 reqs · 3 errors        │  ← 摘要区
│  [Open Settings]        [Quit]    │
└───────────────────────────────────┘
```

### 4.3 服务器状态区（ServerStatusView）

一个水平 `HStack`，左侧是状态指示灯（绿色圆点=运行，红色=停止），中间是状态文字（`Running on :8231` 或 `Stopped`），右侧是启停按钮。

启停逻辑通过 `AppState` 调用 `HTTPServer`：

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var isServerRunning = false
    @Published var port = 8231
    @Published var config: RouteConfig

    private var server: HTTPServer?
    private var routeHandler: RouteHandler?

    func startServer() {
        ProviderCatalog.registerAll()
        routeHandler = RouteHandler(config: config)
        server = HTTPServer { [weak routeHandler] request in
            try await routeHandler?.handle(request)
        }
        do {
            try server?.start(host: config.host, port: config.port)
            isServerRunning = true
        } catch {
            // 弹出错误提示
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        isServerRunning = false
    }
}
```

注意：`HTTPServer.start` 内部已经在新线程中 accept 连接，不会阻塞主线程。但 `MenuBarExtra` 的 `RunLoop.main.run()` 需要保持运行，这与 `HTTPServer` 的 `dispatchMain()` 调用可能冲突。需要确保 `HTTPServer` 不调用 `dispatchMain()`（当前实现中 `dispatchMain()` 在 CLI 的 `serve` 子命令中调用，不在 `HTTPServer.start()` 内部，所以不冲突）。

### 4.4 Provider 列表区（ProviderListView）

遍历 `ProviderRegistry.shared.allDescriptors()`，每个 Provider 一行卡片。卡片内容：

- 左侧：Provider 名称 + 认证状态指示灯（已配置=绿色，未配置=灰色）
- 右侧：请求计数（从 `RequestLogger.shared.summary()` 获取）+ 操作按钮

点击操作按钮（齿轮图标）展开 `ProviderDetailView`，或弹出单独窗口。

### 4.5 Provider 详情视图（ProviderDetailView）

根据 Provider 的 `authType` 不同，展示不同的配置界面。

**API Key 型（DeepSeek）：**

```
┌──────────────────────────────┐
│  DeepSeek                    │
│  API Key:                    │
│  ┌──────────────────────┐    │
│  │ sk-*************a3f1 │    │  ← 密码输入框，支持显示/隐藏切换
│  └──────────────────────┘    │
│  [+ Add another key]          │  ← 多 Key 轮换支持
│  [Save]      [Test Connection]│
└──────────────────────────────┘
```

输入的 Key 通过 `ConfigStore.save()` 写入 `config.json`，运行时即时生效（`RouteHandler` 每次请求都从 `config` 读取 credential）。

**OAuth 型（CodeBuddy / Antigravity）：**

```
┌──────────────────────────────┐
│  CodeBuddy CN                │
│  Status: ● Connected         │
│  Token:  eyJ...exp 2026-08-02 │
│  [Login / Reconnect]          │
│  [Test Connection]            │
└──────────────────────────────┘
```

点击 Login 按钮触发 OAuth 流程。CodeBuddy 使用设备码流（`CodeBuddyOAuthClient.login`），Antigravity 使用 PKCE 流（`AntigravityOAuthClient.login`）。登录完成后凭据写入 `config.json`。

OAuth 流程中的用户交互：
- CodeBuddy：弹出提示框显示授权 URL → 用户在浏览器完成授权 → 自动轮询结果（CLI 中需要用户手动打开浏览器，GUI 中可用 `NSWorkspace.shared.open(url)` 自动打开）
- Antigravity：弹出提示框 → 自动打开浏览器 → 用户完成授权后需要粘贴重定向 URL → 在 GUI 中弹出一个文本输入对话框接收

### 4.6 API Key 管理区（APIKeyManagerView）

展示当前配置的网关 API Key 列表，支持新增和删除。新增的 Key 随机生成（格式 `sk-tg-` + 32 位随机十六进制），保存到 `config.apiKeys` 数组。

```
┌──────────────────────────────┐
│  Gateway API Keys            │
│  sk-tg-...x7e2    [Copy] [✕] │
│  sk-tg-...f9a3    [Copy] [✕] │
│  [+ Generate New Key]        │
└──────────────────────────────┘
```

Key 的生成：

```swift
func generateAPIKey() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    return "sk-tg-\(hex)"
}
```

### 4.7 用量统计区

从 `RequestLogger.shared.summary()` 获取数据，展示总请求数、错误数、各 Provider 的请求分布。初期可简化为一行摘要文字，后续可扩展为简单图表（使用 Swift Charts，macOS 14+ 内置）。

### 4.8 设置窗口（SettingsView）

通过 "Open Settings" 按钮打开一个独立的 `NSWindow` 或 `Window`（SwiftUI Scene）。包含：

- 监听端口配置（修改后需重启服务器生效）
- 监听地址（127.0.0.1 / 0.0.0.0）
- 配置文件路径展示
- 关于信息

## 5. 关键实现细节

### 5.1 MenuBarExtra 生命周期

`MenuBarExtra` 有两种样式：`.menu`（标准菜单）和 `.window`（弹出窗口）。推荐使用 `.window` 以获得更灵活的布局：

```swift
@main
struct BinviaApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Binvia", systemImage: appState.statusIcon) {
            MenuPanelView()
                .environmentObject(appState)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
```

### 5.2 服务器启动时序

应用启动时的初始化顺序：

1. `AppState.init()` — 加载配置（`ConfigStore.load()`），不自动启动服务器
2. UI 显示配置状态（端口、已配置的 Provider）
3. 用户点击 "Start" → 调用 `startServer()`
4. `startServer()` 内部：`ProviderCatalog.registerAll()` → 创建 `RouteHandler` → 创建 `HTTPServer` → `server.start()`
5. 服务器在后台 `DispatchQueue` 中 accept 连接，每个连接在 detached `Task` 中处理
6. UI 每 2 秒刷新一次 metrics（`Timer` + `Task`）

可选：在 `init()` 中自动启动服务器（工程 A 的做法），但这要求配置已就绪。推荐首次启动时引导用户完成配置后再启动。

### 5.3 配置热更新

当用户在 GUI 中修改配置（如添加 API Key、OAuth 登录）后，需要让运行中的服务器立即生效。有两种方案：

方案 A（推荐）：`RouteHandler` 每次请求都从 `config` 对象读取 credential，而 `AppState` 持有 `config` 引用。修改 config 后调用 `ConfigStore.save()` 持久化，下次请求即生效。无需重启服务器。

方案 B：修改 config 后重启服务器。简单但会导致正在进行的请求中断。

选择方案 A 时，需要确保 `RouteConfig` 是引用语义或 `AppState` 中的 `config` 变更能被 `RouteHandler` 看到。当前 `RouteHandler` 在初始化时持有 `config` 副本，需要改为持有引用或重新创建 `RouteHandler`。

最简实现：修改 config 后重新创建 `RouteHandler` 并替换 `HTTPServer` 的 handler 闭包。但 `HTTPServer` 当前不暴露 handler 替换接口。需要为 `HTTPServer` 增加一个可变的 handler 属性，或在 `AppState` 中重新创建 `HTTPServer`（先 stop 再 start）。

推荐：为 `HTTPServer` 增加 `handler` 为 `var` 属性（而非构造函数参数），允许运行时替换。

### 5.4 OAuth 登录的 GUI 适配

**CodeBuddy 设备码流：**

CLI 中需要用户手动在浏览器打开授权 URL。GUI 中可以自动打开：

```swift
func loginCodeBuddy() async {
    let client = CodeBuddyOAuthClient()
    do {
        let credential = try await client.login { url in
            Task { @MainActor in
                NSWorkspace.shared.open(url)
                appState.oauthStatus = .waitingForAuth("请在浏览器中完成授权…")
            }
        }
        try saveCredential(credential, for: "codebuddy-cn")
        appState.oauthStatus = .connected
    } catch {
        appState.oauthStatus = .failed(error.localizedDescription)
    }
}
```

**Antigravity PKCE 流：**

需要用户粘贴重定向 URL。GUI 中弹出一个 `NSAlert` 或自定义 Sheet 包含文本输入框：

```swift
func loginAntigravity() async {
    let client = AntigravityOAuthClient(config: .live())
    do {
        let credentials = try await client.login(
            openURL: { url in
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                }
            },
            codeProvider: { _ in
                await MainActor.run {
                    appState.showCodeInputDialog = true
                }
                // 等待用户在 GUI 中输入 code
                return await appState.waitForCodeInput()
            }
        )
        try saveCredential(credentials, for: "antigravity")
        appState.oauthStatus = .connected
    } catch {
        appState.oauthStatus = .failed(error.localizedDescription)
    }
}
```

`waitForCodeInput()` 需要用 `CheckedContinuation` 实现 GUI 输入与 async 代码的桥接：

```swift
private var codeContinuation: CheckedContinuation<String, Error>?

func waitForCodeInput() async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        self.codeContinuation = continuation
    }
}

func submitCode(_ code: String) {
    codeContinuation?.resume(returning: code)
    codeContinuation = nil
}
```

### 5.5 连通性测试

点击 "Test Connection" 按钮时，在后台 Task 中调用 `provider.testConnection(credential:)`，结果回主线程更新 UI：

```swift
func testProvider(_ providerID: String) {
    appState.testResults[providerID] = .testing
    Task {
        let provider = registry.provider(for: providerID)
        let credential = appState.config.credential(for: providerID)
        let result = try await provider?.testConnection(credential: credential)
        await MainActor.run {
            appState.testResults[providerID] = result?.success == true ? .ok(result?.message ?? "") : .failed(result?.message ?? "Unknown error")
        }
    }
}
```

测试结果用三态表示：`idle`（未测试）、`testing`（测试中，显示 ProgressView）、`ok`（成功，显示绿色勾）、`failed`（失败，显示红色叉 + 错误信息）。

### 5.6 Metrics 刷新

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var usageSummary: UsageSummary = UsageSummary(byProvider: [:])

    private var refreshTimer: Timer?

    func startMetricsRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                self.usageSummary = RequestLogger.shared.summary()
            }
        }
    }
}
```

### 5.7 StrictConcurrency 注意事项

BinviaCore 已启用 `StrictConcurrency`。GUI 层需注意：

`AppState` 标记 `@MainActor`，所有 UI 状态变更在主线程。`HTTPServer` 的 handler 闭包运行在后台线程，闭包内不能直接访问 `AppState` 的 `@Published` 属性。但 `RouteHandler` 本身是 `Sendable` 的，持有 `Sendable` 的 `config`，所以可以安全地在后台线程调用。

`RequestLogger.shared` 是 `@unchecked Sendable`，内部用 `NSLock` 保护，可以从任何线程调用。但 `summary()` 返回的 `UsageSummary` 是值类型，赋值给 `@Published` 属性时需要在主线程执行。

## 6. 开发阶段计划

### Phase 6 — GUI 骨架

- [ ] 新增 `BinviaApp` target（Package.swift + 目录结构）
- [ ] `BinviaApp.swift`：`MenuBarExtra` + `@main` 入口
- [ ] `AppState.swift`：服务器生命周期管理（start/stop）、配置加载
- [ ] `MenuPanelView.swift`：面板骨架（标题 + 状态 + 占位内容）
- [ ] `ServerStatusView.swift`：启停按钮 + 状态指示灯
- [ ] 验证：应用可启动，菜单栏出现图标，可启停服务器

### Phase 7 — Provider 管理

- [ ] `ProviderListView.swift`：Provider 列表（名称 + 状态 + 请求计数）
- [ ] `ProviderDetailView.swift` — DeepSeek：API Key 输入 + 保存 + 多 Key 支持
- [ ] `ProviderDetailView.swift` — CodeBuddy：OAuth 登录按钮（设备码流，自动打开浏览器）
- [ ] `ProviderDetailView.swift` — Antigravity：OAuth 登录按钮（PKCE 流，code 输入对话框）
- [ ] 连通性测试按钮 + 三态结果展示
- [ ] 验证：三种 Provider 均可在 GUI 中配置并测试

### Phase 8 — API Key 管理

- [ ] `APIKeyManagerView.swift`：Key 列表 + 生成 + 删除 + 复制
- [ ] Key 生成逻辑（`SecRandomCopyBytes`）
- [ ] 配置持久化（`ConfigStore.save()`）
- [ ] 验证：生成的 Key 可用于 API 调用

### Phase 9 — 监控与设置

- [ ] `UsageView.swift`：请求统计展示（总数、错误数、各 Provider 分布）
- [ ] Metrics 定时刷新（2s Timer）
- [ ] `SettingsView.swift`：端口配置 + 配置文件路径
- [ ] 配置热更新（修改后无需重启服务器即生效）
- [ ] 验证：修改配置后即时生效，统计数据实时刷新

### Phase 10 — 打磨

- [ ] 菜单栏图标动态状态（运行/停止/错误）
- [ ] OAuth 登录进度提示与错误展示
- [ ] `HTTPServer` handler 运行时替换支持
- [ ] 打包脚本更新（`build.sh` 增加 `BinviaApp` 产物）
- [ ] README 补充 GUI 使用说明
- [ ] 测试：端到端 GUI 操作验证

## 7. 参考对照表

| CodexBar 模式 | Binvia 复用方式 |
|---|---|
| `MenuBarExtra` + `NSStatusItem` | 直接使用 SwiftUI `MenuBarExtra(.window)` 样式 |
| `StatusItemController` 图标渲染 | 简化为 SF Symbols 动态切换 |
| `MenuCardView` 弹出面板 | `MenuPanelView`，SwiftUI VStack 布局 |
| `PreferencesView` 设置窗口 | `SettingsView`，SwiftUI `Settings` scene |
| `AppState` + Timer 轮询 | 同模式，`@MainActor` + `Timer` + `Task` |
| `ConfigStore` 配置读写 | 直接复用 BinviaCore 的 `ConfigStore` |
| `ProviderHTTPClient` | 直接复用（Core 已有） |
| OAuth 流程 | 复用 Core 中的 `CodeBuddyOAuthClient` / `AntigravityOAuthClient`，GUI 层仅处理用户交互 |
| `RequestLogger` metrics | 直接复用，GUI 层调用 `summary()` 展示 |
