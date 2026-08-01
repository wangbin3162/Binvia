# Binvia 实现计划

> 制定日期：2026-08-01
> 目标：实现供应商聚合路由应用，连接 CodeBuddy / Antigravity / DeepSeek 等供应商，路由模型供工具调用，并提供监控。

## 1. 工程定位与核心目标

**Binvia** 是一个本地 AI 供应商聚合路由网关：

- **供应商接入**：连接 DeepSeek（API key）、腾讯 CodeBuddy（OAuth 设备码）、Google Antigravity（OAuth）等供应商。
- **统一出口**：在本地端口提供 OpenAI 兼容 API（`/v1/chat/completions`、`/v1/models`、`/v1/health`），工具（Claude Code、Codex、各类 SDK）通过 api-key 调用。
- **路由**：`provider/model` 模型语法路由到对应供应商；支持可用性测试、健康检查、失败回退。
- **监控**：请求日志、用量统计、供应商健康状态。

## 2. 技术选型（基于 CodexBar 框架）

| 维度 | 决策 | 依据 |
|---|---|---|
| 语言 | Swift 6（StrictConcurrency） | CodexBar 同框架 |
| 构建 | Swift Package Manager | CodexBar 同框架 |
| 平台 | macOS 14+，可扩展 Linux | CodexBar 支持 macOS + Linux CLI |
| HTTP 服务 | 原生 POSIX socket 服务器（Foundation only） | 复用 CodexBar `CLILocalHTTPServer` 模式（`socket/bind/accept` + DispatchSource），零外部依赖 |
| 上游 HTTP | 自研 `ProviderHTTPClient`（Foundation URLSession） | 复用 CodexBar `ProviderHTTPClient` 模式（重试/重定向防护） |
| Provider 架构 | `ProviderDescriptor` + `ProviderRegistry` | 复用 CodexBar 架构 |
| 供应商注册 | `REGISTRY: [String: ProviderDescriptor]` | 借鉴 OmniRoute 注册表扁平结构 |
| 路由语法 | `provider/model` + 别名 | 借鉴 OmniRoute `parseModel` |
| 认证 | api-key（`Authorization: Bearer` / `x-api-key`）+ env key 白名单 | 借鉴 OmniRoute `clientApi` 策略 |
| 存储 | JSON 配置（`~/.config/binvia/config.json`） | 借鉴 CodexBar 配置系统 |
| 监控 | 内存日志 + JSON 导出 | 先最小，后扩展 |

### 模块划分

| 模块 | 类型 | 职责 |
|---|---|---|
| `BinviaCore` | library | Provider 协议/注册表、路由引擎、认证、上游 HTTP 客户端、配置、监控 |
| `BinviaServer` | executable | 本地代理服务器（HTTP + SSE） |
| `BinviaCLI` | executable | CLI 命令（providers/test/serve/config/usage） |
| `BinviaApp` | executable (macOS) | SwiftUI 菜单栏 GUI 应用（启停服务器、配置 Provider、管理 API Key、测试连通性） |
| `BinviaCheck` | executable | 自包含测试（96 用例，无 Xcode 依赖） |

> GUI 详细设计见 [gui-implementation-guide.md](gui-implementation-guide.md)

## 3. 核心架构设计

### 3.1 Provider 抽象

借鉴 CodexBar `ProviderDescriptor` + OmniRoute `RegistryEntry`：

```swift
// 核心协议
public protocol Provider: Sendable {
    var id: String { get }
    var metadata: ProviderMetadata { get }
    var authType: ProviderAuthType { get }        // .apiKey / .oauth / .deviceFlow
    func listModels(credential:) async throws -> [Model]
    func chat(stream request: ChatRequest, credential:) async throws -> AsyncThrowingStream<ChatEvent, Error>
    func testConnection(credential:) async throws -> ConnectionTestResult
}

// 描述符 + 注册表
public struct ProviderDescriptor: Sendable {
    public let id: String
    public let alias: String?
    public let metadata: ProviderMetadata
    public let authType: ProviderAuthType
    public let baseURL: URL
    public let models: [Model]                    // 静态模型目录
    public let factory: @Sendable () -> any Provider
}

public final class ProviderRegistry: Sendable {
    public static let shared = ProviderRegistry()
    private var descriptors: [String: ProviderDescriptor] = [:]
    public func register(_ d: ProviderDescriptor)
    public func descriptor(for id: String) -> ProviderDescriptor?
    public func resolveProvider(_ modelID: String) -> (providerID: String, modelID: String)?  // "ds/deepseek-v4-pro" 解析
}
```

