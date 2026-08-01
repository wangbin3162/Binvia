# Binvia 二期开发计划书

> 制定日期：2026-08-01
> 目标：在 Binvia 一期（DeepSeek / CodeBuddyCN / Antigravity 三供应商 + 菜单栏 GUI）基础上，扩展供应商矩阵、引入模型级启停配置、完善用量监控、增强测试与可观测性。
> 一期背景见：[implementation-plan.md](implementation-plan.md)、[task.md](task.md)、[codexbar-analysis.md](codexbar-analysis.md)、[omniroute-analysis.md](omniroute-analysis.md)、[gui-implementation-guide.md](gui-implementation-guide.md)。

---

## 1. 背景与目标

一期已交付一个可用的本地聚合路由网关：3 个供应商端到端打通、菜单栏 GUI、96 项自检用例、零外部依赖。但仍有以下缺口：

- **供应商矩阵单薄**：仅 3 家，主流厂商（OpenAI / Kimi / Qwen / MiniMax 等）缺失。
- **模型目录半静态**：CodeBuddyCN 仅静态目录，Antigravity 动态获取不写缓存，新供应商的动态发现未抽象。
- **无模型级启停**：供应商接入后所有模型默认暴露，无法按 gateway key 细分可见模型。
- **无上游用量/余额**：`/v1/usage` 仅本地请求日志，无供应商侧余额、配额查询。
- **测试粒度粗**：模型测试需逐个点击，无「该供应商全部模型」批量测试入口。

二期目标对应这五项缺口逐一闭环，并保持一期的「零外部依赖、StrictConcurrency、自包含测试」三大约束。

---

## 2. 工程现状分析

### 2.1 Binvia 现状

| 模块 | 现状 | 二期可复用度 |
|---|---|---|
| `ProviderDescriptor` / `ProviderRegistry` | alias 前缀路由 + 静态 models | 高，需扩展 `modelsURL` 可选字段与 `usageFetcher` 工厂 |
| `Router` | `provider/model`、`alias/model`、裸模型名（前缀优先 + 字母序） | 中，需升级消歧为 OmniRoute 风格（反向索引 + 单候选直选） |
| `ModelCache` | 300s TTL，仅 DeepSeek 使用 | 高，需推广到所有支持动态获取的供应商 |
| `ProviderHTTPClient` | `data` / `stream` / `streamThrowing` + 重试策略 | 高，用量查询直接复用 |
| `RouteHandler` | 4 端点，`/v1/models` 已合并动态+静态 | 中，需接入启停过滤、用量端点扩展 |
| `ConfigStore` | `~/.config/binvia/config.json`，snake_case | 高，需扩展 `providers.<id>.enabledModels` 与 gateway key 级覆盖 |
| `RequestLogger` | 内存日志 + 按供应商/模型聚合 | 高，用量展示可叠加 |
| `SettingsProviderPane` | 每模型独立测试按钮 | 中，需在头部新增「测试全部模型」按钮 |
| `SettingsGatewayKeysPane` | 顶层 `apiKeys` 数组 | 中，需扩展每 key 的 `enabledModels` 字段 |

### 2.2 三个供应商的接入方式

| 供应商 | 认证 | 模型来源 | 用量查询现状 |
|---|---|---|---|
| DeepSeek（`ds`） | API Key（多 key 轮换） | 静态 + 上游 `/models`（ModelCache） | 无 |
| CodeBuddyCN（`cbcn`） | OAuth 设备码 | 仅静态 15 个 | 无 |
| Antigravity（`agy`） | OAuth PKCE | `:fetchAvailableModels` 动态（不写缓存） | 无 |

### 2.3 参考工程可借鉴点

**OmniRoute**（[omniroute-analysis.md](omniroute-analysis.md)）：
- 180 供应商注册表，`RegistryEntry.forceStream` / `alternateFormats` / `modelsUrl` 字段可补到 `ProviderDescriptor`。
- `parseModel` 反向索引 + 前缀启发式消歧比 Binvia 当前更精细。
- Antigravity 用量查询：`cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` + `:retrieveUserQuotaSummary` 双 RPC，分 5h / 周窗口。
- 新供应商端点与认证方式（OpenAI / Kimi / MiniMax / Qwen / opencode / z.ai / xiaomi-mimo）均有现成实现。
- OpenAI 无用量查询实现。

