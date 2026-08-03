# Cursor 支持修复：规划与进度

> 目标：对齐 OmniRoute 的 Cursor 支持——修正模型目录（补 `cu/auto` 等）、添加账号（手动导入 token+machineId）、修复「密钥面板选不到模型」的判定。
>
> 状态：**已完成（含 P2 Agent RPC）**（2026-08 实测快照）
> 关联文档：`docs/omniroute-analysis.md`（上游实现分析）

---

## 1. 背景与问题

Binvia 的 Cursor 支持停留在 Phase 20 旧实现，对照 OmniRoute（`open-sse/config/providers/registry/cursor/index.ts` + `CursorAuthModal` + `services/cursor.ts`）存在三处缺口：

| # | 问题 | 根因 |
|---|---|---|
| 1 | **模型列表不正确，无 `cu/auto` / `cu/composer-*`** | 静态目录只有 16 个自编模型（`claude-4.5-sonnet`、`gpt-5.2`…），非 Cursor 真实 ID；且 IDE 模式 `listModels` 因「无 API key 短路」不返回目录 |
| 2 | **没有「添加账号」实现** | Cursor 注册为 `authType: .apiKey`，只有只读 IDE 探测（`CursorCredentialStore`），无手动导入 token+machineId 的多账号能力 |
| 3 | **密钥面板选不到对应模型** | `AppState.isProviderConfigured("cursor")` 走 `.apiKey` 分支，无 API key 时返回 false → 网关密钥面板/测试面板把 cursor 整体过滤掉 |

额外发现：Binvia 仍用 `StreamUnifiedChatWithTools` 私有端点，OmniRoute 已迁移到 `agent.v1.AgentService/Run`（旧端点拒绝 `auto`/`composer-*`）——此为 P2 独立大项，本次不涉及。

---

## 2. 约束

- 零第三方依赖（Swift 6.2、StrictConcurrency、4 空格缩进、中文注释）
- 不动现有 `StreamUnifiedChatWithTools` 协议
- 不破坏现有测试（`make test` 全绿）
- 模型目录直接同步 OmniRoute 官方注册表，不手抄

---

## 3. 风险

- 真实模型 ID 变更：旧目录 16 个中多数在新目录仍存在（`claude-4.5-sonnet`、`gpt-5.2`、`claude-sonnet-5-medium` 等），Router 解析兼容；仅显示名可能变化
- `GetDefaultModelNudgeData` 动态拉取 schema 未验证：OmniRoute 也未实际调用（靠 `cursor-agent --list-models` 同步静态目录）；本机无 cursor-agent → 采用静态目录方案
- 测试文件 `cu/` 前缀硬编码断言需同步

---

## 4. 切片规划（6 片，每片独立可验证）

| # | 切片 | 目标文件 | 验证 |
|---|---|---|---|
| 1 | 修正 Cursor 静态模型目录（同步官方 123 模型，`auto` 置首） | `CursorModels.swift`（新）、`CursorProvider.swift` | `swift build`；`make test` |
| 2 | IDE 模式动态拉模型（返回官方目录，绕过无 key 短路） | `CursorProvider.swift` | `make test`；listModels 打印 |
| 3 | `isProviderConfigured` 特判 cursor（IDE 检测=已配置） | `AppState.swift`、`CursorCredentialStore.swift` | `make test`；密钥面板出现 `cu/*` |
| 4 | 添加账号 UI（手动导入 token+machineId，多账号） | `SettingsProviderPane.swift`、`ChatModels.swift`、`AppState.swift` | `make test`；构建 |
| 5 | CLI 账号命令（`cursor add/list/remove`） | `BinviaCLI/main.swift` | `make test`；手动验证 |
| 6 | 回归 + 收尾（补测试、清真实配置） | `BinviaCheck/main.swift`、README | `make test` 全绿 |
| 7 | P2 Agent RPC（`auto` / `composer-*`） | `CursorHTTP2.swift`、`CursorAgentRPC.swift`、`CursorProvider.swift` | `swift build`；`make test`；真实网关 `cu/auto` 非流式/流式调用 |

> P2（不在本次范围）：升级 RPC 到 `agent.v1.AgentService/Run` 使 `auto`/`composer-*` 真正可用。切片 1-5 完成后它们能展示但不能调用。

---

## 5. 进度记录

### 切片 1 ✅ 模型目录修正
- 新建 `Sources/BinviaCore/Providers/Cursor/CursorModels.swift`：同步 OmniRoute 官方 123 个模型（`auto` / `composer-*` / gpt / claude / gemini / grok / kimi），`auto` 置首
- `CursorProviderDescriptor.models` 改为引用 `CursorModels.all`
- 验证：`swift build` 通过；`make test` 393 passed / 0 failed

