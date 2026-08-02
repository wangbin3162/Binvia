# 主面板优化计划书

> 制定日期：2026-08-02
> 范围：菜单栏弹出面板（`MenuPanelView`）的信息架构重构——从单一长滚动视图改为「首页概况 + 顶部 SegmentedControl 切换已接入供应商 Tab」，复用二期已建成的 `usageSnapshots` 数据，参考 CodexBar 主面板的紧凑信息密度。
> 相关文档：[gui-implementation-guide.md](gui-implementation-guide.md)、[phase2-completion-report.md](phase2-completion-report.md)、[codexbar-analysis.md](codexbar-analysis.md)。

---

## 1. 背景与目标

### 1.1 现状问题

当前 `MenuPanelView` 由 5 个区块纵向堆叠：

```
┌─ Binvia 标题栏 ──────────────────┐
├─ ServerStatusView（启停按钮）    │
├─ ScrollView(ProviderList +      │ ← 高度 420，信息密度低
│   APIKeyManagerView)             │   APIKeyManager 占大量空间但使用频率低
├─ UsageView（请求计数汇总）       │
└─ footer（设置 / 退出）           ┘
```

存在三个核心问题：

1. **用量快照未在主面板展示**：二期 Phase 16 已建成 `AppState.usageSnapshots`（余额 / 配额窗口 / 模型配额），但仅 `SettingsProviderPane.usageSection` 使用，主面板只显示本地请求计数，看不到上游余额。
2. **信息密度不均**：`ProviderListView` 每行只显示「状态灯 + 名称 + req 计数 + 齿轮」，缺乏一眼可见的健康度；`APIKeyManagerView` 占据主面板近半空间但功能已完全在 `SettingsGatewayKeysPane` 中提供。
3. **缺乏分层**：配置入口、用量详情、网关密钥管理混在同一滚动视图，用户必须在面板里上下翻找。

### 1.2 目标

| # | 目标 | 验收 |
|---|---|---|
| 1 | 主面板首页显示概况：服务器状态 + 总体用量 + 各 provider 健康度卡片 | 展开菜单栏一屏看到全部已配置 provider 的关键指标 |
| 2 | 顶部 SegmentedControl 切换已接入 provider Tab，每个 Tab 展示该 provider 的余额/配额/请求统计 | 至少 3 个 provider（DeepSeek / Antigravity / Kimi）的 Tab 能展示用量卡片 |
| 3 | 主面板移除 `APIKeyManagerView`，网关密钥管理仅保留在设置面板 | Overview 顶部提供「网关密钥」入口按钮跳转设置 |
| 4 | 复用 `SettingsProviderPane.usageSection` 的渲染逻辑，避免重复实现 | 抽取共享组件 `ProviderUsageCard`，设置面板与主面板共用 |
| 5 | 主面板展示 **token 用量**（按 provider 聚合 + 最近请求明细） | Overview Summary 显示总 token；provider 行/Tab 显示 prompt/completion token；「最近请求」列表显示每次请求的 token 与耗时 |
| 6 | 保持 `MenuBarExtra` 约束（不使用 `.sheet` / `SettingsLink`，宽度 ~380pt） | macOS 14/15 上 Tab 切换稳定，无面板消失/闪烁 |

### 1.3 不在本计划范围

- 新增 provider 接入（沿用现有 11 家）
- 上游余额/配额查询接口扩展（沿用 Phase 16 的 `ProviderUsageFetcher` 协议）
- 设置面板内部布局调整（仅 `SettingsProviderPane` 改为引用共享组件，行为不变）
- 菜单栏图标 / `--smoke-test` 自检逻辑变更
- 设置面板内部布局调整（仅 `SettingsProviderPane` 改为引用共享组件，行为不变）
- 菜单栏图标 / `--smoke-test` 自检逻辑变更

---

## 2. 现状分析

### 2.1 主面板组件依赖