**CodexBar**（[codexbar-analysis.md](codexbar-analysis.md)）：
- DeepSeek 余额查询：`GET https://api.deepseek.com/user/balance`（Bearer），返回 `balance_infos[].{currency, total_balance, granted_balance, topped_up_balance}`。
- Antigravity 用量查询：远程 OAuth 路径（与 OmniRoute 同源）+ 本地端口探测（Binvia 作为网关可跳过本地探测）。
- 自适应轮询分档（recentInteraction 2min / warm 5min / idle 15min / longIdle 30min），Binvia 当前 2s 固定轮询已可用，可后期参考。
- **不支持 CodeBuddy-CN**，无网页登录抓取现成实现。
- **不实现动态模型列表**（只读监控工具）。

---

## 3. 需求清单与对齐决策

二期共 10 项需求。已通过 grilling 与产品方对齐的关键决策如下表（✅ = 已对齐）：

| # | 需求 | 对齐决策 | 风险 |
|---|---|---|---|
| 1 | 测试全部模型按钮 | ✅ **供应商级别**：每个供应商卡片旁加按钮，**串行**测试该供应商所有模型，进度条实时反馈 | 低 |
| 2 | 模型启停配置 + 前缀路由 | ✅ **每 gateway key 独立白名单**（key.enabledModels），顶层默认 null=全部启用；✅ 路由策略 A：默认带前缀 + 裸名兼容，消歧升级为 OmniRoute 风格（反向索引 + 单候选直选 + 前缀启发式） | 中 |
| 3 | DeepSeek 用量显示 | ✅ **仅 API Key 通道**：`GET /user/balance` 查余额；使用量走 Binvia 自身 `RequestLogger` | 低 |
| 4 | Antigravity 用量显示 | ✅ 复用远程 OAuth 凭据，调 `retrieveUserQuota` + `retrieveUserQuotaSummary` 双 RPC | 低（OmniRoute 有现成实现） |
| 5 | CodeBuddy-CN 用量显示 | ✅ **浏览器自动导入**：参考 CodexBar `DeepSeekPlatformTokenImporter` 模式，从 Chrome localStorage 读取登录 token | **高**（无现成实现，需逆向 CodeBuddy 网页存储 schema） |
| 6 | 网关密钥前缀改 `sk-bv-` | ✅ 简单替换，向后兼容（旧 `sk-tg-` key 仍可读，新生成用 `sk-bv-`） | 低 |
| 7 | 动态模型列表（自动生成） | ✅ **所有供应商动态获取**，无上游 `/models` 接口的回退静态目录 | 中 |
| 8 | 接入 OpenAI | ✅ **基础接入**：`api.openai.com/v1`，流式 + 非流式，`/v1/models` 动态目录；不实现 `/v1/responses` 端点 | 低 |
| 9 | 接入 7 家新供应商 | ✅ **分批小步快跑**：第一批 OpenAI + opencode + kimi；第二批 z.ai + minimax + xiaomi-mimo + qwen + opencode-go | 中 |
| 10 | codexbar 风格用量展示 | ✅ **有则展示无则隐藏**：DeepSeek / Antigravity / CodeBuddy-CN / Kimi / MiniMax 等支持；OpenAI / z.ai / opencode 无公开 API 则不展示该卡片 | 低 |

### 关键决策说明

**前缀路由（需求 2）**：保持向后兼容是核心约束——现有 Claude Code / Codex 客户端的 model 字段无需改动。新增 8 家供应商后，裸模型名消歧通过反向索引 + 单候选直选 + 前缀启发式（如 `claude-*` → Anthropic 系、`gemini-*` → Gemini 系、`gpt-*` → OpenAI 系）保证可用性。

**每 gateway key 独立白名单（需求 2）**：
```jsonc
{
  "apiKeys": [
    { "key": "sk-bv-xxxx", "enabledModels": null },          // null = 全部启用（默认）
    { "key": "sk-bv-yyyy", "enabledModels": ["ds/deepseek-v4-flash", "cbcn/glm-4.6", "agy/claude-sonnet-4.6"] }
  ]
}
```
路由阶段：解析 model → 鉴权 gateway key → 若该 key 有 `enabledModels` 白名单且模型不在其中，返回 403。

