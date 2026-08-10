# OpenCode / OpenCode Go Cookie 用量查询实现计划

> 制定日期：2026-08-10
> 参考：CodexBar `docs/opencode.md`、`Sources/CodexBarCore/Providers/OpenCode*`
> 关联现状：Binvia 已落地 `OpenCodeGoLocalUsageReader`（本地 SQLite），本文档规划 Cookie web 链路

## 1. 背景与目标

OpenCode / OpenCode Go 上游没有可用的 API Key 用量/余额端点：

- `GET https://opencode.ai/zen/go/v1/quota` 当前返回 404（上游未公开，见 OmniRoute `opencodeQuotaFetcher.ts` 备注）。
- 普通 OpenCode 在 Binvia 中只有 `usageDashboardURL`，没有用量查询。
- CodexBar 证明了一条可行链路：用 `opencode.ai` 浏览器 Cookie 调 `_server` RPC 和抓取 dashboard 页面，能拿到真实的 5h/周/月配额与 Zen 余额。

目标：为 Binvia 的 `opencode` 与 `opencode-go` 增加 Cookie 方式的用量/余额查询，最终做到：

- 本地 SQLite 优先（无需 Cookie 也能显示本机用量）；
- 有 Cookie 时叠加服务端权威配额窗口与 Zen 余额；
- 普通 OpenCode 不再只显示“请到网页查看”。

## 2. 当前现状

### 2.1 已完成（2026-08-10）

| 模块 | 现状 |
|---|---|
| `OpenCodeGoLocalUsageReader` | 已实现：读取 `~/.local/share/opencode/opencode.db`，兼容 `opencode-go` / `opencodego` 两种 provider 名，输出 $12/5h、$30/周、$60/月三个 `QuotaWindow` |
| `OpenCodeGoUsageFetcher` | 已改为默认 local-first；显式设置 `OPENCODE_GO_QUOTA_URL` 才走 web 配额接口 |
| 测试 | `BinviaCheck` 新增 SQLite fixture 用例，覆盖 message-only、message+part、缺失库；`make test` 全部通过 |

### 2.2 已完成（2026-08-11 追加：Cookie web 链路）

| 模块 | 现状 |
|---|---|
| `ProviderCredential.cookieHeader` | 新增字段（可选，旧配置向后兼容）；手动 Cookie 存 GUI 设置面板 / env |
| `OpenCodeCookieConfig` | 新增：Cookie 头过滤（仅 `auth` / `__Host-auth`）、workspace 归一化（`wrk_...`/完整 URL）、env 优先回退 credential |
| `OpenCodeUsageFetcher` | 新增：普通 OpenCode `_server` RPC（workspaces + subscription.get），宽容 JSON + 正则解析 → 5h/周窗口 + 可选续订 |
| `OpenCodeZenBalanceParser` | 新增：JSON 显式键 / 页面 $ 金额 / billing RPC 整数缩放（/1e8） |
| `OpenCodeGoWebUsageFetcher` | 新增：抓 `/workspace/{id}/go` 三窗口 + dashboard/billing 余额；余额失败不影响配额 |
| `OpenCodeGoUsageFetcher` | 改造为 local-first → Cookie web overlay（本地金额 + web 权威剩余/重置 + Zen 余额）→ Cookie 失效回退本地并提示 |
| GUI | `OpenCodeCookieCredentials` 组件（Cookie + workspace 输入、保存/清除），挂在 opencode / opencode-go 设置面板 |
| 测试 | 新增 5 个套件（Cookie 配置、_server RPC、Zen 余额、Go web、local+web overlay）；`make test` 563 断言全绿 |

### 2.3 未完成（后续阶段）

| 缺口 | 说明 |
|---|---|
| 浏览器 Cookie 自动导入 | 第一版用手动粘贴；自动导入（AppKit 读浏览器存储）与 Keychain 缓存列为后续 |
| 真实 Cookie 手动验证 | 需真实登录会话在本地跑一次 `OpenCodeUsageFetcher` / `OpenCodeGoUsageFetcher` 验证输出 |

## 3. 参考实现（CodexBar）

### 3.1 普通 OpenCode

- 数据源：`opencode.ai` 浏览器 Cookie。
- 链路：
  1. `GET/POST https://opencode.ai/_server?id=<workspaces>` 拿 `wrk_...`；
  2. `GET/POST https://opencode.ai/_server?id=<subscription.get>&args=[workspaceID]` 拿订阅用量；
  3. 解析 `rollingUsage.usagePercent/resetInSec`、`weeklyUsage.usagePercent/resetInSec`、可选 `renewsAt`。
- 关键文件：`CodexBar/Sources/CodexBarCore/Providers/OpenCode/OpenCodeUsageFetcher.swift`。
- 注意：普通 OpenCode 在 CodexBar 中也没有“余额”，只有用量窗口；Zen 余额属于 OpenCode Go。

### 3.2 OpenCode Go

- Web 路径：Cookie 拿 workspace 后抓 `https://opencode.ai/workspace/{id}/go`，解析 `rollingUsage` / `weeklyUsage` / `monthlyUsage`。
- Zen 余额：抓 `https://opencode.ai/workspace/{id}` dashboard，兜底 `_server` billing RPC；余额原始整数除以 `100_000_000`。
- 本地路径：`~/.local/share/opencode/opencode.db`，固定限额估算。
- 关键文件：
  - `OpenCodeGoUsageFetcher.swift`
  - `OpenCodeGoZenBalanceFetcher.swift`
  - `OpenCodeGoZenBalanceParser.swift`
  - `OpenCodeGoLocalUsageReader.swift`