| 文件 | 当前职责 | 重构后 |
|---|---|---|
| `MenuPanelView.swift` | 5 区块纵向堆叠 | TabView 容器 + 顶部 SegmentedControl |
| `ServerStatusView.swift` | 启停按钮 + 状态灯 | **保留**，移至 Overview Tab 顶部 |
| `ProviderListView.swift` | provider 列表 + 齿轮跳转 | **移除**（功能合并到 Overview 健康度卡片） |
| `APIKeyManagerView.swift` | 网关 Key 列表 | **从主面板移除**（仅保留在 `SettingsGatewayKeysPane`） |
| `UsageView.swift` | 请求计数汇总 | **移除**（功能合并到 Overview 顶部 summary） |
| `SettingsProviderPane.swift` | 设置面板 provider 详情，含 `usageSection` | **抽取用量渲染为共享组件**，其余不变 |

### 2.2 已有数据基础

`AppState`（`AppState.swift:34-49`）已持有：

- `usageSummary: UsageSummary` —— 本地请求计数（按 provider 聚合），2s 刷新
- `usageSnapshots: [String: ProviderUsageSnapshot]` —— 上游用量快照（余额 / 配额窗口 / 模型配额），5min TTL 缓存
- `testStates: [String: ProviderTestState]` —— 连通性测试结果
- `oauthStates: [String: OAuthFlowState]` —— OAuth 登录状态
- `config.providers: [String: ProviderConfig]` —— 凭据配置
- `orderedProviderDescriptors()` —— 按 `config.providerOrder` 排序的描述符列表

**数据缺口（token 用量）**：`RequestLogEntry`（`Monitoring/RequestLogger.swift:3`）当前只有
`timestamp / method / path / providerID / model / statusCode / durationMS / error`，**不含 token 字段**；
`RouteHandler.handleChat`（`Server/RouteHandler.swift:225`）在返回响应前就记日志，上游流透传后 token 即丢失。
因此「token 用量展示」需要先在 Core 层新增 **token 采集 + 聚合**（见 §3.8），其余 UI 部分仅做重组。

### 2.3 `SettingsProviderPane.usageSection` 的渲染逻辑

`SettingsProviderPane.swift:697-771` 的 `usageSection` 已实现：

- 余额行：`usageMetricRow(label:value:)`（多 Key 余额逐行展示）
- 配额窗口：`quotaWindowRow(_:)`（ProgressView + 剩余百分比 + 重置时间）
- 模型配额：`modelQuotaRow(_:)`（同上，按模型）
- 失败提示：错误图标 + message + 刷新按钮
- 网页看板入口：`usageDashboardURL` provider 显示「在网页查看」按钮

这些逻辑直接抽到共享组件即可。

### 2.4 `MenuBarExtra` 约束回顾

- 不可靠：`.sheet`（macOS 14.6+ 点 sheet 导致面板消失）、`SettingsLink`（窗口打不开）
- 可靠：`TabView`、`ScrollView`、`Form`、自建 `NSWindow`（`SettingsWindowController`）
- 宽度：`MenuBarExtra(.window)` 默认约 380pt，高度自适应

本计划使用 `TabView` + 顶部 `SegmentedControl`（macOS 原生控件，不依赖 sheet/SettingsLink）。

---

## 3. 设计方案

### 3.1 整体布局

```
┌─ MenuPanelView ───────────────────────────┐
│  TopBar: 标题 + 网关密钥入口 + 设置 + 退出  │ ← 紧凑顶部条
├─ SegmentedControl                         │ ← 顶部 Tab 切换
│  [概况] [DeepSeek] [Antigravity] [Kimi]    │   仅已配置的 provider
├─ TabView Content ───────────────────────── │
│                                            │
│  Overview Tab:                             │
│    ┌─ ServerStatusView（启停 + 端口） ─┐  │
│    ├─ Summary 卡片（总 req / err / 活跃 provider） │
│    └─ Provider 健康度列表（每行：图标 + 名称 + 关键用量 + 状态） │
│       点击行 → 切换到对应 provider Tab     │
│                                            │
│  Provider Tab（DeepSeek 示例）:            │
│    ┌─ 头部：品牌图标 + 名称 + 副标题 + 齿轮 │
│    ├─ ProviderUsageCard（余额 / 配额 / 模型配额） │
│    ├─ 本地统计：req / err / 最近错误        │
│    └─ 操作：测试连接 / 在网页查看          │
│                                            │
└────────────────────────────────────────────┘
```

### 3.2 Tab 选择策略

**仅展示已配置凭据的 provider**（对齐用户决策：「仅已配置的 provider」）：

```swift
private var configuredProviders: [ProviderDescriptor] {
    appState.orderedProviderDescriptors().filter { appState.isProviderConfigured($0.id) }
}
```

