# CodexBar 工程分析报告

> 分析日期：2026-08-01
> 工程路径：`/Users/wangbin/workspace/temp/my-token-route/CodexBar`

## 1. 工程概况

CodexBar 是一个 **macOS 14+ 菜单栏应用**，用于监控 AI 编码供应商的用量/限额（剩余额度、重置倒计时、成本、状态），目前支持约 70 个 Provider（Codex、OpenAI、Claude、Cursor、Gemini、Copilot、DeepSeek、Antigravity、OpenRouter、LiteLLM、AWS Bedrock 等）。

- **定位**：只读监控（fetch + parse + 展示），不代理流量。
- **隐私优先**：复用已有会话（OAuth、device flow、API key、浏览器 cookie、本地文件），不存储密码。
- **跨平台 CLI**：捆绑 `codexbar` CLI（macOS/Linux），支持 `usage`/`cards`/`guard`/`serve`/`config` 等命令，可脚本化、可 JSON 输出。
- **技术来源**：MIT 协议开源（作者 Peter Steinberger）。

## 2. 技术栈

| 维度 | 详情 |
|---|---|
| 语言 | Swift 6.2（`swift-tools-version: 6.2`），启用 `StrictConcurrency` |
| 平台 | macOS 14+（app），macOS/Linux（CLI） |
| 构建 | Swift Package Manager（SPM） |
| UI | SwiftUI + AppKit（菜单栏 StatusItem），无 Dock 图标 |
| 存储 | JSON 配置（`~/.config/codexbar/config.json`），SQLite（Linux CLI / 本地扫描） |
| 关键依赖 | Sparkle（自更新）、Commander（CLI 解析）、swift-crypto、swift-log、KeyboardShortcuts、SweetCookieKit（浏览器 Cookie） |

### 模块划分（Package.swift）

| 模块 | 类型 | 路径 | 职责 |
|---|---|---|---|
| `CodexBarCore` | library | `Sources/CodexBarCore/` | 全部核心逻辑：Provider 体系、fetch/parse、HTTP、配置、日志、Keychain、浏览器探测 |
| `CodexBar` | executable (macOS) | `Sources/CodexBar/` | SwiftUI 菜单栏应用：状态存储、设置、图标渲染（约 237 文件） |
| `CodexBarCLI` | executable | `Sources/CodexBarCLI/` | 跨平台 CLI 命令 |
| `CodexBarWidget` | executable (macOS) | `Sources/CodexBarWidget/` | WidgetKit 扩展 |
| `CodexBarClaudeWatchdog` | executable (macOS) | `Sources/CodexBarClaudeWatchdog/` | Claude CLI PTY 会话守护进程 |
| `CodexBarClaudeWebProbe` | executable (macOS) | `Sources/CodexBarClaudeWebProbe/` | Claude web 抓取诊断 |
| `AdaptiveRefreshCore` | target | `Sources/AdaptiveRefreshCore/` | 自适应刷新决策表 |
| `CSQLite3` | systemLibrary | `Sources/CSQLite3/` | Linux sqlite3 链接 |

## 3. 核心架构：Provider 体系

### 3.1 设计模式

```
Sources/CodexBarCore/Providers/
├── ProviderDescriptor.swift        # 描述符 struct + 注册表 ProviderDescriptorRegistry
├── Providers.swift                 # UsageProvider 枚举（70 个）+ ProviderMetadata
├── ProviderFetchPlan.swift         # fetch 策略协议（ProviderFetchStrategy/Pipeline/Context/Plan）
├── APITokenFetchStrategy.swift     # API-key 型策略通用实现
├── ProviderTokenResolver.swift     # 各 Provider token 解析集中地
├── ProviderHTTPClient.swift        # 统一 HTTP 客户端（重试/重定向防护）
├── ProviderBranding.swift / ProviderSettingsSnapshot.swift / ...
└── <ProviderName>/                 # 每个 Provider 一个子目录
    ├── XxxProviderDescriptor.swift # 描述符 + fetch strategy
    ├── XxxSettingsReader.swift     # 环境变量/配置读取
    ├── XxxUsageFetcher.swift       # HTTP 抓取 + 解析
    ├── XxxUsageSnapshot.swift      # Provider 专属快照
    └── ...
```

### 3.2 核心类型

**`ProviderDescriptor`**（`ProviderDescriptor.swift`）：