**CodeBuddy-CN 用量查询（需求 5，高风险）**：CodexBar / OmniRoute 均无实现。二期采用浏览器自动导入方案，但需先抓包分析 CodeBuddy 网页登录后的存储 schema（cookie / localStorage / IndexedDB）。若分析后无可用入口，回退方案为 B（手动导入 cookie）。

---

## 4. 架构设计

### 4.1 ProviderDescriptor 扩展

```swift
public struct ProviderDescriptor: Sendable {
    // 既有字段
    public let metadata: ProviderMetadata
    public let baseURL: URL
    public let models: [Model]                    // 静态目录（兜底）
    public let supportsStreaming: Bool
    public let makeProvider: @Sendable () -> any Provider

    // 二期新增
    public let modelsURL: URL?                   // 动态模型列表端点（null=仅静态）
    public let forceStream: Bool                 // 上游是否强制 stream=true（CodeBuddyCN/Kimi）
    public let usageFetcherFactory: @Sendable () -> any ProviderUsageFetcher?  // 用量查询器
}

public protocol ProviderUsageFetcher: Sendable {
    func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot
}

public struct ProviderUsageSnapshot: Sendable {
    public let balance: Decimal?                 // 余额（DeepSeek）
    public let quotaWindows: [QuotaWindow]       // 配额窗口（Antigravity 5h/周）
    public let modelQuotas: [ModelQuota]          // 模型级配额
    public let rawJSON: [String: Any]            // 原始数据（UI 详情展开）
}
```

### 4.2 Router 消歧升级

当前：`provider/model`、`alias/model`、裸模型名（前缀优先 + 字母序）。

升级为 OmniRoute 风格三段式：

1. **显式前缀**：`ds/xxx`、`cbcn/xxx`、`agy/xxx` → 直接命中，最高优先。
2. **单候选直选**：裸模型名全局唯一供应商拥有 → 直接命中。
3. **前缀启发式**：按模型名前缀推断（`claude-*` → Anthropic 系、`gemini-*` → Gemini 系、`gpt-*` → OpenAI 系、`glm-*` → CodeBuddyCN/GLM 系、`deepseek-*` → DeepSeek）。
4. **前缀优先 + 字母序兜底**：当前逻辑作为最后回退。

实现：在 `ProviderRegistry` 启动时构建 `MODEL_TO_PROVIDERS: [String: [String]]` 反向索引（来自所有 descriptor 的 models 合并）。

### 4.3 模型启停过滤链

```
请求 → 认证 gateway key
     → Router.resolve(model) 得 (providerID, modelID)
     → 若 gatewayKey.enabledModels != null:
         构造规范化模型 ID "alias/modelID"
         若不在 enabledModels 集合 → 403 Forbidden
     → 进入 provider.chat
```

规范化：`enabledModels` 统一存储为 `"<alias>/<modelID>"` 形式（如 `ds/deepseek-v4-flash`），比较时归一化为 alias 形式避免 provider id 与 alias 歧义。

### 4.4 用量查询框架

```
ProviderUsageFetcher（协议）
  ├─ DeepSeekUsageFetcher       — GET /user/balance
  ├─ AntigravityUsageFetcher    — POST :retrieveUserQuota + :retrieveUserQuotaSummary
  ├─ CodeBuddyCNUsageFetcher    — 浏览器导入 token 后调网页接口（待逆向）
  ├─ KimiUsageFetcher           — 调研后实现
  ├─ MiniMaxUsageFetcher        — 调研后实现
  └─ ...
```

GUI 轮询：在 `AppState` 新增 `usageSnapshots: [String: ProviderUsageSnapshot]`，每供应商独立 5min 轮询（参考 CodexBar 自适应分档，但二期先固定 5min）。fetch 失败不中断轮询，UI 显示错误状态。

### 4.5 配置 schema 扩展

```jsonc
{
  "version": 2,                          // 升版本号，旧版自动迁移
  "host": "127.0.0.1",
  "port": 8231,
  "apiKeys": [                           // 改为对象数组（兼容旧字符串数组）
    { "key": "sk-bv-xxxx", "enabledModels": null },
    { "key": "sk-tg-legacy", "enabledModels": ["ds/deepseek-v4-flash"] }
  ],
  "providers": {
    "deepseek":      { "enabled": true, "apiKeys": [...], "credential": {...} },
    "codebuddy-cn":  { "enabled": true, "credential": {...} },
    "antigravity":   { "enabled": true, "credential": {...} },
    "openai":        { "enabled": true, "apiKeys": [...] },
    "opencode":      { "enabled": true, "apiKeys": [...] },
    "kimi":          { "enabled": true, "apiKeys": [...] }
  }
}
```

