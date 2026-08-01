# OmniRoute 工程分析报告

> 分析日期：2026-08-01
> 工程路径：`/Users/wangbin/workspace/temp/my-token-route/OmniRoute`
> 版本：3.8.50

## 1. 工程概况

OmniRoute 是一个 **统一 AI 路由网关**：聚合 160+ 供应商，提供 OpenAI 兼容 API、自动回退、压缩、MCP/A2A 支持、桌面端（Electron）、PWA、监控面板。核心价值是**把任意供应商（OAuth/API-key/Cookie）统一成 OpenAI 兼容接口**，供 Claude Code / Codex / Cursor / 各种工具直接调用。

- **关键能力**：`/v1/chat/completions` 统一入口 + 模型路由（`provider/model` 语法）+ 供应商连接管理 + 本地 MITM 端口代理 + api-key 认证 + 请求监控。
- **双形态**：Next.js Web 应用（管理面板 + API）+ Electron 桌面壳 + `bin/omniroute` CLI。

## 2. 技术栈

| 维度 | 详情 |
|---|---|
| 框架 | Next.js 16 (App Router) + React 19 |
| 语言 | TypeScript 6（ESM） |
| Node | >=22.22.2 <23 或 >=24.0.0 <27 |
| 核心引擎 | `open-sse/` npm workspace（路由/执行器/翻译器） |
| 桌面端 | `electron/` |
| 存储 | better-sqlite3 / sql.js / lowdb（db.json） |
| 关键依赖 | express、zod、undici、ws、http-proxy-middleware、jose（JWT）、pino、next-intl、zustand |

### `src/` 目录职责

| 目录 | 职责 |
|---|---|
| `src/app/` | Next.js App Router：`(dashboard)/` UI、`api/` REST、`v1/` OpenAI 兼容 API |
| `src/domain/` | 领域逻辑：策略引擎、配额缓存、回退策略、成本规则 |
| `src/lib/` | 业务服务：providers、auth、oauth、usage、db、mitm 管理、monitoring |
| `src/mitm/` | **MITM 代理**（本地端口反向代理 + TLS 拦截） |
| `src/server/` | AuthZ 中间件流水线（api-key 认证、CSRF、CORS） |
| `src/sse/` | SSE 聊天处理器（**路由核心层**） |
| `open-sse/` | **核心引擎**：executors、handlers、translators、config/providers |
| `electron/`、`bin/` | 桌面壳、CLI |

## 3. 供应商注册方式（重点）

### 3.1 单一事实来源：`open-sse/config/providers/registry/`

**主注册表**：`open-sse/config/providers/index.ts`

```ts
import { deepseekProvider } from "./registry/deepseek/index.ts";
import { antigravityProvider } from "./registry/antigravity/index.ts";
import { codebuddy_cnProvider } from "./registry/codebuddy-cn/index.ts";
// ...
export const REGISTRY: Record<string, RegistryEntry> = {
  deepseek: deepseekProvider,
  antigravity: antigravityProvider,
  "codebuddy-cn": codebuddy_cnProvider,
  // ... 约 180 个
};
```

**Schema 定义**：`open-sse/config/providers/shared.ts`

```ts
interface RegistryEntry {
  id: string;
  alias?: string;                    // 短别名（ds/cbcn/agy）
  format: "openai" | "anthropic" | "gemini" | "antigravity" | ...;
  executor: string;                  // 指向 executors/ 下的执行器
  baseUrl: string | string[];
  authType: "apikey" | "oauth" | ...;
  authHeader: "bearer" | ...;
  headers?: Record<string, string>;
  oauth?: RegistryOAuth;             // clientIdEnv/tokenUrl/authUrl...
  models: RegistryModel[];           // id/name/contextLength/supportsReasoning...
  passthroughModels?: boolean;
  urlBuilder?: (entry, req) => URL;
  modelsUrl?: string;
}
```

提供 `buildOpenAiCompatibleRegistryEntry()` 工厂：标准 OpenAI 兼容条目四件套 `{format:"openai", executor:"default", authType:"apikey", authHeader:"bearer"}`。

**注册表查询工具**：`open-sse/config/providerRegistry.ts`（`getRegistryEntry`/`getRegisteredProviders`/`getProviderCategory`）。

### 3.2 执行器（Executor）注册

`open-sse/executors/index.ts`：