- Tab 顺序：`config.providerOrder` 排序后过滤
- Tab 数量：0 个已配置 → 仅显示 Overview；N 个已配置 → Overview + N 个 provider Tab
- SegmentedControl 宽度超限时：SwiftUI 原生 `Picker` segmentationStyle 会自动等分压缩；超过 ~6 个时改为横向 `ScrollView` + 顶部 chip（见 §6 风险）

### 3.3 Overview Tab 设计

`OverviewTabView`（新建于 `Sources/BinviaApp/Views/OverviewTabView.swift`）：

```
┌─ ServerStatusView ─────────────────────┐
│  ● Running on :20427        [Stop]     │
├─ Summary 卡片 ─────────────────────────┤
│  总请求 1,234 · 错误 3 · 活跃 3 provider│
│  总 token：prompt 45.2K · completion 18.7K │
├─ Provider 健康度列表 ──────────────────┤
│  [DS] DeepSeek        ¥ 12.34    10 req │ ← 余额
│  [AG] Antigravity     5h 78% · 周 45%   │ ← 配额窗口
│  [KM] Kimi            1.2K tok   5 req  │ ← token 聚合
│  ...                                    │
└─────────────────────────────────────────┘
```

**健康度行**（`ProviderHealthRow`，新建于 `Components/`）：

- 图标：`ProviderBrandIcon`（复用现有组件）
- 名称：`descriptor.displayName`
- 关键用量：从 `usageSnapshots[id]` 派生
  - 有 `balance`：显示余额 + 币种（如 `¥ 12.34`）
  - 有 `quotaWindows`：显示首个窗口剩余百分比（如 `5h 78%`）
  - 无快照：显示 `—`
- 本地请求计数 + token 聚合：`usageSummary.byProvider[id]`（req 数 / 总 token，见 §3.8）
- 点击行：通过 binding 切换 SegmentedControl selection 到对应 provider Tab
- 右侧齿轮：跳转到 `SettingsProviderPane`（复用 `SettingsWindowController.shared.show(appState:pane:)`）

### 3.4 Provider Tab 设计

`ProviderTabView`（新建于 `Sources/BinviaApp/Views/ProviderTabView.swift`）：

```
┌─ 头部行 ───────────────────────────────┐
│  [Icon] DeepSeek          [⚙️ 设置]    │
│         API Key · 已配置                │
├─ ProviderUsageCard ────────────────────┤
│  余额                  ¥ 12.34 CNY     │
│  ─ 多 Key 余额（如有）逐行展示 ─        │
│  5h 窗口               78%  重置 14:00  │
│  Weekly                45%  重置 周一   │
│  claude-sonnet-4.6     62%             │
│  [刷新用量]                             │
├─ 本地统计 ─────────────────────────────┤
│  请求数 10 · 错误 0                     │
│  token：prompt 12.4K · completion 8.2K │
├─ 最近请求 ─────────────────────────────┤
│  14:02:03 ds/deepseek-v4-flash 1,024→512 tok 2.3s ✓ │
│  ...                                    │
├─ 操作 ─────────────────────────────────┤
│  [测试连接]  [在网页查看]               │
└─────────────────────────────────────────┘
```

- 头部行：复用 `SettingsProviderPane.headerRow` 的精简版（移除启用开关，开关保留在设置面板）
- 用量卡片：`ProviderUsageCard`（共享组件，见 §3.5）
- 本地统计：从 `usageSummary.byProvider[id]` 派生（req / err / token，见 §3.8）
- 最近请求：`RecentRequestsView`（见 §3.9），仅展示该 provider 的条目
- 操作按钮：「测试连接」调 `appState.testProvider(id)`，「在网页查看」打开 `descriptor.usageDashboardURL`
- 无用量 API 的 provider（如 OpenAI / z.ai / opencode）：Tab 内只显示头部 + 本地统计 + 最近请求 + 操作，不显示 `ProviderUsageCard`；若 `usageDashboardURL` 存在则显示网页入口

### 3.5 共享组件抽取：`ProviderUsageCard`

新建 `Sources/BinviaApp/Components/ProviderUsageCard.swift`：