**迁移策略**：`ConfigStore.load` 检测 `version < 2` 时，把旧 `apiKeys: [String]` 转为 `[{key: $0, enabledModels: null}]`，写回 version=2。旧 `sk-tg-` key 保留可用，新生成用 `sk-bv-`。

---

## 5. 开发计划

二期划分为 7 个 Phase（Phase 12–18，接续一期 Phase 11）。优先级排序原则：**先架构后功能、先低风险后高风险、先核心供应商后扩展**。

### Phase 12 — 路由与配置升级（基础）

> 依赖：无（其他 Phase 都依赖此）
> 预计：~2 天

- [x] 12.1 `ProviderDescriptor` 新增 `modelsURL`、`forceStream`、`usageFetcherFactory` 字段
- [x] 12.2 `ProviderRegistry` 构建 `MODEL_TO_PROVIDERS` 反向索引
- [x] 12.3 `Router` 消歧升级：显式前缀 → 单候选直选 → 前缀启发式 → 字母序兜底
- [x] 12.4 `RouteConfig.apiKeys` 字段类型从 `[String]` 扩展为 `[GatewayKeyConfig]`（含 `enabledModels: [String]?`），旧字符串数组自动迁移
- [x] 12.5 `ConfigStore` version 升至 2，迁移逻辑 + 单测
- [x] 12.6 `RouteHandler` 增加 gateway key 级 `enabledModels` 过滤（403 Forbidden）
- [x] 12.7 BinviaCheck 新增：反向索引消歧、前缀启发式、迁移逻辑、enabledModels 过滤

### Phase 13 — 供应商级测试 + 动态模型扩展

> 依赖：Phase 12
> 预计：~1 天

- [x] 13.1 `Provider.testAllModels()` 默认实现：调 `listModels` → 串行 `testModel` → 汇总结果
- [x] 13.2 `SettingsProviderPane` 头部新增「测试全部模型」按钮（与「测试连接」并列），进度条 + 结果列表
- [x] 13.3 `ProviderDescriptor.modelsURL` 接入：`listModels` 默认实现改为「`ModelCache` 优先 → 上游 `modelsURL` → 静态兜底」
- [x] 13.4 `ModelCache` 推广到所有供应商（CodeBuddyCN 仍静态，但走统一接口）
- [x] 13.5 BinviaCheck 新增：`testAllModels` 串行逻辑、`modelsURL` 兜底

### Phase 14 — OpenAI 接入（需求 8，第一批）

> 依赖：Phase 12
> 预计：~1 天

- [x] 14.1 `Sources/BinviaCore/Providers/OpenAI/` 新建：`OpenAIProviderDescriptor` + `OpenAIProvider`
- [x] 14.2 baseURL=`https://api.openai.com/v1`，authType=`.apiKey`，modelsURL=`/v1/models`
- [x] 14.3 `chat` 实现：标准 OpenAI 兼容请求（`stream` 透传，非流式直接 body），无需 envelope 翻译
- [x] 14.4 静态模型目录兜底（gpt-5.6 / 5.5 / 5.4 / 4.1 / 4o / o3 / o4-mini）
- [x] 14.5 `ProviderCatalog.registerAll()` 加一行
- [x] 14.6 GUI 设置面板：apiKey 段位支持 OpenAI 配置（与 DeepSeek 同模式）
- [x] 14.7 BinviaCheck 集成测试（mock `/v1/models` + mock `/v1/chat/completions`）

### Phase 15 — opencode + kimi 接入（需求 9，第一批）

> 依赖：Phase 14（验证 OpenAI 兼容供应商接入流程）
> 预计：~1.5 天

- [x] 15.1 `Providers/OpenCode/`：baseURL=`https://opencode.ai/zen/v1`，alias=`oc`，`passthroughModels=true`（动态为主）
- [x] 15.2 `Providers/Kimi/`：baseURL=`https://api.moonshot.ai/v1`，alias=`kimi`，`forceStream=true`（参考 CodeBuddyCN 强制流式 + 聚合模式）
- [x] 15.3 `ProviderCatalog` 注册两家
- [x] 15.4 GUI 配置段位（apiKey 模式）
- [x] 15.5 BinviaCheck 集成测试