### 3.2 路由引擎

```
/v1/chat/completions
  ├→ 认证（api-key）
  ├→ 解析 model="provider/model" 或别名
  ├→ resolveProvider → ProviderRegistry.lookup
  ├→ 凭据解析（config.json 或 env）
  ├→ testConnection 缓存（可用性）
  ├→ provider.chat(stream:)  → 上游
  └→ SSE/JSON 响应回传 + 请求日志
```

### 3.3 本地代理服务器

- 原生 socket 服务器监听 `127.0.0.1:PORT`（默认 8231）。
- 请求解析（method/path/headers/body）→ 路由分发。
- 支持 SSE 流式响应（`text/event-stream`）。
- 端点：
  - `GET /v1/models` — 聚合模型目录
  - `POST /v1/chat/completions` — 聊天（流式 + 非流式）
  - `GET /v1/health` — 健康检查
  - `GET /v1/usage` — 用量/日志（监控）

### 3.4 配置

```json
{
  "version": 1,
  "port": 8231,
  "apiKeys": ["sk-local-..."],
  "providers": {
    "deepseek": { "enabled": true, "apiKey": "sk-..." },
    "codebuddy-cn": { "enabled": true, "oauth": { "accessToken": "...", "refreshToken": "..." } },
    "antigravity": { "enabled": true, "oauth": { "accessToken": "...", "refreshToken": "..." } }
  }
}
```

## 4. 供应商接入方案（三个典型）

### 4.1 DeepSeek（API key — ✅ 已完成）

- 注册表：`id: "deepseek"`, `alias: "ds"`, `authType: .apiKey`, baseURL `https://api.deepseek.com/v1`。
- 认证：`Authorization: Bearer <DEEPSEEK_API_KEY>`。
- 模型：`deepseek-v4-pro`、`deepseek-v4-flash`（可从 `/v1/models` 动态拉取 + `ModelCache` 缓存）。
- 聊天：标准 OpenAI 兼容，流式 + 非流式直通；多 api-key 401/403 自动轮换。
- 可用性测试：`GET /v1/models` 或最小 token 请求。
- **依据**：CodexBar `DeepSeek`（API key 型，`APITokenFetchStrategy`）+ OmniRoute `registry/deepseek`（`authType:"apikey"`, `executor:"default"`）。
- 实现：`Sources/BinviaCore/Providers/DeepSeek/DeepSeekProvider.swift`

### 4.2 腾讯 CodeBuddy（OAuth 设备码 — ✅ 已完成）

- 注册表：`id: "codebuddy-cn"`, `alias: "cbcn"`, `authType: .deviceFlow`, baseURL `https://copilot.tencent.com/v2/chat/completions`。
- 认证：设备码流（`requestDeviceCode` → 浏览器打开 `authUrl` → 轮询 `pollToken` 直到 `code===0`，`11217` 为 pending；`refreshAccessToken`）。
- 请求特点：**强制流式**（非流式被上游 400 code 11101 拒绝），非流式客户端由 `SSEJSONAggregator` 自动重聚合。
- Headers：`User-Agent: CLI/2.108.1 CodeBuddy/2.108.1`、`X-Product: SaaS`、`X-IDE-Type: CLI`。
- **依据**：OmniRoute `registry/codebuddy-cn` + `src/lib/oauth/providers/codebuddy-cn.ts` + `open-sse/executors/codebuddy-cn.ts`。
- 实现：`Sources/BinviaCore/Providers/CodeBuddy/CodeBuddyOAuthClient.swift` + `CodeBuddyCNProvider.swift`