```swift
struct ProviderUsageCard: View {
    let providerID: String
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let snapshot = appState.usageSnapshots[providerID] {
            // 复用 SettingsProviderPane.usageSection 的渲染：
            // - 失败提示
            // - 余额行（多 Key 余额逐行）
            // - 配额窗口 ProgressView
            // - 模型配额 ProgressView
            // - 刷新按钮
        } else if let dashboard = ProviderRegistry.shared.descriptor(for: providerID)?.usageDashboardURL {
            // 网页看板入口
        }
        // 无快照且无 dashboard：不渲染（Tab 中显示「暂无用量数据」占位）
    }
}
```

**抽取来源**：`SettingsProviderPane.swift:697-838` 的 `usageSection` / `usageMetricRow` / `quotaWindowRow` / `modelQuotaRow` / `progressColor` / `balanceText` 整体迁移到 `ProviderUsageCard`。

**`SettingsProviderPane` 改造**：原 `usageSection` 改为：

```swift
if !descriptor.isUserDefined {
    Section {
        ProviderUsageCard(providerID: providerID)
    } header: {
        Text("用量")
    }
}
```

行为与原实现完全一致（保持 Phase 16 的「有则展示无则隐藏」语义）。

### 3.6 顶部 TopBar 设计

`MenuPanelView` 顶部条（替换原「Binvia 标题栏」）：

```
┌────────────────────────────────────────┐
│  ⚡ Binvia    [🔑 Keys] [⚙️] [✕]        │
└────────────────────────────────────────┘
```

- 左侧：`bolt.shield` 图标 + 「Binvia」标题
- 右侧三个图标按钮：
  - `key.fill` → 跳转到 `SettingsPane.gatewayKeys`（替代原主面板的 `APIKeyManagerView`）
  - `gearshape` → 打开设置（`SettingsPane.general`）
  - `xmark.rectangle` → 退出
- 高度紧凑（~32pt），与 SegmentedControl 之间用 Divider 分隔

### 3.7 SegmentedControl 实现

```swift
@State private var selectedTab: String = "overview"  // "overview" 或 providerID

Picker("", selection: $selectedTab) {
    Text("概况").tag("overview")
    ForEach(configuredProviders, id: \.id) { descriptor in
        Text(descriptor.displayName).tag(descriptor.id)
    }
}
.pickerStyle(.segmented)
```

- Tab 切换通过 `selectedTab` binding 驱动 Overview 行点击
- Provider 配置变化时（用户在设置面板新增 provider），`configuredProviders` 自动响应（`@EnvironmentObject appState` 触发重渲染）
- 已配置 provider 为 0 时：仅显示 Overview，隐藏 SegmentedControl

### 3.8 Token 用量统计设计（数据层新增）

**数据来源**：上游 OpenAI 兼容响应中的 `usage` 字段。
- 非流式（`stream=false`）：响应 JSON 直接含 `usage: {prompt_tokens, completion_tokens, total_tokens}`
- 流式（`stream=true`）：结束 chunk（`[DONE]` 前）通常带 `usage`；强制流式供应商（CodeBuddy/Kimi）由 `SSEJSONAggregator` 聚合后同样含 `usage`

**采集位置**：`RouteHandler.handleChat`（`Server/RouteHandler.swift:198-236`）。当前透明透传不解析，
改造为：用「透传 + 旁路解析」的方式包裹上游流——每个 chunk 原样转发，同时喂给 `SSEParser` 抽取 `usage`，
流结束时回填到已记日志条目。**不透传不破坏、不改响应内容**。

```
上游流 chunk ──► TokenUsageExtractor ──► 原样透传给客户端
                      │ SSEParser 逐 chunk 解析完整事件
                      │ 提取 data: JSON 的 usage 字段（流式）
                      │ finish() 时解析残余体（非流式单 JSON）
                      ▼
                 流结束 → logger.updateTokens(id, tokens)
```

**数据模型变更**（`Monitoring/RequestLogger.swift` + `Server/RouteHandler.swift`）：

```swift
/// Token 用量（上游 usage 的标准化结构，缺失字段默认为 0）
public struct TokenUsage: Sendable, Codable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int
}

// RequestLogEntry 新增：
public let id: UUID              // 流结束回填定位用；init 默认 UUID() 不破坏现有调用点
public var tokens: TokenUsage?   // 流结束后回填；nil = 尚未采集到或上游未返回

// ProviderUsage 新增聚合字段：
public var totalPromptTokens: Int
public var totalCompletionTokens: Int
public var totalTokens: Int

// RequestLogger 新增方法：
public func updateTokens(id: UUID, tokens: TokenUsage)   // 流结束时回填日志条目
// summary() 聚合时累加 entry.tokens 到 ProviderUsage
```