### Phase 16 — 用量查询框架 + 三个已有供应商

> 依赖：Phase 12
> 预计：~3 天

- [x] 16.1 `Networking/Usage/` 新建：`ProviderUsageFetcher` 协议、`ProviderUsageSnapshot` 模型、`UsageCache` actor（5min TTL）
- [x] 16.2 `DeepSeekUsageFetcher`：`GET /user/balance`，解析 `balance_infos[]`
- [x] 16.3 `AntigravityUsageFetcher`：复用 OAuth 凭据，调 `:retrieveUserQuota` + `:retrieveUserQuotaSummary` 双 RPC
- [x] 16.4 `CodeBuddyCNUsageFetcher`：**抓包分析 CodeBuddy 网页存储 schema**（高风险任务）
  - [ ] 16.4a 调研：CodeBuddy 官网登录后的 cookie / localStorage / IndexedDB 中的 token 字段（**暂缓**：离线无法逆向，见二期完成报告）
  - [ ] 16.4b 实现 `CodeBuddyCNTokenImporter`：从 Chrome localStorage 读取（参考 CodexBar `DeepSeekPlatformTokenImporter`）（**暂缓**）
  - [ ] 16.4c 若 16.4a 无可用入口，回退方案 B（手动导入 cookie 到 config）（**暂缓**）
- [x] 16.5 `AppState` 新增 `usageSnapshots` + 5min 轮询
- [x] 16.6 `SettingsProviderPane` 新增「用量」Section：余额卡片 / 配额进度条 / 模型级配额列表
- [x] 16.7 BinviaCheck 单测（mock 上游用量接口）

### Phase 17 — 网关密钥前缀迁移（需求 6）

> 依赖：无（可与其他 Phase 并行）
> 预计：~0.5 天

- [x] 17.1 `AppState.generateAPIKey()` 前缀 `sk-tg-` → `sk-bv-`
- [x] 17.2 旧 `sk-tg-` key 仍可鉴权（向后兼容），仅新生成用 `sk-bv-`
- [x] 17.3 GUI 文案更新（如有「以 sk-tg- 开头」的说明）
- [x] 17.4 BinviaCheck 单测

### Phase 18 — 第二批供应商接入 + 用量扩展

> 依赖：Phase 14、15、16
> 预计：~3 天

- [x] 18.1 `Providers/OpenCodeGo/`：baseURL=`https://opencode.ai/zen/go/v1`，alias=`ocgo`
- [x] 18.2 `Providers/Zai/`：baseURL=`https://api.z.ai/api/anthropic/v1/messages`，alias=`zai`，Anthropic 兼容格式
- [x] 18.3 `Providers/MiniMax/`：baseURL=`https://api.minimax.io/anthropic/v1/messages`，alias=`mm`，Anthropic 兼容格式
- [x] 18.4 `Providers/XiaomiMimo/`：baseURL=`https://api.xiaomimimo.com/v1`，alias=`mimo`
- [x] 18.5 `Providers/QwenCloud/`：baseURL=`https://dashscope-intl.aliyuncs.com/compatible-mode/v1`，alias=`qwc`
- [x] 18.6 调研每家用量查询 API，有则实现 `UsageFetcher`，无则不展示卡片（需求 10）
- [x] 18.7 BinviaCheck 集成测试
- [x] 18.8 README 供应商表格同步更新

---

## 6. 开发进度

> 实施时按 Phase 顺序勾选；每个 Phase 完成后追加 ✅ 与完成日期。

| Phase | 主题 | 状态 | 完成日期 |
|---|---|---|---|
| 12 | 路由与配置升级 | ✅ 已完成 | 2026-08-01 |
| 13 | 供应商级测试 + 动态模型扩展 | ✅ 已完成 | 2026-08-01 |
| 14 | OpenAI 接入 | ✅ 已完成 | 2026-08-01 |
| 15 | opencode + kimi 接入 | ✅ 已完成 | 2026-08-01 |
| 16 | 用量查询框架 + 三家已有供应商 | ✅ 已完成（CodeBuddy-CN 用量暂缓） | 2026-08-01 |
| 17 | 网关密钥前缀迁移 | ✅ 已完成 | 2026-08-01 |
| 18 | 第二批供应商 + 用量扩展 | ✅ 已完成 | 2026-08-01 |