```swift
public struct ProviderDescriptor: Sendable {
    public let id: UsageProvider            // 唯一标识（枚举）
    public let metadata: ProviderMetadata   // 展示名、标签、图标
    public let branding: ProviderBranding
    public let tokenCost: ProviderTokenCostConfig
    public let pace: ProviderPaceCapability // 重置窗口/月度推断
    public let fetchPlan: ProviderFetchPlan // 数据源模式 + 策略管线
    public let cli: ProviderCLIConfig       // CLI 名/别名/版本探测
    public func fetchOutcome(context:) async -> ProviderFetchOutcome
    public func fetch(context:) async throws -> ProviderFetchResult
}
```

**`ProviderFetchPlan`**：数据源模式（`sourceModes`）+ 策略管线（多个 strategy 依序降级）。五类 fetch 策略：
- `cli` — 调用本地 CLI
- `web` — 浏览器 web 会话
- `oauth` — OAuth 远程 API
- `apiToken` — API key 型（`APITokenFetchStrategy`，闭包注入 `resolveToken`/`loadUsage`）
- `localProbe` — 本地端口探测（如 Antigravity）

### 3.3 Provider 注册方式

1. `UsageProvider` 枚举（`Providers.swift`）是唯一事实来源。
2. 每个 Provider 提供 `static let descriptor: ProviderDescriptor`。
3. `ProviderDescriptorRegistry.descriptorsByID` 静态字典登记全部映射，`bootstrap` 首次访问自动注册。
4. **新增 Provider = 新建子目录 + 枚举加 case + 注册表加一行**。

## 4. 典型 Provider 接入方式

### 4.1 API-key 型：DeepSeek（`Sources/CodexBarCore/Providers/DeepSeek/`）

| 文件 | 作用 |
|---|---|
| `DeepSeekProviderDescriptor.swift` | 描述符 + `DeepSeekAPIFetchStrategy`/`DeepSeekPlatformFetchStrategy` |
| `DeepSeekSettingsReader.swift` | 读取 `DEEPSEEK_API_KEY`/`DEEPSEEK_KEY`，SHA-256 profile scope |
| `DeepSeekUsageFetcher.swift` | `GET https://api.deepseek.com/user/balance`（Bearer）+ 平台用量端点 |
| `DeepSeekUsageCostParser.swift` | 解析 `balance_infos`、`usage/amount`、`usage/cost` |
| `DeepSeekPlatformTokenImporter.swift` | 从 Chrome local-storage 导入 Platform token |
| `UsageSnapshot+DeepSeek.swift` | 快照转换 |

**流程**：`ProviderTokenResolver.deepseekToken` → 读 env → 选 strategy（`.api`/`.web`/`.auto`）→ `ProviderHTTPClient.shared.response(for:)` → 解析 → `toUsageSnapshot()`。

**关键点**：API key 型 Provider 的通用模式已抽象为 `APITokenFetchStrategy`——只需注入 `resolveToken` 和 `loadUsage` 两个闭包。

### 4.2 本地探测型：Antigravity（`Sources/CodexBarCore/Providers/Antigravity/`，13 文件）

| 文件 | 作用 |
|---|---|
| `AntigravityProviderDescriptor.swift` | 描述符 + app/CLI/OAuth 三个 strategy + 账号守卫 |
| `AntigravityStatusProbe.swift` | 进程发现（`ps -ax`）+ gRPC-web `POST 127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/...` |
| `AntigravityStatusProbe+PortDetection.swift` | **端口探测**：`lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` |
| `AntigravityCLISession.swift` | PTY 常驻 `agy` CLI 进程管理 |
| `AntigravityRemoteUsageFetcher.swift` | OAuth 远程源（`cloudcode-pa.googleapis.com/v1internal:*`） |
| `AntigravityOAuthCredentialsStore.swift` | OAuth 凭据存取，`ANTIGRAVITY_OAUTH_CREDENTIALS_JSON` env 注入 |

**本地探测流程**：
1. `ps -ax` 分类进程（app / IDE / CLI `agy`），提取 `--csrf_token`、`--extension_server_port`。
2. `lsof` 列出监听端口。
3. POST 到本地 HTTPS 端点，先 `RetrieveUserQuotaSummary`，回退 `GetUserStatus`、`GetCommandModelConfigs`。
4. 若应用未开，则用 PTY 拉起 `agy`，等待其本地 HTTPS 服务就绪后探测。

