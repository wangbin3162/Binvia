# 供应商令牌手动选择计划

## 1. 目标

将供应商凭据从“多个令牌自动轮换”调整为“多个令牌可保存，但每个供应商由用户手动选择一个生效令牌”。

目标行为：

- 每个供应商可以保存多个 API Key / Access Token。
- 令牌列表每行增加启用勾选。
- 每个供应商最多一个令牌处于启用状态。
- 新增第一个令牌时默认启用它。
- 用户切换勾选项后，后续请求使用新的令牌。
- 请求失败不自动切换其他令牌；用户需要在供应商设置中手动切换。
- 保留同一令牌上的网络层重试，例如连接失败、408、429、5xx 的重试策略；这不是令牌轮换。
- CodeBuddy 的 OAuth 登录 token 继续与模型调用 token 分离，仅用于现有积分/用量查询流程。

## 2. 当前实现确认

### 2.1 已有多个令牌能力

`ProviderConfig.apiKeys` 当前已经是 `[KeyedToken]`，包含 `label` 和 `value`，配置文件也已经兼容旧版 `[String]` 格式。

相关文件：

- `Sources/BinviaCore/Config/RouteConfig.swift`
- `Sources/BinviaCore/Provider/ChatModels.swift`
- `Sources/BinviaApp/AppState.swift`
- `Sources/BinviaApp/Views/Settings/SettingsProviderPane.swift`

### 2.2 当前确实存在两处 token 自动轮换

- `CodeBuddyCNProvider`：多个 token 在握手阶段遇到 401、403、429、502 时轮换。
- `DeepSeekProvider`：多个 key 在握手阶段遇到 401、403、429、502 时轮换。

其他当前内置 API Key 供应商主要从 `credential.apiKey` 读取单个 key，没有发现同等的 token 列表轮换逻辑。通用的 `ProviderHTTPClient` 仍有 HTTP 层重试，但它重试的是同一个请求和同一个凭据，不属于 token 轮换。

### 2.3 当前配置读取会默认取首个令牌

`RouteConfig.credential(for:)` 在 `credential.apiKey` 为空时，会把 `apiKeys` 中第一个非空令牌填入 `credential.apiKey`。

因此当前列表顺序实际上影响默认调用令牌，但没有显式的令牌启用状态，也无法通过 UI 清楚表达“当前生效的是哪一个”。

### 2.4 当前 UI 已有令牌增删，但没有启用选择

`SettingsProviderPane` 已有：

- API Key 供应商的带标签令牌列表；
- CodeBuddy 的模型调用 token 列表；
- 添加和删除令牌；
- 即时保存配置。

本计划是在现有列表基础上增加选择状态，不重做供应商设置页面。

## 3. 设计方案

### 3.1 配置模型

给 `KeyedToken` 增加令牌级启用字段，例如：

```swift
public var enabled: Bool
```

建议约束：

- 一个供应商的 `apiKeys` 中最多一个 `enabled == true`。
- 空列表表示没有配置令牌。
- 列表非空但没有启用项时，供应商视为没有可调用凭据，并返回明确的缺少启用令牌错误。
- `enabled` 只表示该令牌是否用于请求，不改变供应商级 `ProviderConfig.enabled`。

### 3.2 旧配置迁移

旧配置中的 `apiKeys` 没有 `enabled` 字段，解码时按以下规则迁移：

- 令牌列表为空：保持为空。
- 令牌列表非空：第一个非空令牌设为启用，其余设为未启用。
- 旧的 `credential.apiKey` 如果存在且与某个列表令牌相同，优先将该令牌设为启用，以保持用户当前行为。
- 如果旧 `credential.apiKey` 不在列表中，则将它作为兼容的已启用令牌补入列表，避免静默丢失凭据。
- 迁移后保存时写入新版对象格式；不删除旧字段以外的无关配置。

环境变量仍作为无配置文件时的兼容兜底，但不参与多个令牌选择，也不参与自动轮换。计划实现时需要明确优先级：已配置令牌优先，其次是 `credential.apiKey`，最后才是供应商环境变量。

### 3.3 生效令牌解析

在 `RouteConfig` 增加统一的“当前生效令牌”解析方法，供路由和供应商使用：

```swift
selectedToken(for providerID: String) -> KeyedToken?
```

解析规则：

1. 返回该供应商唯一的 `enabled` 且值非空令牌。
2. 对旧配置兼容时按迁移规则选择第一个有效令牌。
3. 没有启用令牌时，不把 `apiKeys` 中任意其他令牌自动当作当前令牌。
4. 环境变量只作为完全没有配置令牌时的单一兼容凭据。

`credential(for:)` 应改为使用该选择结果填充 `credential.apiKey`，而不是无条件取 `apiKeys.first`。

### 3.4 UI 交互

沿用现有 `tokenRow` 和按索引渲染方式，在每行前增加 Checkbox：

- 勾选某行：该行成为当前生效令牌，并取消同一供应商其他行的勾选。
- 点击当前已勾选项：不允许变成“多选”或空选，保持至少一个启用项；如需停用全部令牌，应通过删除令牌或明确的“停用供应商”操作完成。
- 新增第一个令牌：自动设置 `enabled = true`。
- 新增后续令牌：默认未启用，不改变当前生效令牌。
- 删除当前令牌：若仍有其他令牌，自动启用删除位置附近的一个令牌，并持久化；若无剩余令牌，保持空列表。
- 列表操作继续使用 `enumerated` + index，不按 label 或 value 定位。
- 行内显示当前启用状态，避免只依赖列表顺序判断。

