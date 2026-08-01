# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# 项目简介

Binvia：本地 AI 供应商聚合路由网关（macOS）。在本地端口提供 OpenAI 兼容 API（`/v1/chat/completions`、`/v1/models` 等），连接 DeepSeek / 腾讯 CodeBuddy / Google Antigravity 上游，供 Claude Code、Codex、各类 SDK 通过 api-key 调用，带请求监控与菜单栏 GUI。纯 Swift + 原生 POSIX socket，零外部依赖（Package.swift 无任何第三方依赖）。

# 常用命令

本机只有 CommandLineTools（无 Xcode/xctest），**`swift test` 不可用**，测试统一走自包含可执行 target。

- 构建：`swift build`
- 测试（全部套件）：`make test` 即 `swift run BinviaCheck`
  - 测试是单个可执行文件（`Sources/BinviaCheck/main.swift`），内含极简断言框架；**无法按用例过滤**，想只跑某套件需临时注释入口处对应 `run(...)` 行。
  - 退出码：0=全部通过，1=存在失败断言。
- 运行服务器：`make run`（= `swift run BinviaServer`），可加 `--port N` / `--config PATH`
- CLI：`swift run BinviaCLI providers list`、`test <provider|alias>`、`oauth login <codebuddy-cn|antigravity>`、`config path`、`serve`
- GUI（菜单栏应用）：`swift run BinviaApp`
- GUI 无界面自检：`swift run BinviaApp --smoke-test`（`swift run` 可能被权限分类器拦截，可改跑 `./.build/debug/BinviaApp --smoke-test`）
- 打包（release 构建 + 测试 + GUI 自检 + 拷贝到 bin/）：`make release` 即 `./Scripts/build.sh`，产物 `bin/Binvia.app`、`bin/BinviaServer`、`bin/BinviaCLI`
- 清理：`make clean`（删除 .build 与 bin）

# 架构

## 模块（Package.swift，5 个 target，全部开启 StrictConcurrency）

- **BinviaCore**（库）：全部业务逻辑——Provider 协议/注册表、路由、认证、配置、监控、上游 HTTP 客户端、本地 HTTP 服务器。GUI/CLI/Server/Check 只依赖它。
- **BinviaServer**（可执行）：入口 = 加载配置 → `ProviderCatalog.registerAll()` → `RouteHandler` → `HTTPServer` 常驻。
- **BinviaCLI**（可执行）：providers / test / oauth / config / serve 子命令。
- **BinviaApp**（可执行，SwiftUI + AppKit）：菜单栏 GUI，含 `--smoke-test`。
- **BinviaCheck**（可执行）：自包含测试（非 XCTest）。

## 核心数据流

```
HTTP 客户端 → HTTPServer(POSIX socket) → RouteHandler
  → APIKeyAuthenticator 认证
  → Router.resolve(model) 解析 provider/model
  → Provider.chat() → ProviderHTTPClient → 上游
响应反向返回；SSE 流式逐事件透传，或由 SSEJSONAggregator 聚合成单 JSON
```

## 关键组件（BinviaCore）

- **Provider 协议**（`Provider/`）：`chat` **始终返回 `AsyncThrowingStream<Data>`**（SSE chunk 或整段 JSON body），由上层决定透传（streaming）或聚合（non-streaming）。
- **ProviderDescriptor + ProviderRegistry**：描述符携带静态元数据（id / alias / 模型目录 / baseURL）+ `makeProvider` 工厂闭包；`ProviderRegistry.shared` 是 NSLock 单例，支持 alias 解析。
- **Router**（`Router/Router.swift`）：解析 `provider/model`、`alias/model`、裸模型名（静态目录消歧：模型名以 provider id/alias 前缀开头者优先，仍歧义取字母序）。
- **ProviderHTTPClient**（`Networking/`）：统一上游请求。`data(for:retryPolicy:)` 指数退避重试（仅幂等方法 + 408/429/5xx，尊重 `Retry-After` 封顶 60s）；`stream(for:)` 逐字节透传、非 2xx 透传错误 body（反向代理语义）；`streamThrowing(for:)` 非 2xx 抛 `ProviderError.upstreamError`（供 key 轮换等握手判断）。
- **SSEParser / SSEJSONAggregator**：跨 chunk 累积、空行切分事件；把强制流式上游的 SSE 聚合成 OpenAI 单 JSON（供 `stream=false` 客户端）。
- **HTTPServer + RouteHandler**（`Server/`）：手写 POSIX socket 服务器（poll 循环、每连接独立 Task、10s 读超时，无外部框架），分发 4 个端点：`GET /v1/health`、`GET /v1/models`、`POST /v1/chat/completions`、`GET /v1/usage`。`setHandler()` 支持运行时热替换 handler（GUI 热更新依赖此机制）。流式响应不设 Content-Length，靠连接关闭标识结束。
- **ConfigStore**（`Config/`）：读写 `~/.config/binvia/config.json`（`BINVIA_CONFIG` 覆盖），0600 权限，snake_case 编解码。凭据解析：config 优先，回退 `<PROVIDER>_API_KEY` / `<PROVIDER>_ACCESS_TOKEN` 等环境变量。未配置 `apiKeys` 时允许匿名访问（开发模式）。
- **APIKeyAuthenticator**（`Auth/`）：Bearer / x-api-key；恒有效 env key：`BINVIA_API_KEY` / `ROUTER_API_KEY` / `OMNIROUTE_API_KEY`。
- **RequestLogger**（`Monitoring/`）：内存日志上限 10k 条，按 provider/model 聚合用量，`/v1/usage` 输出。