**兼容性**：`UsageSummary` / `ProviderUsage` 仅由 `summary()` 现算、`/v1/usage` 序列化输出，
不落盘不解码，新增字段无兼容风险；`RequestLogEntry.id` 带默认值，测试与调用点零改动。

**`TokenUsageExtractor` 实现要点**（新建于 `Sources/BinviaCore/Networking/TokenUsageExtractor.swift`）：
- `@unchecked Sendable` 类（仿 `IteratorHandler`，单任务内可变，无并发访问）
- 内部持 `SSEParser`；`process(_ chunk: Data) -> Data` 原样返回并顺带解析
- 完整 SSE 事件 → `SSEEvent.dataValue` → JSON 解码 → 提取 `usage`（`usage.prompt_tokens` / `completion_tokens` / `total_tokens`）
- 流式 `usage` 可能有多个（部分供应商发多个带 usage 的 chunk），取**最后一个非空**
- `finish()`：冲刷 `SSEParser` 残余 buffer（非流式整段 JSON），解析 `usage`；返回累计结果
- 解析失败 / 无 `usage` → 返回 nil，不影响透传与日志

**UI 展示**：
- Overview Summary 增加「总 token：prompt X · completion Y」
- Provider 行副行 / Provider Tab 增加 token 聚合（`usageSummary.byProvider[id]` 派生）
- 「最近请求」mini 列表（新增，见 §3.9）：最近 N 条 `RequestLogEntry`，显示时间 / 模型 / prompt→completion / 耗时 / 状态

### 3.9 最近请求列表（可选增强）

Provider Tab 底部（或 Overview 底部）展示最近请求：

```
最近请求
  14:02:03  ds/deepseek-v4-flash  1,024→512 tok  2.3s  ✓
  14:01:57  agy/claude-sonnet-4.6  2,048→768 tok  5.1s  ✓
  14:01:20  cbcn/glm-4.6           512→128 tok   1.8s  ✗ 502
```

- 数据源：`RequestLogger.allEntries()`（内存上限 1 万条）
- `AppState` 新增 `@Published recentEntries: [RequestLogEntry]`，随 2s metrics 轮询刷新，倒序取最近 10 条
- 流式请求的 token 在流结束后才回填，故「最近请求」可能短暂显示 `—`（token 未就绪），下一轮刷新补上

---

## 4. 实施步骤

### Phase 22 — Token 采集（Core 数据层）

前置步骤，UI 重构依赖 token 数据。

#### 22.0 Token 采集与聚合
- `RequestLogger.swift`：新增 `TokenUsage` struct；`RequestLogEntry` 增加 `id: UUID`（默认值）与 `tokens: TokenUsage?`
- `ProviderUsage` 增加 `totalPromptTokens` / `totalCompletionTokens` / `totalTokens`，`summary()` 聚合
- 新建 `TokenUsageExtractor.swift`（透传 + 旁路解析，见 §3.8）
- `RouteHandler.handleChat`：包裹上游流 → 返回后流结束回填 `logger.updateTokens(id:tokens:)`
- **验证**：`swift build` 无警告；`make test` 全过；新增单测覆盖——流式带 usage 的 chunk、非流式整段 JSON、无 usage 的响应、多 usage chunk 取最后一个

### Phase 23 — 主面板 Tab 化重构

按依赖顺序分 6 步，每步独立可编译可验证。

#### 23.1 抽取 `ProviderUsageCard` 共享组件
- 新建 `Sources/BinviaApp/Components/ProviderUsageCard.swift`
- 从 `SettingsProviderPane` 迁移：`usageSection` / `usageMetricRow` / `quotaWindowRow` / `modelQuotaRow` / `progressColor` / `balanceText`
- `ProviderUsageCard` 公开 API：`init(providerID:)`，内部 `@EnvironmentObject appState`
- `SettingsProviderPane.usageSection` 改为 `ProviderUsageCard(providerID: providerID)` 调用
- **验证**：`swift build` 无警告；`swift run BinviaApp --smoke-test` 全过；设置面板用量卡片视觉与重构前一致