```ts
const executors = {
  antigravity: new AntigravityExecutor(),
  "codebuddy-cn": new CodeBuddyCnExecutor(),
  "deepseek-web": new DeepSeekWebExecutor(),
  // ...
};
export function getExecutor(provider) {
  return executors[provider] ?? new DefaultExecutor();
}
```

### 3.3 新增供应商步骤

1. 创建 `open-sse/config/providers/registry/<provider>/index.ts` 导出 `RegistryEntry`。
2. 在 `open-sse/config/providers/index.ts` 登记进 `REGISTRY`。
3. （可选）特殊执行器 → `open-sse/executors/<provider>.ts` 并注册。
4. （可选）UI 常量、key 验证、OAuth 流程。

## 4. 模型获取与路由（重点）

### 4.1 /models 接口

- 入口：`src/app/api/v1/models/route.ts` → `getUnifiedModelsResponse()`。
- 目录 `src/app/api/v1/models/`：`catalog.ts`（聚合 REGISTRY 静态模型 + 已连接供应商动态模型 + OpenRouter 目录）、`catalogResponse.ts`、`catalogDedupe.ts` 等。

### 4.2 模型路由主链路

```
/v1/chat/completions (src/app/api/v1/chat/completions/route.ts)
  └→ handleChat (src/sse/handlers/chat.ts)
       ├→ resolveRoutingModel (src/sse/handlers/resolveRoutingModel.ts)  # 解析 provider/model
       ├→ getProviderCredentialsWithQuotaPreflight (src/sse/services/auth.ts)
       ├→ resolveModelOrError / executeChatWithBreaker (src/sse/handlers/chatHelpers.ts)
       └→ handleChatCore (open-sse/handlers/chatCore.ts)
            └→ getExecutor(provider).execute() (open-sse/executors/base.ts)
```

- **模型字符串解析**：`open-sse/services/model.ts` 的 `parseModel()`，支持别名（`agy→antigravity`）、通配符路由。
- **账号选择**：`src/sse/services/auth.ts` 的 `getProviderCredentials()`（配额过滤、熔断、会话亲和）+ `open-sse/services/accountFallback.ts`（429/熔断回退）。
- **格式翻译器**：`open-sse/translator/`（request/response 双向转换，如 `antigravity-to-openai`、`gemini-to-openai`）。

### 4.3 供应商可用性测试

- 接口：`POST /api/providers/[id]/test`（`src/app/api/providers/[id]/test/route.ts`）。
- API-key 连接 → `validateProviderApiKey()`（`src/lib/providers/validation.ts`）。
- OAuth 连接 → `testOAuthConnection()`（自动 refresh token + 探测上游端点）。
- 模型级测试 → `src/lib/api/modelTestRunner.ts`（真实调用 `/v1/chat/completions`）。

## 5. 本地端口代理 / 反向代理（重点）

### 5.1 `src/mitm/` 目录

| 文件/目录 | 作用 |
|---|---|
| `server.cjs` | **核心代理服务器**（独立 CJS 子进程，HTTPS + CONNECT 隧道） |
| `manager.ts` | 代理生命周期管理（spawn、DNS 配置、证书安装） |
| `types.ts` | `MitmTarget` + `AgentId` |
| `targets/` | 各 Agent 目标描述（antigravity、claudeCode、copilot、codex...） |
| `handlers/` | 各 Agent 请求处理（格式转换 + 转发） |
| `dns/` | `/etc/hosts` DNS 劫持（目标域名 → 127.0.0.1） |
| `cert/` | MITM 根 CA + 每主机叶子证书 |
| `_internal/` | CJS shim：`forwardTarget.cjs`、`standaloneRouting.cjs`、`aliasConfig.cjs`、`bypass.cjs` |
| `inspector/` | 流量捕获 |

### 5.2 两种接入模式

**模式 A：DNS 劫持（无需配置）**
1. `manager.ts` → `dns/provision.ts` 把目标域名（如 `cloudcode-pa.googleapis.com`）写入 `/etc/hosts` → 127.0.0.1。
2. IDE 请求到达本地 `server.cjs`（`MITM_LOCAL_PORT`，默认 443）。
3. `https.createServer` 用 MITM 证书做 TLS 终止解密。
4. 按 Host 路由：`bypass > target > passthrough`（`src/mitm/targets/index.ts` 的 `routeConnection()`）。