CodeBuddy 的“模型调用 token”列表和 API Key 供应商列表都使用同一套选择语义。CodeBuddy OAuth 登录区域保持独立，不把 OAuth 登录 token 混入模型调用令牌选择。

### 3.5 Provider 行为

移除供应商级 token 列表读取和失败轮换：

- `CodeBuddyCNProvider`：删除 `resolveTokens`、轮换循环和 `isTokenRotationError`；每次请求只使用解析后的当前启用 token。
- `DeepSeekProvider`：删除 `resolveKeys`、轮换循环和 `isTokenRotationError`；每次请求只使用当前启用 key。
- 其他 API Key 供应商继续读取 `credential.apiKey`，由统一的 `RouteConfig.credential(for:)` 提供当前启用令牌。
- 不修改供应商的请求格式、模型转换、SSE 处理和 CodeBuddy 的 OAuth 用量查询。
- 不删除 `ProviderHTTPClient` 的同 key 网络重试；需要在注释和文档中区分“HTTP 重试”和“凭据轮换”。

错误行为：当前令牌收到 401、403、429 或其他上游错误时，直接返回错误，不尝试列表中的其他令牌。客户端可以根据错误提示进入设置切换令牌。

## 4. 预计修改范围

### Slice 1：配置模型和迁移

文件：

- `Sources/BinviaCore/Config/RouteConfig.swift`
- `Sources/BinviaCore/Provider/ChatModels.swift`（仅在类型定义需要调整时）
- `Sources/BinviaCore/Config/ConfigStore.swift`（仅在迁移保存需要调整时）

动作：增加 `KeyedToken.enabled`、旧配置兼容解码、唯一启用约束和 `selectedToken` 解析。

验证：旧版字符串数组、新版对象数组、旧 `credential.apiKey`、空列表、多启用项都能得到确定结果。

### Slice 2：AppState 和设置 UI

文件：

- `Sources/BinviaApp/AppState.swift`
- `Sources/BinviaApp/Views/Settings/SettingsProviderPane.swift`
- 如有必要，相关令牌行组件文件

动作：增加按索引启用/切换方法；保存时规范化为最多一个启用项；在 API Key 和 CodeBuddy token 列表加入 Checkbox；处理新增、删除当前令牌的边界。

验证：切换供应商令牌后配置立即落盘；重启/热加载后选择保持；新增第二个令牌不改变当前生效令牌；删除当前令牌后选择稳定。

### Slice 3：供应商移除 token 轮换

文件：

- `Sources/BinviaCore/Providers/CodeBuddy/CodeBuddyCNProvider.swift`
- `Sources/BinviaCore/Providers/DeepSeek/DeepSeekProvider.swift`
- 可能需要同步的 provider 注释和 README 文案

动作：改为单令牌调用，删除请求失败后的令牌轮换；保留同 key 的网络层重试和现有协议适配。

验证：mock 上游对当前 token 返回 401/403/429 时不会收到第二个 token 的请求；选中另一 token 后下一次请求才使用新 token；无启用 token 时返回明确错误。

### Slice 4：测试和文档同步

文件：

- `Sources/BinviaCheck/main.swift`
- `README.md`
- 必要时更新 `docs/build-release-guide.md` 中关于 DeepSeek/CodeBuddy 轮换的描述

动作：增加配置迁移、唯一启用、手动切换、无自动轮换的回归测试；删除 README 中“上游多 Key 自动轮换”的不准确表述。

验证：`make test`、`swift build`；检查配置 JSON 编解码和现有供应商连接测试不回归。

## 5. 风险与边界

- `ProviderConfig.enabled` 是供应商级开关，不能与令牌级 `KeyedToken.enabled` 混用。
- CodeBuddy 的 `credential.accessToken` / `refreshToken` 服务于 OAuth 用量查询，不能因为令牌选择改造而误删或改成模型调用 token。
- 环境变量没有 UI 选择状态。若同时存在配置令牌和环境变量，必须保证配置中的启用令牌优先，避免用户勾选后请求仍使用环境变量。
- `ProviderHTTPClient` 的 429/5xx 重试可能仍然产生多次相同 token 请求；这属于网络重试，不是 token 切换，文档和测试需要明确区分。
- 旧版配置如果有多个 token，迁移后只启用一个，不能继续隐式轮换。
- 当前请求错误不会自动修改令牌启用状态，也不应因 401/403 自动禁用 token；是否停用由用户手动决定。
- “手动切换”需要确保热更新后的 `RouteHandler` 获取新配置，不能只更新 UI 草稿而未更新实际服务配置。

## 6. 完成标准

- 每个供应商可保存多个令牌，并明确显示唯一生效令牌。
- 新增第一个令牌默认启用；新增后续令牌默认不抢占当前令牌。
- 所有 provider 请求只使用当前生效令牌，不因请求失败自动尝试其他令牌。
- DeepSeek 和 CodeBuddy 的现有协议适配、SSE、用量查询和 OAuth 流程不受影响。
- 旧配置可读取且不会静默丢失凭据。
- `make test` 和 `swift build` 通过。
- README 与设置页文案不再声称存在上游多 Key 自动轮换。