### 关键里程碑

- **M1（Phase 12-13 完成）**：✅ 路由与配置基础就绪（反向索引消歧、v2 配置迁移、enabledModels 白名单、供应商级批量测试、动态模型兜底）。
- **M2（Phase 14-15 完成）**：✅ 第一批新供应商（OpenAI + opencode + kimi）端到端可用。
- **M3（Phase 16 完成）**：✅ DeepSeek / Antigravity 用量卡片上线；**CodeBuddy-CN 用量暂缓**（需求 5，待逆向网页存储 schema，见 [二期完成报告](phase2-completion-report.md)）。
- **M4（Phase 17-18 完成）**：✅ 第二批供应商接入完毕（opencode-go / xiaomi-mimo / qwen-cloud / zai / minimax），二期全部交付。

---

## 7. 预期成果与风险

### 7.1 预期成果

**功能层面**：
- 供应商矩阵从 3 家扩展到 11 家（DeepSeek / CodeBuddyCN / Antigravity / OpenAI / opencode / opencode-go / kimi / z.ai / minimax / xiaomi-mimo / qwen）。
- 每个 gateway key 可独立配置可见模型白名单。
- DeepSeek / Antigravity / CodeBuddy-CN（视抓包）/ Kimi / MiniMax 等供应商在设置面板展示余额或配额。
- 每个供应商卡片可一键串行测试全部模型。
- 所有支持上游 `/v1/models` 的供应商动态获取模型列表。

**架构层面**：
- `ProviderDescriptor` 扩展为支持动态模型、强制流式、用量查询器的统一抽象。
- Router 消歧升级为 OmniRoute 风格三段式，支持 11 家供应商下裸模型名仍可用。
- `ConfigStore` schema v2，向后兼容 v1。

**测试层面**：
- BinviaCheck 用例从 96 项扩展到 ~140 项（覆盖消歧升级、迁移逻辑、启停过滤、新供应商集成、用量查询）。

### 7.2 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| **CodeBuddy-CN 网页存储 schema 不可逆向**（需求 5） | 高 — Phase 16.4 可能卡住 | 提前在 Phase 12 启动抓包调研；若无可用入口，回退方案 B（手动 cookie 导入），UI 标注「实验性」 |
| Anthropic 兼容格式供应商（z.ai / minimax）envelope 翻译工作量超预期 | 中 | 参考 Antigravity envelope 模式，抽象 `EnvelopeTranslator` 协议复用 |
| 某些供应商无公开用量 API（OpenAI / z.ai / opencode） | 低 — 已对齐「有则展示无则隐藏」 | UI 直接隐藏卡片，不影响其他功能 |
| 配置 schema v1→v2 迁移破坏现有用户配置 | 中 | `ConfigStore.load` 自动迁移 + 备份原文件到 `config.json.v1.bak`；BinviaCheck 覆盖迁移用例 |
| 多 key 白名单过滤性能（每请求查 set） | 低 | `enabledModels` 加载时预编译为 `Set<String>`，O(1) 查询 |
| Antigravity 用量 RPC 与 chat 共用 OAuth 凭据触发限流 | 低 | 用量查询走独立 `UsageCache`（5min TTL），不与 chat 路径竞争 |

---

## 8. 验收标准

二期完成时需满足：

1. `swift build` 无警告。
2. `make test`（BinviaCheck）全部通过，覆盖新增的 7 个 Phase 全部功能点。
3. `swift run BinviaApp --smoke-test` 全部通过。
4. 11 家供应商在 GUI 设置面板可配置（apiKey 或 OAuth 流程）。
5. 至少 DeepSeek + Antigravity 两家用量卡片在 GUI 正确展示。
6. 每个 gateway key 可独立配置 `enabledModels`，过滤生效（403）。
7. 每个供应商卡片「测试全部模型」按钮可串行执行并汇总结果。
8. 新生成网关密钥前缀为 `sk-bv-`，旧 `sk-tg-` key 仍可鉴权。
9. README 供应商表格与配置示例同步更新。