## 上游流式差异（重要语义）

- DeepSeek 原生支持流式+非流式。
- CodeBuddy / Antigravity 上游**强制 `stream=true`**（非流式会被 400 拒绝），非流式客户端由 provider 内部用 `SSEJSONAggregator` 聚合（如 `CodeBuddyCNProvider.swift:104-119`）。新增 OAuth 类供应商必须遵循「强制流式上游 → 非流式客户端」模式。

## 多 api-key 轮换（DeepSeek 示例）

`DeepSeekProvider.chat` 对 keys 逐个尝试：用 `streamThrowing` 取首个数据块，**此阶段抛出的 401/403 视为握手失败才轮换**；已进入传输阶段后不再轮换。key 来源：config `providers.<id>.apiKeys` 数组 + 环境变量（`RouteConfig.apiKeys(for:)` 已去重过滤）。

## GUI（BinviaApp）

- `AppState`：`@MainActor` ObservableObject，持有 config、服务器生命周期、OAuth 流程（`CheckedContinuation` 桥接授权码输入 sheet）、网关 key（`sk-tg-` 前缀，SecRandomCopyBytes）、2s 轮询 metrics。
- 菜单栏：`MenuBarExtra(.window)`。**不注册 SwiftUI Settings 场景**（菜单栏应用中不可靠），设置窗口由 `SettingsWindowController` 自建 NSWindow + NSHostingController。
- 设置面板：`Views/Settings/`，CodexBar 风格左栏 + 详情。

# 测试（BinviaCheck）

- 极简断言（expectEqual / True / False / Nil / Throws），`run(name) {}` 分组，`Sources/BinviaCheck/main.swift` 末尾按序执行。
- 网络测试两种 mock：`URLProtocolMock`（URLSession 层，测重试策略）+ 本地真实 `HTTPServer` 当 mock 上游（测 DeepSeek 集成、SSE 透传/聚合）。
- **测试隔离**：入口把 `BINVIA_CONFIG` 指向 /tmp 路径并清理相关环境变量，避免读到本机真实配置/凭据。新增测试不得污染真实 config。

# 参考文档

`docs/` 收录本项目借鉴的两个上游工程的分析报告。**改动借鉴自上游的代码前，先读对应分析文档；分析不足时再查上游源码**（均在本机）：

- **CodexBar**（macOS 菜单栏 AI 用量监控，Swift）：本工程的 `ProviderDescriptor`/注册表、`ProviderHTTPClient`、`ConfigStore`、菜单栏 GUI 模式均借鉴自它。先读 `docs/codexbar-analysis.md`；必要时查源码：`/Users/wangbin/workspace/temp/my-token-route/CodexBar`。
- **OmniRoute**（AI 路由网关，TypeScript）：`provider/model` 路由语法、api-key 认证、SSE chat handler、供应商注册表，以及 CodeBuddy/Antigravity 的请求头与模型目录均来自它。先读 `docs/omniroute-analysis.md`；必要时查源码：`/Users/wangbin/workspace/temp/my-token-route/OmniRoute`。
- **GUI**：菜单栏应用、设置窗口、OAuth 流程、metrics 轮询的实现参考 `docs/gui-implementation-guide.md`。

# 环境与约定

- 代码注释与 README 均为中文，保持中文注释风格。
- 平台 macOS 14+，`swift-tools-version: 6.2`。
- **零外部依赖**：新增功能优先用 Foundation / AppKit 实现，不要轻易引入第三方包。
- 新增供应商：`Providers/` 下新建目录实现 Provider + 描述符，在 `ProviderCatalog.registerAll()` 加一行注册，同步更新 README 供应商表格。
