# Binvia 任务清单

> 更新：2026-08-01（Phase 6-11 GUI 全部完成）
> 详细背景见：`implementation-plan.md`、`codexbar-analysis.md`、`omniroute-analysis.md`、`gui-implementation-guide.md`

## Phase 0 — 工程骨架（已完成 ✅ 2026-08-01）

- [x] `Package.swift`：BinviaCore / BinviaServer / BinviaCLI 三目标
- [x] Core：`Provider` 协议、`ProviderDescriptor`、`ProviderRegistry`、`Model`、`ChatModels`
- [x] Core：`ConfigStore`（config.json 读写）
- [x] Core：`APIKeyAuthenticator`（Bearer / x-api-key / env key）
- [x] Core：`ProviderHTTPClient`（上游 HTTP，流式/错误透传）
- [x] Core：`Router`（provider/model 解析、别名、裸模型归属）
- [x] Server：`HTTPServer`（原生 socket）、请求解析、路由分发
- [x] Server：端点 `/v1/models`、`/v1/chat/completions`、`/v1/health`、`/v1/usage`
- [x] Providers：DeepSeek（api-key 直通，端到端可用，`DEEPSEEK_BASE_URL` 可覆盖）
- [x] Providers：CodeBuddy / Antigravity 描述符注册（stub）
- [x] CLI：`serve` / `providers list` / `test` / `config path`
- [x] 构建验证 `swift build` + 本地 mock 端到端测试（SSE 流式/非流式/认证/用量）

## Phase 1 — 核心完善（已完成 ✅ 2026-08-01）

- [x] SSE 流式转发（流式 + JSON 重聚合）：`SSEParser`/`SSEJSONAggregator` 共享工具，强制流式上游对非流式客户端自动聚合
- [x] `testConnection` 可用性测试 + CLI `providers test` / `oauth login`
- [x] 动态模型获取 + 缓存：`ModelCache`（300s TTL），`/v1/models` 合并静态+动态
- [x] 上游重试策略：`ProviderHTTPRetryPolicy`（408/429/5xx 退避，尊重 Retry-After）
- [x] 多 api-key / 密钥轮换：`ProviderConfig.apiKeys`，上游 401/403 自动换 key

## Phase 2 — CodeBuddy 接入（已完成 ✅ 2026-08-01）

- [x] OAuth 设备码流（获取/刷新 token）：`CodeBuddyOAuthClient`（requestDeviceCode → pollToken code===0/11217 → refresh）
- [x] `CodeBuddyProvider` 执行器（强制流式 + JSON 重聚合）
- [x] 模型目录（GLM 系列等 15 个）
- [x] 可用性测试（OAuth 自动 refresh 探测）+ mock 验证 12 项通过

## Phase 3 — Antigravity 接入（已完成 ✅ 2026-08-01）

- [x] Google OAuth（PKCE）+ projectId 引导：`AntigravityOAuthClient`（loadCodeAssist → onboardUser）
- [x] cloudcode 信封翻译器（request/response 双向）：`AntigravityEnvelopeTranslator`
- [x] `AntigravityProvider` 执行器（流式，401 自动 refresh 重试）
- [x] 可用性测试 + mock 验证 40 项断言通过

## Phase 4 — 监控（已完成 ✅ 基础版在 Phase 0 完成）

- [x] 请求日志（时间/模型/供应商/耗时/token/状态）：`RequestLogger`
- [x] 用量统计（按供应商/模型聚合）：`UsageSummary`
- [x] `GET /v1/usage` 导出接口
- [x] 健康检查 `GET /v1/health`

## Phase 5 — 扩展与收尾（已完成 ✅ 2026-08-01）

- [x] 测试用例（单元 + 集成）：自包含可运行测试 `BinviaCheck`（96 用例全过，本机无需 Xcode）
- [x] README 使用文档
- [x] 打包脚本（Makefile / Scripts/build.sh，产物到 `bin/`）
- [ ] 扩展其他供应商（本地探测型，如 Antigravity 本地 LSP）※ 二期

## Phase 6 — GUI 骨架（已完成 ✅ 2026-08-01）

- [x] `Package.swift` 新增 `BinviaApp` target
- [x] `BinviaApp.swift`：`@main` + `MenuBarExtra(.window)` + 菜单栏图标（运行/停止动态切换 `bolt.shield.fill`/`bolt.shield`）
- [x] `AppState.swift`：`@MainActor`，配置加载 + 服务器 start/stop 生命周期 + `--smoke-test` 无界面自检
- [x] `MenuPanelView.swift`：面板骨架（标题 + 服务器状态区 + Provider/Key/Usage 分区 + 底部操作）
- [x] `ServerStatusView.swift`：启停按钮 + 状态指示灯
- [x] `HTTPServer`：新增 `setHandler()`（运行时替换）与 `stop()`（poll 轮询 + 关 fd 优雅停止）
- [x] 验证：应用可启动（进程存活），菜单栏出现图标，可启停服务器（smoke test 10 项通过）

