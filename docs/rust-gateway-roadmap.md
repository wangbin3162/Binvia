# Rust 网关后续路线图（Roadmap）

> **铁律**：Web + Rust 完成（本路线图 R1–R12 全部通过验收）之前，**禁止修改 `Sources/` 下任何 macOS app 代码**（BinviaCore / BinviaServer / BinviaCLI / BinviaApp / BinviaCheck）。`Sources/` 仅作为移植参考**只读**使用；确有必要改动须先征得用户明确同意。详见 `AGENTS.md`「Important Constraint」。

> 制定日期：2026-08-05
> 范围：`binvia-core/`（Rust 网关）+ `web/`（管理面板）在 S1-S5 之后的剩余工作。
> 参考：`docs/web-panel-plan.md`（S1-S5 已完成）、`docs/rust-gateway-build.md`（构建与运行）。
> 对齐基线：macOS 版 `Sources/BinviaCore`（Swift）。本路线图只列 **尚未落地** 的能力。

---

## 1. 当前完成度速览

| 能力 | Swift（Sources/BinviaCore） | Rust（binvia-core） |
|---|---|---|
| /v1 网关（chat/models/usage/health） | ✅ | ✅ |
| admin API 全量 + 认证 + 凭据掩码 + 热更新 | ✅ | ✅ |
| 13 个 Provider 目录注册 | ✅ | ✅ |
| codebuddy-cn 专用 headers + force-stream SSE 聚合 | ✅ | ✅ |
| 请求日志 + Token 统计 | ✅ | ✅ |
| Web 面板（概览/Provider/日志/Keys/设置） | ✅（GUI） | ✅ |
| 真实 Provider 用量查询 | ✅ 8 个 UsageFetcher | ❌ 空快照 |
| Anthropic 兼容翻译（zai/minimax） | ✅ | ❌ 目录占位 |
| Codex / Cursor 专用协议 | ✅ | ❌ 目录占位 |
| OAuth 登录（device flow / OAuth） | ✅ | ❌ 仅手填 token |
| 上游模型缓存（ModelCache） | ✅ | ❌ 只读 catalog |
| HTTP 重试策略 | ✅ | ❌ 仅 429 映射 |
| 集成测试（本地 mock 服务器） | ✅ | ⚠️ 仅 12 个单测 |

---

## 2. 剩余切片

### R1 — 真实 Provider 用量查询（服务端，最高优先）

- **目标**：`POST /admin/api/usage/refresh` 真正抓取各 Provider 余额/配额，填充 `monitor/usage_cache.rs` 的 `ProviderUsageSnapshot`；`/v1/usage` 语义保持 token 统计不变。
- **Swift 参考**：`Sources/BinviaCore/Networking/Usage/*UsageFetcher.swift`（DeepSeek/CodeBuddyCn/Antigravity/Codex/Cursor/Kimi/OpenCodeGo）+ `UsageCache.swift`。
- **实现要点**：
  - 新增 `usage/fetcher.rs`：按 provider 分发的 `UsageFetcher` trait（async），DeepSeek 余额（`GET /user/balance`）、CodeBuddy 用量面板接口等。
  - `refresh_handler` 并发抓取（`futures::stream`），失败写 `snapshot.error` 不阻断整体。
  - 抓取周期建议 5min 缓存 + 手动刷新（对齐 web-panel-plan §8 刷新节奏）。
- **验证**：配置真实 key 后 `curl -X POST /admin/api/usage/refresh` 返回非空 balance/quota；`cargo test` 新增 fetcher mock 用例。

### R2 — Anthropic 兼容翻译层（服务端）

- **目标**：zai / minimax 可真实对话。当前它们被注册为 OpenAI 兼容并 POST 到 `/api/anthropic/v1/messages`，格式不符必失败；连接测试返回"不支持专用协议"。
- **Swift 参考**：`AnthropicCompatChatExecutor.swift` + `AnthropicEnvelopeTranslator.swift`。
- **实现要点**：
  - 新增 `gateway/anthropic.rs`：OpenAI ChatRequest ↔ Anthropic messages 信封互转（system/assistant 映射、`max_tokens`、SSE 事件 `content_block_delta` 转 OpenAI chunk）。
  - `ProviderDescriptor` 增加 `anthropic_compat: bool`（或按 base_url 后缀 `/messages` 判定），`chat.rs` 分发时走翻译路径。
- **验证**：`curl /v1/chat/completions -d '{"model":"zai/glm-5.2",...}'` 流式+非流式均返回；catalog 测试更新 `unsupported_protocol_message`。

### R3 — Codex 专用协议（服务端）

- **目标**：codex 真实可用（OAuth token → ChatGPT 后端 `responses` API + SSE）。
- **Swift 参考**：`CodexProvider.swift` + `CodexOAuthClient.swift` + `CodexResponsesTranslator.swift`。
- **实现要点**：认证（chatgpt.com session/oauth）、`/backend-api/codex/responses` SSE 协议、模型名映射（gpt-5.6-sol 等）。
- **验证**：带有效 token 的端到端 curl；失败降级为清晰错误。

### R4 — Cursor 专用协议（服务端）