### 4.3 Google Antigravity（OAuth + cloudcode 信封 — ✅ 已完成）

- 注册表：`id: "antigravity"`, `alias: "agy"`, `authType: .oauth`, 上游 `cloudcode-pa.googleapis.com`。
- 认证：Google OAuth `authorization_code` + PKCE；OAuth 后 `loadCodeAssist` + `onboardUser` 获取 `projectId`。
- 请求：cloudcode 信封（Gemini `contents` 格式）→ 翻译为 OpenAI → 上游 `streamGenerateContent?alt=sse` → 反向翻译回 SSE。
- **依据**：OmniRoute `registry/antigravity` + `open-sse/executors/antigravity.ts` + CodexBar `Providers/Antigravity`（本地探测/OAuth）。
- 实现：`Sources/BinviaCore/Providers/Antigravity/AntigravityOAuthClient.swift` + `AntigravityEnvelopeTranslator.swift` + `AntigravityProvider.swift`
- **扩展（二期）**：参考 CodexBar `AntigravityStatusProbe` 实现本地 language server 探测（`lsof` 端口探测），实现"本地供应商直接代理"。

## 5. 实现阶段计划

### Phase 0 — 工程骨架（已完成 ✅）
- [x] 创建 `Binvia` Swift 包（Package.swift：Core/Server/CLI 三目标）
- [x] 核心类型：`Provider` 协议、`ProviderDescriptor`、`ProviderRegistry`、`Model`、`ChatRequest/ChatEvent`
- [x] 三个 Provider 描述符注册（deepseek/codebuddy-cn/antigravity）
- [x] 配置读写（config.json）
- [x] API-key 认证
- [x] 本地 HTTP 服务器骨架（原生 socket）
- [x] 路由端点骨架（`/v1/models`、`/v1/chat/completions`、`/v1/health`、`/v1/usage`）
- [x] DeepSeek Provider 端到端可用（api-key 直通，SSE 流式 + 非流式，mock 验证通过）
- [x] `swift build` 通过验证

### Phase 1 — 核心完善（已完成 ✅）
- [x] SSE 流式转发完整实现（流式 + JSON 聚合）※ `SSEParser`/`SSEJSONAggregator`
- [x] 可用性测试接口（`testConnection`）+ CLI `providers test` / `oauth login`
- [x] 模型动态获取（上游 `/v1/models` 拉取 + `ModelCache` 缓存）
- [x] 多 api-key / 密钥轮换（`ProviderConfig.apiKeys`，401/403 自动切换）
- [x] 错误处理与上游重试策略（`ProviderHTTPRetryPolicy`）

### Phase 2 — CodeBuddy 接入（已完成 ✅）
- [x] OAuth 设备码流实现（获取/刷新 token）※ `CodeBuddyOAuthClient`
- [x] `CodeBuddyProvider` 执行器（强制流式 + JSON 重聚合）
- [x] 模型目录（GLM 系列等 15 个）
- [x] 可用性测试（OAuth 自动 refresh 探测）

### Phase 3 — Antigravity 接入（已完成 ✅）
- [x] Google OAuth（PKCE）+ projectId 引导 ※ `AntigravityOAuthClient`
- [x] cloudcode 信封翻译器（request/response 双向）※ `AntigravityEnvelopeTranslator`
- [x] `AntigravityProvider` 执行器（流式）
- [x] 可用性测试

### Phase 4 — 监控（已完成 ✅）
- [x] 请求日志（时间/模型/供应商/耗时/token/状态）※ `RequestLogger`
- [x] 用量统计（按供应商/模型聚合）※ `UsageSummary`
- [x] `GET /v1/usage` 导出接口
- [x] 健康检查与状态聚合

### Phase 5 — 扩展与收尾（已完成 ✅）
- [x] 测试用例（单元 + 集成）：自包含可运行测试 `BinviaCheck`（96 用例，`make test` 本机直接跑，无需 Xcode）
- [x] README 使用文档
- [ ] 扩展其他供应商（本地探测型，如 Antigravity 本地 LSP）※ 二期
- [x] 打包脚本（Makefile / Scripts/build.sh，产物到 `bin/`）