#### 23.2 新建 `ProviderHealthRow` 组件
- 新建 `Sources/BinviaApp/Components/ProviderHealthRow.swift`
- 入参：`descriptor: ProviderDescriptor`、`onTap: () -> Void`、`onSettings: () -> Void`
- 内部从 `appState.usageSnapshots` / `appState.usageSummary` 派生关键指标
- 关键用量优先级：`balance` > `quotaWindows.first` > `—`；副行追加 token 聚合（`prompt/completion`）
- **验证**：编译通过；Preview 可见各状态（有余额 / 有配额 / 无快照 / 有 token）

#### 23.3 新建 `OverviewTabView`
- 新建 `Sources/BinviaApp/Views/OverviewTabView.swift`
- 结构：`ServerStatusView` → Summary 卡片 → `ProviderHealthRow` 列表
- Summary 卡片：总请求数 / 错误数 / 活跃 provider 数 / 总 token（从 `appState.usageSummary` 派生）
- 行点击：调用 `onSelectProvider(providerID)` 回调（由 `MenuPanelView` 绑定到 `selectedTab`）
- **验证**：编译通过；展开菜单栏可见概况页

#### 23.4 新建 `ProviderTabView`
- 新建 `Sources/BinviaApp/Views/ProviderTabView.swift`
- 结构：头部行（图标 + 名称 + 副标题 + 齿轮）→ `ProviderUsageCard` → 本地统计（req / err / token）→ 最近请求列表 → 操作按钮
- 头部副标题：复用 `appState.providerSubtitle(providerID)`
- 操作按钮：「测试连接」调 `appState.testProvider`；「在网页查看」打开 `usageDashboardURL`
- **验证**：编译通过；切换到 provider Tab 可见用量卡片

#### 23.5 重构 `MenuPanelView` 为 TabView 容器
- 重写 `MenuPanelView.swift`：TopBar + SegmentedControl + TabView
- `selectedTab` 状态绑定 Overview 行点击与 SegmentedControl
- 移除 `ProviderListView` / `APIKeyManagerView` / `UsageView` 的引用（文件保留，待 23.6 清理）
- 保留 `onAppear` 中的 `startMetricsRefresh` / `startUsageRefresh` / `startOAuthRefresh` / `bootstrapOAuth`
- **验证**：`swift run BinviaApp --smoke-test` 全过；GUI 启动后面板可切换 Tab

#### 23.6 最近请求列表 + 清理与文档
- `AppState` 新增 `@Published recentEntries: [RequestLogEntry]`，随 2s metrics 轮询刷新（倒序最近 10 条）
- 新建 `Sources/BinviaApp/Views/RecentRequestsView.swift`：Provider Tab 底部展示最近请求（时间 / 模型 / token / 耗时 / 状态）
- 删除 `ProviderListView.swift`（功能已合并到 Overview）
- 删除 `UsageView.swift`（功能已合并到 Overview Summary）
- `APIKeyManagerView.swift` 保留（设置面板 `SettingsGatewayKeysPane` 仍可能复用其行视图；若不复用则一并删除）
- 更新 `CODEBUDDY.md` 的「GUI」章节描述
- 更新 README GUI 截图说明（如有）
- **验证**：`swift build` 无警告；`make test` 全过

### Phase 24（可选，后续迭代）— 信息密度优化

- Overview Summary 增加运行时长（从服务器启动时间派生）
- 健康度行增加错误率指示（错误数 > 0 时红色标记）

---

## 5. 测试验证

### 5.1 编译与 smoke test

```bash
swift build                           # 无警告
swift run BinviaApp --smoke-test      # 全过（验证应用启动不崩溃）
make test                             # BinviaCheck 全过（验证 Core 未受影响）
```

### 5.2 手动验证清单