### 切片 2 ✅ IDE 模式 listModels
- `CursorProvider.listModels` 显式覆盖：API key 模式走 `/v1/models` 动态获取（失败回退静态）；IDE 模式直接返回 `CursorModels.all`
- 绕过原 `fetchDynamicModels` 的「无 API key 短路」
- 验证：`swift build` + `make test` 通过

### 切片 3 ✅ isProviderConfigured 特判
- `AppState.isProviderConfigured` 增加 cursor 分支：`CursorCredentialStore.peekCachedIdentity()` 缓存命中（IDE 登录）或 config 存过 token → 已配置；未探测时异步 `refresh()` 后 `objectWillChange` 重算
- `CursorCredentialStore` 新增 `nonisolated(unsafe) peekCachedIdentity()`（仅读缓存，无竞态）
- 顺带修复既有 `withCString` 未使用告警
- 验证：构建 + `make test` 通过

### 切片 4 ✅ 添加账号 UI
- `ProviderCredential` 新增 `machineId` 字段（Cursor 专用，缺省 nil 兼容旧配置）
- `AppState` 新增 `CursorAccount` 结构 + `cursorAccounts(for:)` / `setCursorAccounts(_:for:)`：主账号 → `credential.accessToken/machineId`，其余 → `apiKeys[]`（machineId 编码进标签前缀 `mid:`）
- `SettingsProviderPane` 新增「手动导入账号」Section（token + machineId 输入、账号列表、移除）
- `CursorProvider.chat` 凭据优先级：手动导入账号 → API key → IDE 自动发现；手动账号非流式也走 `SSEJSONAggregator`
- 验证：构建 + `make test` 通过

### 切片 5 ✅ CLI 账号命令
- `BinviaCLI cursor add <token> [machineId]` / `cursor list` / `cursor remove`
- 与 `test` 命令一致用 `ConfigStore.load()` 默认路径
- 验证：`BINVIA_CONFIG` 隔离手动测试 add/list/remove 全部正常；真实配置已清理干净

### 切片 6 ✅ 回归 + 测试
- `BinviaCheck/main.swift` 新增：
  - `cursorModelsCatalogTests`：目录完整性（auto 置首、无重复、123 个、非空展示名、关键模型存在）
  - `cursorIDEModeTests` 追加：手动账号优先（Authorization 用 credential.accessToken、checksum 用 machineId）、listModels 返回完整目录
- 验证：**536 passed / 0 failed**（较基线新增 143 断言）；全 target `swift build` 通过；真实 `~/.config/binvia/config.json` 无 cursor 残留

---

## 6. 改动文件清单

| 文件 | 改动 |
|---|---|
| `Sources/BinviaCore/Providers/Cursor/CursorModels.swift` | **新增**：官方 123 模型目录 |
| `Sources/BinviaCore/Providers/Cursor/CursorProvider.swift` | 目录引用、`listModels` 覆盖、`chat` 账号优先 |
| `Sources/BinviaCore/Providers/Cursor/CursorCredentialStore.swift` | `peekCachedIdentity()`；`nonisolated(unsafe)` 缓存属性 |
| `Sources/BinviaCore/Provider/ChatModels.swift` | `ProviderCredential.machineId` |
| `Sources/BinviaApp/AppState.swift` | `isProviderConfigured` 特判；`CursorAccount` 存取 |
| `Sources/BinviaApp/Views/Settings/SettingsProviderPane.swift` | 「手动导入账号」Section |
| `Sources/BinviaCLI/main.swift` | `cursor add/list/remove` |
| `Sources/BinviaCheck/main.swift` | 新增/扩展测试 |

---

## 7. 验证结果汇总

- `swift build`：全 target 通过
- `swift run BinviaCheck`：536 passed / 0 failed
- `BinviaCLI cursor add/list/remove`：手动验证通过（`BINVIA_CONFIG` 隔离，真实配置干净）

---

## 8. 剩余风险 / 未验证项

1. ~~**P2（未做）**：升级 RPC 到 `agent.v1.AgentService/Run`（HTTP/2 双向流）使 `auto`/`composer-*` 真正可用。当前旧端点会拒绝这两个模型——**它们可展示但调用会失败**。~~
2. **`GetDefaultModelNudgeData` 动态拉取未实现**：OmniRoute 也未实际调用（靠 `cursor-agent --list-models` 同步）；本机无 cursor-agent，采用静态目录方案。装了 cursor-agent 后可补动态同步。
3. **GUI 未实机运行验证**：`swift build` 通过但未启动 App 肉眼看界面（无显示器环境）；逻辑与现有面板模式一致。
4. **旧配置模型 ID 兼容**：旧目录多数 ID 在新目录仍存在，Router 解析未破坏。

---

## 10. P2 实测诊断（2026-08 复现）

