# Binvia 二期完成报告

> 完成日期：2026-08-01
> 范围：`docs/phase2-plan.md` 全部 7 个 Phase（12–18）
> 验收：`swift build` 无警告、`make test`（BinviaCheck）277 项全过、`swift run BinviaApp --smoke-test` 全过

---

## 1. 交付概况

二期 10 项需求全部落地，供应商矩阵从 3 家扩展到 **11 家**，测试从 96 项扩展到 **277 项**（+181）。

| # | 需求 | 状态 | 说明 |
|---|---|---|---|
| 1 | 测试全部模型按钮 | ✅ | 供应商卡片「测试全部模型」串行执行 + 进度条 + 实时结果 |
| 2 | 模型启停配置 + 前缀路由 | ✅ | 每 gateway key 独立 `enabledModels` 白名单（403 过滤）；Router 消歧升级为反向索引 + 单候选直选 + 前缀启发式 |
| 3 | DeepSeek 用量显示 | ✅ | `GET /user/balance` → 余额卡片 |
| 4 | Antigravity 用量显示 | ✅ | `retrieveUserQuota` + `retrieveUserQuotaSummary` 双 RPC → 模型配额/周窗口 |
| 5 | CodeBuddy-CN 用量显示 | ⏸️ **暂缓** | 需逆向网页存储 schema（见 §5 后续事项） |
| 6 | 网关密钥前缀改 `sk-bv-` | ✅ | 新生成 `sk-bv-`，旧 `sk-tg-` 仍可鉴权 |
| 7 | 动态模型列表 | ✅ | 所有供应商统一 `ModelCache → modelsURL → 静态兜底` |
| 8 | 接入 OpenAI | ✅ | `api.openai.com/v1`，流式 + 非流式，`/v1/models` 动态 |
| 9 | 接入 7 家新供应商 | ✅ | openai / opencode / kimi / opencode-go / z.ai / minimax / xiaomi-mimo / qwen-cloud（共 8 家） |
| 10 | codexbar 风格用量展示 | ✅ | 有则展示无则隐藏：DeepSeek / Antigravity / Kimi 有卡片，其余隐藏 |

---

## 2. 各 Phase 交付明细

### Phase 12 — 路由与配置升级（基础）
- `ProviderDescriptor` 新增 `modelsURL` / `forceStream` / `usageFetcherFactory` 字段（`ProviderUsageFetcher` 协议 + `ProviderUsageSnapshot` 等类型建在 `Networking/Usage/ProviderUsageFetcher.swift`）。
- `ProviderRegistry` 构建 `MODEL_TO_PROVIDERS` 反向索引（`providers(forModel:)`）。
- `Router` 消歧升级为 4 段：显式前缀 → 单候选直选 → 前缀启发式（`claude-*`/`gemini-*`→antigravity、`gpt-*`→openai、`glm-*`→codebuddy-cn、`deepseek-*`→deepseek、`kimi-*`→kimi、`qwen*`→qwen-cloud 等）→ 前缀优先 + 字母序兜底。
- `RouteConfig.apiKeys` 由 `[String]` 升级为 `[GatewayKeyConfig]`（含 `enabledModels: [String]?`），解码兼容 v1 字符串数组；`ConfigStore` version 升至 2，加载时自动迁移并备份 `config.json.v1.bak`。
- `RouteHandler` 新增网关 key 级 `enabledModels` 过滤（chat 返回 403；`/v1/models` 只返回白名单内模型）。
- GUI：`SettingsGatewayKeysPane` 每个 key 可编辑模型白名单。

### Phase 13 — 供应商级测试 + 动态模型扩展
- `Provider.testAllModels` 默认实现（listModels → 逐个 testModel → `ModelTestOutcome` 汇总，单模型失败不中断）。
- `Provider.listModels` 默认实现 `ModelCache → modelsURL → 静态兜底`（`fetchDynamicModels` 共享助手，支持 `<PROVIDER>_BASE_URL` 环境变量覆盖以便测试/自建上游）。
- Antigravity 接入 `ModelCache`。
- GUI：`SettingsProviderPane` 「测试全部模型」按钮 + 进度条 + 结果列表。

### Phase 14/15 — OpenAI / opencode / kimi
- `Providers/OpenAI/`：标准 OpenAI 兼容（单 key，`rawBody` 透传，`stream` 原样转发）。
- `Providers/OpenCode/`：alias `oc`，`modelsURL` 动态为主。
- `Providers/Kimi/`：`forceStream=true`，非流式客户端用 `SSEJSONAggregator` 聚合（复刻 CodeBuddyCN 模式）。