## 4. 目标架构

```
OpenCodeGoUsageFetcher
  ├─ local-first（已实现）
  │    OpenCodeGoLocalUsageReader
  └─ cookie web（本次计划）
       ├─ OpenCodeGoWebUsageFetcher    dashboard + billing
       └─ OpenCodeZenBalanceParser      balance 解析

OpenCodeUsageFetcher（新增）
  └─ OpenCodeWebUsageFetcher           _server RPC

CookieHeaderStore
  ├─ manual cookie（设置面板 / env）
  └─ Keychain cache（后续）

ProviderUsageSnapshot
  ├─ quotaWindows（5h / 周 / 月）
  └─ balance（Zen 余额，OpenCode Go）
```

## 5. 实施步骤

### 阶段 1：Cookie 凭据与配置

- 在 `ProviderCredential` 或新的 `CookieHeaderStore` 中增加 Cookie 字段，优先支持手动 Cookie（设置面板 + env `OPENCODE_COOKIE` / `OPENCODE_GO_COOKIE`）。
- 增加 workspace 配置：env `OPENCODE_WORKSPACE_ID` / `OPENCODE_GO_WORKSPACE_ID`，兼容 `wrk_...` 与完整 URL。
- Keychain 缓存与浏览器导入列为后续阶段，避免第一版范围过大。

验收：

- GUI 设置面板可保存/清空 Cookie 与 workspace；
- `OpenCodeWebCookieSupport` 能从配置/环境变量构造 `Cookie` 请求头。

### 阶段 2：OpenCode `_server` RPC 查询

- 新增 `OpenCodeUsageFetcher`（参考 CodexBar）：
  - `fetchWorkspaceID`：调 `_server` workspaces；
  - `fetchSubscriptionInfo`：调 `_server` subscription.get；
  - 解析 `rollingUsage` / `weeklyUsage` / `resetInSec`；
  - 401/403 / 登出特征文本 → 明确报错。
- 挂到 `OpenCodeProviderDescriptor.usageFetcherFactory`。

验收：

- 无 Cookie → 返回错误快照（不崩溃）；
- 有 Cookie → 返回两个 `QuotaWindow`；
- 用 URLProtocol mock 覆盖 GET/POST、空 payload、登出文本。

### 阶段 3：OpenCode Go web 查询与 Zen 余额

- 新增 `OpenCodeGoWebUsageFetcher`：
  - 抓 `/workspace/{id}/go` 解析三窗口；
  - 并行抓 dashboard 解析 Zen 余额；
  - 余额解析失败时不影响配额窗口。
- `OpenCodeGoUsageFetcher` 顺序：local-first → cookie web overlay → 纯本地结果。

验收：

- 有 Cookie → 配额窗口与余额都显示；
- Cookie 失效 → 回退本地结果并提示 Cookie 过期；
- 余额解析失败 → 只显示本地/配额，不报错。

### 阶段 4：GUI 与展示

- Provider 设置面板增加：
  - Cookie 输入（SecureField）+ 保存/清除；
  - workspace 输入（可选）；
  - 刷新用量按钮沿用现有 `ProviderUsageCard`。
- `ProviderUsageCard` 已支持 `quotaWindows` 与 `balance`，无需大改。

### 阶段 5：测试与回归

- 单测：
  - `_server` GET/POST 请求头与 URL；
  - 三窗口解析、fraction/percent 归一化；
  - Zen balance 解析（JSON / HTML / billing RPC）；
  - local + web overlay 优先级；
  - Cookie 失效回退。
- 集成：
  - `make test` 全量通过；
  - 用真实 Cookie 在本地跑一次 `OpenCodeUsageFetcher` / `OpenCodeGoUsageFetcher` 验证输出。

## 6. 配置与环境变量

| 变量 | 用途 |
|---|---|
| `OPENCODE_COOKIE` | OpenCode 手动 Cookie（测试/无 GUI 环境） |
| `OPENCODE_GO_COOKIE` | OpenCode Go 手动 Cookie |
| `OPENCODE_WORKSPACE_ID` | 跳过 workspace 发现，强制指定 OpenCode workspace |
| `OPENCODE_GO_WORKSPACE_ID` | 同上，OpenCode Go |
| `OPENCODE_GO_LOCAL_DIR` | 覆盖本地 opencode 数据目录（已实现） |
| `OPENCODE_GO_QUOTA_URL` | 显式覆盖 web 配额端点（保留，仅供测试/上游开放后使用） |

## 7. 风险与注意事项

- Cookie 会过期：过期后应清理缓存并回退本地数据，不阻断主流程。
- `_server` RPC 与页面结构是上游未公开接口：字段名/函数 ID 可能变化，解析要容忍多字段名。
- 普通 OpenCode 没有 Zen 余额字段；不要给 `opencode` 声明余额。
- 浏览器 Cookie 导入涉及隐私与 Keychain 权限，第一版用手动 Cookie 更稳妥。
- 保持 Binvia 零第三方依赖：Cookie 导入可后续用 AppKit 读取浏览器存储或让用户手动粘贴。

## 8. 验证方式

- `make test` 全量通过（含新增 Cookie mock 用例）。
- `swift run BinviaApp --smoke-test` 通过。
- 手动验证：配置 Cookie 后打开 Provider 面板，opencode-go 应显示三窗口 + Zen 余额；opencode 应显示 5h/周用量。