**对本文档后续工程的启示**：Antigravity 的"本地端口探测"模式可直接复用为**本地供应商代理**的探测机制。

## 5. 配置系统

- 目录：`Sources/CodexBarCore/Config/`（5 文件）。
- 文件：`~/.config/codexbar/config.json`（`CODEXBAR_CONFIG` 可覆盖；legacy `~/.codexbar/config.json`）。
- 结构：`version` + `providers[]`（id/enabled/source/apiKey/cookieHeader/tokenAccounts/...）+ `hooks`。
- `ProviderConfigEnvironment.swift` 把配置字段投影为环境变量注入 Provider fetch 上下文。

## 6. HTTP 客户端

`Sources/CodexBarCore/ProviderHTTPClient.swift`：
- `ProviderHTTPClient.shared` 单例，30s 请求超时 / 90s 资源超时。
- `ProviderHTTPRetryPolicy`：可重试 408/429/500/502/503/504，指数退避上限 10s，尊重 `Retry-After`。
- `redirectGuardedSession`：重定向防护（仅 https→https 且同源），防止凭据泄漏。

## 7. CLI 实现

- 入口：`Sources/CodexBarCLI/CLIEntry.swift`（`@main` async），基于 `steipete/Commander` 的 `Program(descriptors:)` 解析。
- 命令：`usage`、`cards`、`guard`（配额门禁）、`cost`、`sessions`、`serve`（本地 HTTP 服务）、`config`（validate/dump/providers/enable/disable/set-api-key）、`hooks`、`cache`、`cookie`、`diagnose`。

## 8. 数据模型

| 模型 | 文件 |
|---|---|
| `UsageSnapshot`（统一快照：primary/secondary/tertiary 速率窗 + provider 明细 + identity） | `Sources/CodexBarCore/UsageFetcher.swift` |
| `ProviderAccountSnapshot` / `ProviderIdentitySnapshot` / `ProviderCostSnapshot` | `ProviderAccountSnapshot.swift` 等 |
| Provider 专属模型 | 各 Provider 目录内 |

## 9. 关键目录索引

```
Sources/CodexBarCore/                 # 核心库
├── Providers/                        # Provider 体系（70 子目录 + 基础设施）
│   ├── ProviderDescriptor.swift      #   描述符 + 注册表
│   ├── Providers.swift               #   UsageProvider 枚举
│   ├── APITokenFetchStrategy.swift   #   API-key 通用策略
│   ├── DeepSeek/  Antigravity/  ...  #   各 Provider 实现
├── Config/                           # 配置系统
├── ProviderHTTPClient.swift          # HTTP 客户端
├── UsageFetcher.swift                # 统一快照模型
├── Hooks/  Logging/  Host/  WebKit/  # 基础设施
Sources/CodexBar/                     # macOS 菜单栏应用（UI/状态）
Sources/CodexBarCLI/                  # CLI（36 文件）
Sources/CodexBarWidget/               # WidgetKit 扩展
docs/                                 # 115 篇文档（architecture/provider 文档）
Scripts/                              # 构建/发布/测试脚本（53 个）
```

## 10. 构建与运行

```bash
make start          # 开发主流程（compile_and_run.sh）
swift build         # 纯构建
swift build --product CodexBarCLI   # 构建 CLI
./Scripts/package_app.sh            # 打包 app
make test / make check / make format
```

## 11. 对本工程（Binvia）的可借鉴点

1. **Provider 描述符 + 注册表架构**：`ProviderDescriptor` + `ProviderDescriptorRegistry` 的注册方式轻量、扩展性好，适合作为路由网关的供应商抽象。
2. **`APITokenFetchStrategy` 抽象**：API-key 型供应商（DeepSeek）只需注入 `resolveToken` + `loadUsage`，可作为路由器供应商基类。
3. **`ProviderFetchPlan` 多策略降级**：`sourceModes` + 策略管线（自动/API/Web 降级）适用于"多接入方式供应商"（DeepSeek 有 API 和 Web 双通道）。
4. **`ProviderHTTPClient` 重试/重定向防护**：可作为代理转发的上游 HTTP 客户端基础。
5. **CLI + JSON 输出**：`codexbar serve` 已证明用 CLI 起本地 HTTP 服务的可行性。
6. **Antigravity 本地端口探测**：`lsof` + 本地 HTTPS 探测模式可用于检测本地供应商进程是否可用。