- **目标**：cursor 真实可用（Agent RPC / HTTP2 通道）。
- **Swift 参考**：`CursorAgentRPC.swift` + `CursorHTTP2.swift` + `CursorRPC.swift` + `CursorCredentialStore.swift`。
- **实现要点**：凭据（machine_id/workspace_id）、RPC 消息封装、SSE 翻译。
- **验证**：同上。

### R5 — OAuth 登录（服务端 + admin API）

- **目标**：面板/CLI 可发起 CodeBuddy device flow、Antigravity OAuth 登录并保存 token，替代手填。
- **Swift 参考**：`CodeBuddyOAuthClient.swift`、`AntigravityOAuthClient.swift`、GUI `OAuthLoginButton` / `CodeInputSheet`。
- **实现要点**：
  - admin API 新增：`POST /admin/api/providers/{id}/oauth/start`（返回 device_code/验证 URL）、`POST /admin/api/providers/{id}/oauth/poll`（轮询 → 存 `ProviderCredential` + 热更新）。
  - CLI 可复用同一端点（`BinviaCLI oauth` 对齐）。
- **验证**：mock 设备端点全流程测试；真实 CodeBuddy 人工验证一次。

### R6 — 上游模型缓存（服务端，可选）

- **目标**：`/v1/models` 对已配置 provider 拉取上游真实模型列表并缓存（TTL），未配置时回退 catalog。
- **Swift 参考**：`ModelCache.swift`。
- **实现要点**：`gateway/models.rs` 增加异步拉取 + 缓存；注意 `enabled/disabled_models` 过滤仍生效。
- **验证**：配置真实 key 后 `/v1/models` 包含上游模型；mock 上游断言缓存命中。

### R7 — HTTP 重试策略（服务端）

- **目标**：可重试状态码（408/429/500/502/503/504）按 Retry-After/指数退避重试，默认 1-2 次。
- **Swift 参考**：`ProviderHTTPClient.swift`（`ProviderHTTPRetryPolicy`）。
- **实现要点**：`OpenAICompatibleProvider.send_chat` 外层重试循环；429 尊重 `Retry-After` 头；流式请求不重试。
- **验证**：mock 上游连续 429 后成功；重试上限后返回 502。

### R8 — Web 用量卡片展示（前端）

- **目标**：ProvidersView 渲染余额/配额/模型限额卡片（对齐 Swift `ProviderUsageCard`）。
- **前置**：R1（当前 snapshots 为空，无数据可画）。
- **实现要点**：`SnapshotsResponse` 类型已有；按 `balance`/`quotaWindows`/`modelQuotas` 分组渲染 + 刷新按钮。
- **验证**：`make rust-release` 产物 + 浏览器人工走查。

### R9 — Web OAuth 登录交互（前端）

- **目标**：ProvidersView 内嵌 OAuth 按钮（跳转/弹窗）+ device flow 验证码输入（对齐 `OAuthLoginButton`/`CodeInputSheet`）。
- **前置**：R5。
- **验证**：真实登录一次 + 登录态展示（已登录/过期）。

### R10 — About / 版本检查（前端，可选）

- **目标**：设置页 About 块 + 版本检查（对齐 Swift `SettingsAboutPane` + `UpdateChecker`）。
- **实现要点**：读 `overview.version` + 远端 release 检查（网关新增或前端直连 GitHub API）。
- **验证**：显示当前版本与最新版本。

### R11 — 集成测试补齐（工程）

- **目标**：Rust 侧补本地 mock 上游集成测试（对齐 Swift：`URLProtocolMock` + 真实本地 `HTTPServer` mock）。
- **覆盖**：SSE 流式端到端、force-stream 聚合、认证三态、admin 热更新、凭据掩码、key 白名单。
- **实现要点**：用 `axum`/`tokio::net::TcpListener` 起临时 mock 上游（测试内起服务，非新依赖）；沿用现有 `run()` 断言风格。
- **验证**：`make rust-test` 全绿。

### R12 — npm / 分发形态（远期，可选）

- **目标**：`npm i -g binvia` 直接启动（下载器 + 启动器模式）。
- **参考**：`docs/web-panel-plan.md` §13（原为 Swift 二进制设计，Rust 版产出 `bin/binvia` 同理适用）。
- **验证**：npm 包安装后 `binvia` 启动 + 打开面板。

---

## 3. 建议推进顺序

```
R1（用量抓取）→ R8（用量卡片）→ R2（Anthropic 翻译）→ R7（重试）
→ R3/R4（codex/cursor）→ R5+R9（OAuth 闭环）→ R11（测试贯穿每步）
可选：R6（模型缓存）、R10（About）、R12（npm 分发）
```

理由：R1 解锁 web 核心价值（用量监控）；R2 成本低收益大（解锁 2 个 provider）；R7 提升稳定性；R3/R4 依赖 OAuth（R5），可合并推进；R11 建议随每步增量补充。

## 4. 完成验收标准

1. `make rust-test` 全绿（含每步新增用例）。
2. 配置真实 key 后：`usage/refresh` 返回真实余额/配额，面板用量卡片有数据。
3. zai / minimax / codex / cursor 连接测试与对话均真实可用（不再返回"不支持专用协议"）。
4. 面板可完成 CodeBuddy / Antigravity OAuth 登录闭环。
5. `make rust-release` 产物单文件运行，`/v1/*` 与 `/admin/*` 无回归。