**模式 B：显式 HTTP 代理（CONNECT 隧道）**
- `server.cjs` 的 `server.on("connect")`：bypass → 裸 TCP 转发；target → 200 后交给本地 TLS 解密；其它 → passthrough。

### 5.3 拦截转发链路（`intercept()`，server.cjs 第 465 行）

```
1. 解析 body → aliasConfigShim.applyAntigravityOverride（模型映射）
2. standaloneRoutingShim.resolveForwardTargetForAgent
   - cloudcode 信封 → /v1/antigravity
   - OpenAI body  → /v1/chat/completions
   - anthropic 格式 → /v1/messages
3. fetch(forward.url, { Authorization: Bearer ${ROUTER_API_KEY}, x-omniroute-source: agent-bridge })
4. SSE 流式回传 + captureToInspector() 上报流量
```

### 5.4 api-key 认证与 OpenAI 兼容接口

- 认证入口：`src/proxy.ts`（Next.js middleware matcher）→ `src/server/authz/pipeline.ts`。
- 策略：`src/server/authz/policies/clientApi.ts` 的 `extractBearer()` 支持 `Authorization: Bearer`、`x-api-key`、`x-goog-api-key`、URL token → `validateApiKey()`。
- 持久化 env key：`src/sse/services/auth.ts` 的 `isValidApiKey()`（`OMNIROUTE_API_KEY` / `ROUTER_API_KEY` 恒为有效）。
- OpenAI 兼容接口（`src/app/api/v1/`）：`chat/completions`、`completions`、`responses`、`embeddings`、`images`、`audio`、`models`、`antigravity`。

## 6. 三种典型供应商接入

### 6.1 Google Antigravity（本地语言服务器 + OAuth）

| 关注点 | 文件 |
|---|---|
| 注册表 | `open-sse/config/providers/registry/antigravity/index.ts`（`format:"antigravity"`, `executor:"antigravity"`, `authType:"oauth"`） |
| 执行器 | `open-sse/executors/antigravity.ts`（1526 行，`AntigravityExecutor`） |
| OAuth | `src/lib/oauth/providers/antigravity.ts`（authorization_code + PKCE） |
| 上游 URL | `open-sse/config/antigravityUpstream.ts`（`cloudcode-pa.googleapis.com`） |
| MITM target | `src/mitm/targets/antigravity.ts` + `handlers/antigravity.ts` |
| API 路由 | `src/app/api/v1/antigravity/route.ts` |

**接入方式**：
- 认证：Google OAuth `authorization_code`，OAuth 后执行 `loadCodeAssist` + `onboardUser` 获取 `projectId`。
- 请求：cloudcode 信封（Gemini `contents` 格式）→ 翻译为 OpenAI → 路由到目标 provider → 响应反向翻译为 cloudcode SSE。
- 始终使用流式端点 `streamGenerateContent?alt=sse`；`refreshCredentials()` 处理 token 轮换。
- **MITM**：DNS 劫持 `cloudcode-pa.googleapis.com` → 本地 server.cjs 解密 → 转发 `/v1/antigravity`（带 `ROUTER_API_KEY`）。

### 6.2 Tencent CodeBuddy（设备码 OAuth）

| 关注点 | 文件 |
|---|---|
| 注册表 | `open-sse/config/providers/registry/codebuddy-cn/index.ts`（`executor:"codebuddy-cn"`, `authType:"oauth"`, baseUrl `https://copilot.tencent.com/v2/chat/completions`, 15 个模型） |
| 执行器 | `open-sse/executors/codebuddy-cn.ts`（强制 `stream:true`） |
| OAuth | `src/lib/oauth/providers/codebuddy-cn.ts`（`device_code` 流） |

**接入方式**：
- 认证：自定义设备码流。`requestDeviceCode()` POST `stateUrl?platform=...` 获取 `state`+`authUrl`；打开浏览器；`pollToken()` GET `tokenUrl?state=...` 轮询直到 `code===0`（`11217` 为 pending）。
- 请求：OpenAI 兼容格式但**强制流式**（非流式被上游 400 code 11101 拒绝），OmniRoute 为 JSON 客户端重新聚合 SSE。
- Headers：`User-Agent: CLI/2.108.1 CodeBuddy/2.108.1`、`X-Product: SaaS`、`X-IDE-Type: CLI` 等。

### 6.3 DeepSeek（API 版 + Web 版双通道）