### Phase 16 — 用量查询框架
- `UsageCache` actor（5min TTL）。
- `DeepSeekUsageFetcher`：`GET {base}/user/balance`，解析 `balance_infos[]`（余额 + 币种）。
- `AntigravityUsageFetcher`：复用 OAuth 凭据，`retrieveUserQuota` → 模型级配额；`retrieveUserQuotaSummary` → 周窗口配额（best-effort）。
- `AppState` 新增 `usageSnapshots` + 5min 轮询 + `refreshUsageNow`；`SettingsProviderPane` 新增「用量」Section（余额卡 / 配额进度条 / 模型配额，失败显示错误 + 刷新按钮）。

### Phase 17 — 网关密钥前缀迁移
- `generateAPIKey()` 前缀 `sk-tg-` → `sk-bv-`；旧 key 向后兼容（鉴权只认配置内容，不校验前缀）；smoke test 断言更新。

### Phase 18 — 第二批供应商 + Anthropic 信封翻译
- `AnthropicEnvelopeTranslator`（纯函数）：OpenAI `ChatRequest` → Anthropic `/v1/messages`（`system` 提取、`max_tokens` 默认 4096、role 映射、`stream` 透传）；Anthropic SSE → OpenAI SSE（`content_block_delta.text` → `delta.content`，`message_delta.stop_reason` → `finish_reason`，`[DONE]` 收尾）。
- `AnthropicCompatChatExecutor` 复用 z.ai / minimax 的聊天粘合逻辑（恒 `stream:true` 上游 + 非流式客户端聚合）。
- 新增 5 家：opencode-go（`ocgo`）、xiaomi-mimo（`mimo`）、qwen-cloud（`qwc`）、zai（`zai`，Anthropic）、minimax（`mm`，Anthropic）。
- `KimiUsageFetcher`：`GET /v1/users/me/balance` → 余额卡片。

---

## 3. 关键文件地图

```
Sources/BinviaCore/
├── Provider/ProviderDescriptor.swift        # modelsURL / forceStream / usageFetcherFactory
├── Provider/Provider.swift                  # testAllModels / listModels 默认实现 / fetchDynamicModels
├── Provider/ProviderRegistry.swift          # 反向索引 providers(forModel:)
├── Router/Router.swift                      # 4 段消歧
├── Config/RouteConfig.swift                 # GatewayKeyConfig + v1/v2 双格式解码
├── Config/ConfigStore.swift                 # v1→v2 迁移 + .v1.bak 备份
├── Auth/APIKeyAuthenticator.swift           # matchedKey 返回命中 key
├── Server/RouteHandler.swift                # enabledModels 403 过滤
├── Networking/Usage/                        # ProviderUsageFetcher / UsageCache / 各 fetcher
└── Providers/
    ├── OpenAI|OpenCode|Kimi|OpenCodeGo|XiaomiMimo|QwenCloud|Zai|MiniMax/
    ├── Anthropic/AnthropicEnvelopeTranslator.swift
    └── ProviderCatalog.swift                # 11 家注册
```

---

## 4. 如何验证

### 4.1 自动化验证（三件套）
```bash
cd /Users/wangbin/workspace/temp/my-token-route/Binvia

# 1. 编译：应无警告无错误
swift build

# 2. 全部测试：应输出 passed=277, failed=0
make test          # = swift run BinviaCheck

# 3. GUI 无界面自检：应 ALL PASSED
swift run BinviaApp --smoke-test
```

### 4.2 手动验证（GUI）
```bash
swift run BinviaApp
```
1. **设置 → 网关密钥**：点「生成新 Key」，确认前缀为 `sk-bv-`；展开该 key 的「模型白名单」，填入一行 `ds/deepseek-v4-pro` 并应用。
2. **设置 → 供应商**：确认 11 家供应商都在侧栏；每家都可用 API Key 配置（apiKey 型）或 OAuth（codebuddy-cn / antigravity）。
3. 任一供应商面板点「测试全部模型」：应串行执行并显示进度条 + 逐模型结果。
4. **用量卡片**：DeepSeek 配置 API Key 后、Antigravity OAuth 登录后，设置面板应出现「用量」Section（DeepSeek 余额卡 / Antigravity 配额进度条）；OpenAI 等无用量 API 的供应商不显示。