## Phase 7 — Provider 管理 GUI（已完成 ✅ 2026-08-01）

- [x] `ProviderListView.swift`：Provider 列表卡片（名称 + 认证状态 + 请求计数 + 齿轮进入配置）
- [x] `ProviderDetailView` — DeepSeek：API Key 输入（密码遮蔽）+ 多 Key 轮换 + 保存
- [x] `ProviderDetailView` — CodeBuddy：OAuth 登录按钮（设备码流，自动打开浏览器）
- [x] `ProviderDetailView` — Antigravity：OAuth 登录按钮（PKCE 流，授权码输入对话框）
- [x] `OAuthLoginButton.swift`：封装 OAuth 登录交互（四态：等待/输入/成功/失败）
- [x] 连通性测试按钮 + 三态结果（idle / testing / ok / failed）
- [x] 配置持久化（`ConfigStore.save()`）
- [x] 验证：三种 Provider 视图编译通过；配置/凭据持久化由 smoke test 覆盖

## Phase 8 — API Key 管理 GUI（已完成 ✅ 2026-08-01）

- [x] `APIKeyManagerView.swift`：Key 列表 + 生成 + 删除 + 复制（带"已复制"反馈）
- [x] `APIKeyInputField.swift`：密码输入框组件（显示/隐藏切换）
- [x] Key 生成逻辑（`SecRandomCopyBytes` → `sk-tg-` + 32 hex）
- [x] 配置持久化到 `config.apiKeys`
- [x] 验证：smoke test 覆盖 Key 格式、持久化、以及 401/200 网关认证

## Phase 9 — 监控与设置 GUI（已完成 ✅ 2026-08-01）

- [x] `UsageView.swift`：请求统计展示（总数/错误/各 Provider 分布，按请求数降序）
- [x] Metrics 定时刷新（2s Timer + Task，onAppear 启动 / onDisappear 停止）
- [x] `SettingsView.swift`：端口配置 + 配置路径 + 环境变量说明 + 保存并应用
- [x] 配置热更新（`HTTPServer.setHandler` 运行时替换，改端口自动重启）
- [x] 验证：smoke test 覆盖热更新后服务仍可用

## Phase 10 — GUI 打磨与打包（已完成 ✅ 2026-08-01）

- [x] 菜单栏图标动态状态（运行/停止）
- [x] OAuth 登录进度提示与错误展示（`OAuthFlowState` 五态）
- [x] `HTTPServer` handler 运行时替换接口（`setHandler`）
- [x] `build.sh` 增加 `BinviaApp` 产物（打包为 `bin/Binvia.app`，LSUIElement 仅菜单栏）
- [x] README 补充 GUI 使用说明
- [x] 端到端验证：`swift run BinviaApp --smoke-test` 12 项全过；GUI 进程可启动；BinviaCheck 96 用例全过

## Phase 11 — 设置面板重构（已完成 ✅ 2026-08-01）

- [x] 设置窗口改为 CodexBar 风格：左侧栏（服务器 / 网关密钥 / 供应商）+ 右侧 `Form(.grouped)` 详情
- [x] 侧栏供应商列表带品牌图标（`ProviderBrandIcon`，DeepSeek/CodeBuddy 蓝紫渐变、Antigravity Google 四色）+ 配置状态圆点 + 已配置计数 + 右键启用/停用
- [x] `SettingsProviderPane`：头部行（图标 + 名称 + 副标题 + 启用开关），连接流程参考 OmniRoute `EditConnectionModal`
  - DeepSeek：API Key 多行输入（多 Key 轮换）+ 测试连接 + 保存
  - CodeBuddy：OAuth 设备码登录 + 手动 Access Token 粘贴
  - Antigravity：OAuth PKCE 登录（内联授权码输入）+ 手动 Access/Refresh Token 粘贴
- [x] 连通性测试结果 Section（idle/testing/ok/failed）+ 信息 Section（别名/Base URL/认证方式/已配置）
- [x] `SettingsGeneralPane`：监听地址/端口 + 配置路径 + 环境变量说明 + 保存并应用（保留原热更新）
- [x] `SettingsGatewayKeysPane`：网关 Key 列表 + 复制/删除 + 生成新 Key
- [x] 窗口尺寸对齐 CodexBar（880×620，最小 760×520，侧栏 240）
- [x] `SettingsWindowController` 持共享 `SettingsSelectionModel`：菜单栏点 Provider 齿轮可直接切换到对应面板
- [x] 菜单栏面板 Provider 配置入口统一收敛到设置窗口（删除原面板内导航 `ProviderDetailView`）
- [x] 验证：`swift build` 无警告；BinviaCheck 96 用例全过；`--smoke-test` 12 项全过；GUI 进程可启动