| 关注点 | 文件 |
|---|---|
| API 注册表 | `open-sse/config/providers/registry/deepseek/index.ts`（`authType:"apikey"`, baseUrl `https://api.deepseek.com/v1/chat/completions`） |
| Web 注册表 | `open-sse/config/providers/registry/deepseek/web/index.ts`（`executor:"deepseek-web"`） |
| Web 执行器 | `open-sse/executors/deepseek-web.ts`（模拟 `chat.deepseek.com` web 客户端，Pow 挑战） |
| 配额抓取 | `open-sse/services/deepseekQuotaFetcher.ts` |

**接入方式**：
- **deepseek（API 版）**：标准 OpenAI 兼容 + Bearer API key，`executor:"default"` 直连 `api.deepseek.com/v1/chat/completions`。
- **deepseek-web**：用户 token 存于 apiKey 字段（可 JSON 包裹 `{"value":"..."}`），带浏览器指纹头请求 `chat.deepseek.com/api/v0/chat/completion`。

## 7. 监控功能

| 功能 | 文件 |
|---|---|
| 可观测性服务 | `src/lib/monitoring/observability.ts`（熔断器、会话、quota 快照、遥测） |
| 供应商健康自动调度 | `src/lib/monitoring/providerHealthAutopilot.ts` |
| 用量事件 | `src/lib/usage/usageEvents.ts`、`usageStats.ts` |
| 请求日志 | `src/lib/usageDb.ts`（`saveCallLog`）、`src/lib/proxyLogger.ts` |
| MITM 流量捕获 | `src/mitm/inspector/` |
| API | `src/app/api/usage/*`、`src/app/api/analytics/*`、`src/app/api/monitoring/health`、`src/app/api/logs/` |

## 8. 关键目录索引

```
open-sse/                                 # 核心引擎
├── config/providers/registry/<provider>/ # 供应商注册（唯一事实来源）
├── config/providerRegistry.ts            # 注册表查询
├── executors/                            # 执行器（antigravity/codebuddy-cn/deepseek-web/default）
├── handlers/chatCore.ts                  # 最终执行（翻译+SSE+usage）
├── services/model.ts                     # 模型解析
├── translator/                           # 格式转换
src/
├── app/api/v1/                           # OpenAI 兼容 API（chat/completions/models/antigravity...）
├── app/api/providers/[id]/test/          # 供应商可用性测试
├── sse/handlers/chat.ts                  # 路由核心
├── sse/services/auth.ts                  # 凭据选择/配额预检
├── mitm/                                 # MITM 本地代理（server.cjs/manager/targets/handlers/dns/cert）
├── server/authz/                         # api-key 认证流水线
├── lib/providers/validation.ts           # API key 验证
├── lib/monitoring/                       # 监控
└── lib/usage/                            # 用量统计
```

## 9. 运行方式

```bash
npm run dev            # Next.js 开发模式
npm run electron:dev   # Next.js + Electron
npm run build / npm run start
PORT=20128 npm run dev # 默认端口 20128
```

关键 env：`PORT`、`BASE_URL`、`JWT_SECRET`、`INITIAL_PASSWORD`、`REQUIRE_API_KEY`、`OMNIROUTE_API_KEY`/`ROUTER_API_KEY`、`MITM_LOCAL_PORT`、`ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET`、`DEEPSEEK_API_KEY`、`QUOTA_STORE_DRIVER`。

## 10. 对本工程（Binvia）的可借鉴点

1. **注册表即供应商注册方式**：`REGISTRY: Record<string, RegistryEntry>` 是新增供应商的单一入口，比 CodexBar 的枚举+静态字典更扁平。
2. **OpenAI 兼容入口**：`/v1/chat/completions` + `/v1/models` 是所有工具调用的统一面，api-key 认证（Bearer/x-api-key）+ env key 白名单。
3. **执行器 + 翻译器分离**：`getExecutor(provider)` + translator 处理非 OpenAI 格式供应商（antigravity 的 cloudcode 信封、codebuddy 的强制流式）。
4. **本地端口代理**：MITM `server.cjs` 监听本地端口 → 解密 → 按 Host/Agent 路由 → 带 `ROUTER_API_KEY` 转发到自身 `/v1/*`。
5. **供应商可用性测试**：`/api/providers/[id]/test` + `validateProviderApiKey()`，OAuth 自动 refresh 探测。
6. **模型路由语法**：`provider/model` + 别名（`agy`/`ds`/`cbcn`）+ 通配符路由。