| # | 场景 | 期望 |
|---|---|---|
| 1 | 0 个 provider 已配置 | 主面板仅显示 Overview，无 SegmentedControl |
| 2 | 1 个 provider 已配置 | SegmentedControl 显示 [概况 \| DeepSeek]，可切换 |
| 3 | 3 个 provider 已配置 | SegmentedControl 显示 [概况 \| DeepSeek \| Antigravity \| Kimi] |
| 4 | DeepSeek Tab | 显示余额卡片（多 Key 余额逐行）+ 本地统计 |
| 5 | Antigravity Tab | 显示配额窗口 ProgressView + 模型配额 |
| 6 | Kimi Tab | 显示余额卡片 |
| 7 | OpenAI Tab（无用量 API） | Tab 不出现（未配置时不显示）；配置后 Tab 显示「暂无用量数据」+ 本地统计 + token |
| 8 | Overview 点击 DeepSeek 行 | SegmentedControl 切换到 DeepSeek Tab |
| 9 | TopBar 齿轮点击 | 打开设置窗口 |
| 10 | TopBar Keys 点击 | 打开设置窗口并跳转到「网关密钥」面板 |
| 11 | Provider Tab 齿轮点击 | 打开设置窗口并跳转到对应 provider 面板 |
| 12 | 设置面板用量卡片 | 与重构前视觉一致（验证抽取无回归） |
| 13 | 发起一次 chat 请求（流式） | 结束后 Provider Tab 的 token 统计增加；最近请求列表出现该条记录（含 token） |
| 14 | 发起一次 chat 请求（非流式） | 同上；token 立即写入（非流式整段 JSON 一次解析完成） |
| 15 | 上游不返回 usage 的响应 | 该请求 token 显示「—」，不报错、不影响透传 |

### 5.3 BinviaCheck 单测补充

UI 视图难以在 `BinviaCheck`（无 XCTest）中测试，但可补充纯数据派生逻辑测试：

- **TokenUsageExtractor**（22.0）：流式带 usage 的 chunk、非流式整段 JSON、无 usage 的响应、多 usage chunk 取最后一个、chunk 跨事件边界
- `RequestLogger.summary()` token 聚合正确性（含 0 / nil token 的条目）
- `AppState` 新增派生属性（如 `totalRequests` / `activeProviderCount` / `totalTokens`）—— 可在 `BinviaCheck` 中构造 `AppState` 验证计算正确性
- `ProviderHealthRow` 的关键用量优先级逻辑若抽为纯函数 —— 可单测

---

## 6. 风险与权衡

### 6.1 SegmentedControl 宽度限制

**风险**：已配置 provider ≥ 6 个时，`Picker(.segmented)` 会等分压缩，文字截断不可读。

**对策**：
- 已配置 provider ≤ 5 个：使用原生 `Picker(.segmented)`
- 已配置 provider ≥ 6 个：改为顶部横向 `ScrollView` + chip 按钮（自定义样式），点击切换 `selectedTab`
- 实现时先做 `.segmented` 版本，验证 6+ 场景后再决定是否切 chip

### 6.2 TabView 在 MenuBarExtra 中的稳定性

**风险**：`TabView` 在 `MenuBarExtra(.window)` 中可能存在切换动画卡顿或高度跳变。

**对策**：
- 使用 `TabView(selection:)` + `selectedTab` binding，避免 `.tabViewStyle(.page)` 的滑动冲突
- 每个 Tab 内容用 `ScrollView` 包裹，高度自适应；外层 `MenuPanelView` 不设固定高度
- 若高度跳变严重，给 TabView 内容区设 `.frame(minHeight: 320, maxHeight: 480)`

### 6.3 设置面板用量卡片回归

**风险**：抽取 `ProviderUsageCard` 时遗漏 `SettingsProviderPane` 的边界条件（如 `isUserDefined` 跳过）。

**对策**：
- 23.1 步骤独立提交，先迁移不改行为
- 23.5 重构 `MenuPanelView` 前，先手动验证设置面板用量卡片视觉与重构前一致
- 若发现差异，回退 23.1 单步

### 6.4 Token 采集对透传的侵入风险

**风险**：`TokenUsageExtractor` 包裹上游流若解析出错，可能污染透传数据或导致流提前结束。

**对策**：
- Extractor 的 `process(_:)` **始终原样返回入参 chunk**，解析逻辑完全独立于返回值
- 解析失败一律 `try?` 静默吞掉，返回 nil，绝不影响透传
- 抽取逻辑单测先行（22.0），用固定 chunk 序列验证「输入 = 输出」
- 路由层包裹用 `Task.detached`（与现状一致），Extractor 为单任务内可变对象（仿 `IteratorHandler`），不引入跨任务共享状态

### 6.5 已配置 provider 变化时的 Tab 选择