### Phase 6 — GUI 骨架（待开始 ⏳）

目标：菜单栏应用可启动，可启停服务器。

- [ ] `Package.swift` 新增 `BinviaApp` executable target（依赖 `BinviaCore`）
- [ ] `Sources/BinviaApp/BinviaApp.swift`：`@main` + `MenuBarExtra(.window)`
- [ ] `Sources/BinviaApp/AppState.swift`：`@MainActor` 状态管理（配置加载、服务器生命周期）
- [ ] `Views/MenuPanelView.swift`：面板骨架（标题 + 状态 + 占位）
- [ ] `Views/ServerStatusView.swift`：启停按钮 + 状态指示灯（绿/红圆点）
- [ ] 验证：应用可启动，菜单栏出现图标，点击可启停服务器

### Phase 7 — Provider 管理 GUI（待开始 ⏳）

目标：在 GUI 中配置三种 Provider 并测试连通性。

- [ ] `Views/ProviderListView.swift`：Provider 列表卡片（名称 + 认证状态 + 请求计数）
- [ ] `Views/ProviderDetailView.swift` — DeepSeek：API Key 输入框（密码遮蔽）+ 多 Key 添加 + 保存
- [ ] `Views/ProviderDetailView.swift` — CodeBuddy：OAuth 登录按钮（设备码流，自动打开浏览器，轮询结果展示）
- [ ] `Views/ProviderDetailView.swift` — Antigravity：OAuth 登录按钮（PKCE 流，code 输入对话框）
- [ ] `Components/OAuthLoginButton.swift`：封装 OAuth 登录交互（进度提示 + 成功/失败反馈）
- [ ] 连通性测试按钮 + 三态结果展示（idle / testing / ok / failed）
- [ ] 配置持久化：修改后调用 `ConfigStore.save()` 写入 `config.json`
- [ ] 验证：三种 Provider 均可在 GUI 中配置、OAuth 登录、测试连通

### Phase 8 — API Key 管理 GUI（待开始 ⏳）

目标：在 GUI 中创建和管理网关 API Key。

- [ ] `Views/APIKeyManagerView.swift`：Key 列表 + 生成 + 删除 + 复制到剪贴板
- [ ] `Components/APIKeyInputField.swift`：密码输入框组件（显示/隐藏切换）
- [ ] Key 生成逻辑（`SecRandomCopyBytes` → `sk-tg-` + 32 位 hex）
- [ ] 配置持久化到 `config.apiKeys`
- [ ] 验证：生成的 Key 可用于 `curl -H "Authorization: Bearer <key>"` 调用

### Phase 9 — 监控与设置 GUI（待开始 ⏳）

目标：实时展示用量统计，提供设置窗口。

- [ ] `Views/UsageView.swift`：请求统计（总数、错误数、各 Provider 分布）
- [ ] Metrics 定时刷新（2s Timer + `Task`）
- [ ] `Views/SettingsView.swift`：端口配置 + 配置文件路径展示 + 环境变量说明
- [ ] 配置热更新（修改后运行中的服务器即时生效，方案：为 `HTTPServer` 增加可变 handler 或重建 RouteHandler）
- [ ] 验证：修改配置后即时生效，统计数据实时刷新

### Phase 10 — GUI 打磨与打包（待开始 ⏳）

- [ ] 菜单栏图标动态状态（运行=彩色填充，停止=灰色描边，错误=带感叹号）
- [ ] OAuth 登录进度提示与错误展示（Sheet 或 Alert）
- [ ] `HTTPServer` handler 运行时替换接口
- [ ] `Scripts/build.sh` 增加 `BinviaApp` 产物拷贝
- [ ] README 补充 GUI 使用说明章节
- [ ] 端到端 GUI 操作验证（配置 → 启动 → 调用 → 查看统计）

## 6. task.md