> 用户报告「cursor 发送测试后提示 error」。经网关实测复现 + 上游逐帧调试确认根因，并已通过 `agent.v1.AgentService/Run` 端点实验验证修复路径。

### 10.1 实测复现（旧端点 `StreamUnifiedChatWithTools`）

`curl POST /v1/chat/completions`（model=`cu/auto`）→ HTTP 200，但响应 content=`"Error"`。开启 `CURSOR_DEBUG=1` 后上游返回 JSON 错误帧：

```json
{"error":{"code":"not_found","message":"Error","details":[{"debug":{"error":"ERROR_BAD_MODEL_NAME","details":{"title":"AI Model Not Found","detail":"Model name is not valid: \"auto\""}}}]}}
```

命名模型（`claude-4.5-sonnet` / `gpt-5.2` / `gpt-5.5-low` 等）返回：

```json
{"error":{"code":"resource_exhausted","message":"Error","details":[{"debug":{"error":"ERROR_RATE_LIMITED_CHANGEABLE","details":{"title":"Named models unavailable","detail":"Free plans can only use Auto."}}}]}}
```

**根因**：账号为免费套餐 → 只能用 `auto`；但旧端点 `StreamUnifiedChatWithTools` **不认识 `auto`**（`ERROR_BAD_MODEL_NAME`）。死循环 → 无任何模型可用。

### 10.2 新端点实验验证（`agent.v1.AgentService/Run`）

用 Node `node:http2` 直接调用 `https://agentn.global.api5.cursor.sh/agent.v1.AgentService/Run`（Connect-RPC 双向流）：

| 发现 | 细节 |
|---|---|
| **`auto` 免费可用** | model `auto` → 需翻译为 `default`（`RequestedModel.model_id="default"`）；免费套餐正常返回 `PONG` |
| **命名模型正确拒绝** | `claude-4.5-sonnet` → `Free plans can only use Auto`（错误信息清晰） |
| **版本头必须用 CLI 格式** | `x-cursor-client-version: cli-2026.07.08-0c04a8a`（OmniRoute 同步的最新 CLI build）；IDE 格式 `1.1.3`/`3.2.14` → `Update Required` 拒绝 |
| **双向握手硬性要求** | 服务器发 `request_context`（ExecServerMessage variant 10）后**挂起等 ack**；必须同流回 `ExecClientMessage.request_context_result`。单向 `END_STREAM` 不行（12s 无响应） |
| **KV 通道** | 服务器发 `kv_server_message` 保存对话（`set_blob`），无需应答；只有发 system-prompt blob 时才有 `get_blob` |
| **请求头集** | 无 `x-cursor-checksum` / `machineId` / `x-amzn-trace-id`（与旧端点不同）；需要 `traceparent` / `backend-traceparent` / `x-request-id` / `x-original-request-id` |
| **文本帧结构** | `AgentServerMessage.interaction_update(1)` → `InteractionUpdate.text_delta(1)` → `TextDeltaUpdate.text(1)`；thinking 在 field 4；`turn_ended`=14 |
| **结束信号** | Connect-RPC `{}` JSON 帧（flags 0x02/0x03） |

**关键差异 vs 旧端点**：新端点不接受 `auto` 字面量，需翻译为 `default`；模型 ID 带 effort 后缀（`claude-opus-4-8-high`）需拆成 `RequestedModel{model_id: "claude-opus-4-8", parameters: [{id:"effort", value:"high"}]}`。

### 10.3 实现与验证（Swift 侧）

新端点**必须双向 HTTP/2**（同流回 ack）。Binvia 现有能力盘点：

| 方案 | 可行性 |
|---|---|
| `URLSession` | ✗ 仅 HTTP/1.1，无双向流；无法暴露 h2 |
| `Network.framework`（NWConnection） | ✅ 可用：TLS/ALPN 由 `NWConnection` 自动协商 h2，HTTP/2 帧层由 Binvia 自实现 |
| 系统 `libcurl` | ⚠️ dylib 存在但无 Swift module；h2 双向流 API 不友好 |
| **NWConnection + 最小 HTTP/2 帧层** | ✅ 零依赖；实现连接前奏、SETTINGS、HEADERS、DATA、PING、WINDOW_UPDATE，HPACK 请求头使用静态表 |

**实现状态**：已完成。新增 `CursorHTTP2.swift` + `CursorAgentRPC.swift`；`NWConnection` 负责 TLS 双向传输，Binvia 负责 HTTP/2/Connect-RPC 帧和 request_context/KV 回写。默认 IDE 模式切换至 `agent.v1.AgentService/Run`；`CURSOR_BASE_URL` 存在时保留旧 URLSession 协议，仅用于 URLProtocol mock/镜像兼容。