### 4.3 网关 API 手动验证
```bash
# 启动服务器（指定临时配置）
BINVIA_CONFIG=/tmp/bv-demo.json swift run BinviaCLI serve --port 8231
# 或 GUI 里开启服务器

# 生成两个 key：一个无白名单，一个只放行 ds/deepseek-v4-flash
# 编辑 /tmp/bv-demo.json（apiKeys 为对象数组，version=2）：
# {
#   "version": 2,
#   "host": "127.0.0.1", "port": 8231,
#   "apiKeys": [
#     { "key": "sk-bv-open", "enabled_models": null },
#     { "key": "sk-bv-narrow", "enabled_models": ["ds/deepseek-v4-flash"] }
#   ]
# }

# 白名单外模型 → 403
curl -s http://127.0.0.1:8231/v1/chat/completions \
  -H "Authorization: Bearer sk-bv-narrow" \
  -H "Content-Type: application/json" \
  -d '{"model":"ds/deepseek-v4-pro","messages":[{"role":"user","content":"hi"}]}'
# → {"error":"Model ds/deepseek-v4-pro is not enabled for this gateway key"}

# 白名单内模型 → 进入上游（无上游凭据时 502，而非 403）
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8231/v1/chat/completions \
  -H "Authorization: Bearer sk-bv-narrow" \
  -H "Content-Type: application/json" \
  -d '{"model":"ds/deepseek-v4-flash","messages":[{"role":"user","content":"hi"}]}'

# 无白名单 key → 全部放行；/v1/models 按白名单过滤
curl -s http://127.0.0.1:8231/v1/models -H "Authorization: Bearer sk-bv-narrow" | jq '.data[].id'

# v1 配置自动迁移：放一个旧格式 config（apiKeys 是字符串数组）再加载，
# 应生成 config.json.v1.bak 且 apiKeys 变为对象数组
```

### 4.4 CLI
```bash
swift run BinviaCLI providers list     # 应列出 11 家
swift run BinviaCLI test deepseek      # 供应商连通性测试
```

---

## 5. 后续任务事项（follow-up）

1. **CodeBuddy-CN 用量查询（需求 5，最高优先）** — 二期暂缓。需要在线环境逆向 CodeBuddy 网页登录后的存储 schema（cookie / localStorage / IndexedDB），参照 CodexBar `DeepSeekPlatformTokenImporter` 实现 `CodeBuddyCNTokenImporter`；若不可行则回退方案 B（手动导入 cookie 到 config，UI 标注「实验性」）。前置：可在设置面板先提供「手动粘贴 cookie」入口。
2. **Kimi 余额接口复核** — `GET /v1/users/me/balance` 为参考实现，需用真实 Moonshot key 验证响应结构与字段（`data[0].available_balance`）；若结构不符，调整 `KimiUsageFetcher` 解析。
3. **z.ai / minimax 真实上游验证** — Anthropic 信封翻译按 OmniRoute 约定实现，需用真实 key 验证 `?beta=true` 后缀、`anthropic-version` 头、以及流式/非流式聚合的端到端行为。
4. **GUI 用量卡片补充** — CodeBuddy-CN / Kimi / MiniMax 的用量卡片（Kimi 已实现 fetcher，需接 GUI 刷新链路确认）；「用量」Section 的刷新按钮已实现，可补充自动刷新失败重试的 UI 状态。
5. **README 配置示例** — 二期只同步了供应商表格；`README` 中 `apiKeys` 示例应更新为 v2 对象数组（含 `enabledModels`），并补充 `sk-bv-` 前缀说明。
6. **打包回归** — 跑 `make release`（release 构建 + 自检 + 拷贝到 `bin/`），确认 `bin/Binvia.app` / `bin/BinviaServer` / `bin/BinviaCLI` 生成正常。
7. **测试稳定性备忘** — 本仓库存在「本地 HTTPServer mock + URLSession」偶发崩溃（`Fatal error: Not enough bits to represent the passed value`，`Swift/arm64e-apple-macos.swiftinterface:13152`，与业务代码无关）。新增网络测试时优先用 `URLProtocol.registerClass(URLProtocolMock.self)`，避免真实 socket mock。
8. **CI/发布** — 二期未引入 CI；如需，把 `make test` + `swift run BinviaApp --smoke-test` 接入 CI（注意本机无 Xcode，用 CommandLineTools 即可）。