**风险**：用户在设置面板移除某 provider 后，`selectedTab` 仍指向该 providerID，TabView 显示空白。

**对策**：
- `MenuPanelView` 监听 `configuredProviders` 变化：若 `selectedTab` 不在新列表中且不是 "overview"，重置为 "overview"
- 使用 `.onChange(of: configuredProviders.map(\.id))` 检测变化

### 6.6 APIKeyManagerView 移除的兼容性

**风险**：用户习惯从主面板管理网关 Key，移除后找不到入口。

**对策**：
- TopBar 顶部显式提供 `key.fill` 图标按钮，tooltip「网关密钥」，点击跳转 `SettingsPane.gatewayKeys`
- Overview Summary 卡片底部可加一行小字提示「N 个网关密钥已配置 · 管理」

### 6.7 流式 token 回填延迟

**风险**：流式请求在响应返回后仍持续数秒，token 需流结束才回填，「最近请求」可能短暂显示「—」。

**对策**：
- 接受短暂延迟（下一轮 2s 轮询补上），并在 UI 对 nil token 显示「—」而非 0
- `/v1/usage` 的 entries 直接引用 `RequestLogger` 内存数组，回填后自然包含 token，无额外处理

---

## 7. 文件变更清单

### 新增

| 文件 | 职责 |
|---|---|
| `Sources/BinviaCore/Networking/TokenUsageExtractor.swift` | 上游流透传 + 旁路解析 `usage`（22.0） |
| `Sources/BinviaApp/Components/ProviderUsageCard.swift` | 用量卡片共享组件（从 `SettingsProviderPane` 抽取） |
| `Sources/BinviaApp/Components/ProviderHealthRow.swift` | Overview 中的 provider 健康度行 |
| `Sources/BinviaApp/Views/OverviewTabView.swift` | 首页概况 Tab |
| `Sources/BinviaApp/Views/ProviderTabView.swift` | 单个 provider 详情 Tab |
| `Sources/BinviaApp/Views/RecentRequestsView.swift` | 最近请求列表（token / 耗时 / 状态） |

### 修改

| 文件 | 变更 |
|---|---|
| `Sources/BinviaCore/Monitoring/RequestLogger.swift` | 新增 `TokenUsage`；`RequestLogEntry` 加 `id`/`tokens`；`ProviderUsage` 加 token 聚合；新增 `updateTokens(id:)` |
| `Sources/BinviaCore/Server/RouteHandler.swift` | `handleChat` 用 `TokenUsageExtractor` 包裹上游流，流结束回填日志 |
| `Sources/BinviaApp/AppState.swift` | 新增 `recentEntries` 派生（2s 轮询刷新）；token/请求派生属性 |
| `Sources/BinviaApp/Views/MenuPanelView.swift` | 重构为 TopBar + SegmentedControl + TabView 容器 |
| `Sources/BinviaApp/Views/Settings/SettingsProviderPane.swift` | `usageSection` 改为引用 `ProviderUsageCard` |
| `Sources/BinviaCheck/main.swift` | 新增 TokenUsageExtractor / summary 聚合 / AppState 派生属性单测 |
| `CODEBUDDY.md` | 「GUI」章节描述更新 |

### 删除

| 文件 | 原因 |
|---|---|
| `Sources/BinviaApp/Views/ProviderListView.swift` | 功能合并到 Overview 健康度列表 |
| `Sources/BinviaApp/Views/UsageView.swift` | 功能合并到 Overview Summary |
| `Sources/BinviaApp/Views/APIKeyManagerView.swift` | 已有 `SettingsGatewayKeysPane`，主面板不再展示（待 23.6 确认是否被复用） |

---

## 8. 验收标准

- [ ] `swift build` 无警告
- [ ] `swift run BinviaApp --smoke-test` 全过
- [ ] `make test`（BinviaCheck 277 项 + 新增 token 用例）全过
- [ ] 手动验证清单（§5.2）15 项全过
- [ ] 设置面板用量卡片视觉与重构前一致
- [ ] 0/1/3/6 个已配置 provider 场景下 SegmentedControl 均可用
- [ ] 流式 / 非流式请求的 token 均能在主面板正确展示；无 usage 响应不报错
- [ ] macOS 14 / 15 上 Tab 切换稳定，无面板消失/闪烁