```markdown
# Binvia 任务清单

## Phase 0 工程骨架 ✅
- [x] Package.swift（BinviaCore / BinviaServer / BinviaCLI）
- [x] Core: Provider 协议、ProviderDescriptor、ProviderRegistry、Model、ChatModels
- [x] Core: ConfigStore（config.json 读写）
- [x] Core: APIKeyAuthenticator
- [x] Core: ProviderHTTPClient（上游，重试/流式/错误透传）
- [x] Core: Router（provider/model 解析、别名、路由）
- [x] Server: HTTPServer（原生 socket）、请求解析、路由分发
- [x] Server: 端点 /v1/models /v1/chat/completions /v1/health /v1/usage
- [x] Providers: DeepSeek（api-key 直通，端到端）
- [x] Providers: CodeBuddy / Antigravity 描述符注册（stub）
- [x] CLI: serve / providers list / config / test / oauth login
- [x] 构建验证 swift build + mock 端到端

## Phase 1 核心完善 ✅
- [x] SSE 流式转发（流式 + JSON 聚合）※ SSEParser / SSEJSONAggregator
- [x] testConnection + CLI providers test
- [x] 动态模型获取 + 缓存 ※ ModelCache
- [x] 上游重试策略 ※ ProviderHTTPRetryPolicy
- [x] 多 api-key / 轮换

## Phase 2 CodeBuddy ✅
- [x] OAuth 设备码流 ※ CodeBuddyOAuthClient
- [x] CodeBuddyProvider 执行器（强制流式 + 重聚合）
- [x] 模型目录（15 个）+ 可用性测试

## Phase 3 Antigravity ✅
- [x] Google OAuth PKCE ※ AntigravityOAuthClient
- [x] cloudcode 信封翻译器 ※ AntigravityEnvelopeTranslator
- [x] AntigravityProvider 执行器 + 可用性测试

## Phase 4 监控 ✅
- [x] 请求日志 ※ RequestLogger
- [x] 用量统计 + /v1/usage
- [x] 健康状态 /v1/health

## Phase 5 扩展收尾 ✅
- [x] 测试（自包含 BinviaCheck，96 用例）
- [x] README
- [x] 打包（Makefile / Scripts/build.sh）
- [ ] 扩展其他供应商（本地探测型 LSP）※ 二期
```

## 7. 参考工程对照表

| 能力 | CodexBar 借鉴 | OmniRoute 借鉴 |
|---|---|---|
| Provider 抽象 | `ProviderDescriptor` + Registry | `RegistryEntry` 扁平注册表 |
| API-key 供应商 | `APITokenFetchStrategy` | `registry/deepseek` |
| OAuth 设备码 | — | `oauth/providers/codebuddy-cn.ts` |
| OAuth + 信封翻译 | `Providers/Antigravity`（本地探测） | `executors/antigravity.ts` + `translator` |
| 本地端口代理 | `CLILocalHTTPServer`（原生 socket） | `mitm/server.cjs` + `standaloneRouting.cjs` |
| api-key 认证 | — | `server/authz/policies/clientApi.ts` |
| 路由语法 | — | `services/model.ts` `parseModel` |
| 配置 | `Config/` JSON | db.json / env |
| 监控 | 日志 | `usageDb.ts` + `monitoring/` |

## 8. 风险评估

| 风险 | 影响 | 缓解 |
|---|---|---|
| CodeBuddy/Antigravity OAuth 流程复杂 | Phase 2/3 延期 | 先 DeepSeek 打通全链路；OAuth 实现参考 OmniRoute 已验证代码 |
| 上游私有协议变化（cloudcode 信封） | Antigravity 不稳定 | 翻译器隔离；失败回退 |
| 原生 socket 服务器 SSE 处理复杂 | 流式转发 bug | 参考 CodexBar 请求解析；SSE 逐事件透传而非缓冲 |
| Swift 服务器生态相对弱 | 开发成本 | 本项目仅需 HTTP 直通，无需框架 |
| 上游限流/429 | 服务质量 | 重试 + 回退 + 健康状态 |
