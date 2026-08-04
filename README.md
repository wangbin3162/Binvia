# Binvia

本地 AI 供应商聚合路由网关：连接 DeepSeek / 腾讯 CodeBuddy / Google Antigravity 等供应商，在本地端口提供 **OpenAI 兼容 API**，供 Claude Code、Codex、各类 SDK 通过 api-key 调用，并带请求监控。

技术框架基于 [CodexBar](https://github.com/steipete/CodexBar)（Swift + 原生 socket，零外部服务器依赖），供应商注册/路由/代理设计借鉴 OmniRoute。

## 功能

- **供应商注册**：`ProviderDescriptor` + `ProviderRegistry` 注册表，新增供应商只需一个文件 + 一行登记。
- **模型路由**：`provider/model` 或别名（`ds`/`cbcn`/`agy`），支持裸模型名自动归属。
- **OpenAI 兼容 API**：`/v1/chat/completions`（流式 + 非流式）、`/v1/models`。
- **api-key 认证**：`Authorization: Bearer` / `x-api-key`，配置或环境变量 key 白名单。
- **SSE 流式透传**：逐事件实时转发；强制流式上游（CodeBuddy/Antigravity）对非流式客户端自动 JSON 重聚合。
- **上游重试**：`ProviderHTTPClient` 对 408/429/5xx 指数退避重试，尊重 `Retry-After`。
- **动态模型 + 缓存**：`/v1/models` 合并静态目录与各供应商动态模型，`ModelCache` 300s TTL。
- **多 api-key 轮换**：上游 401/403 时自动切换到下一个 key。
- **监控**：`/v1/usage` 请求日志 + 按供应商/模型聚合统计。
- **可用性测试**：`BinviaCLI test <provider>`。

## 已接入供应商

| Provider | 别名 | 认证 | 状态 |
|---|---|---|---|
| deepseek | `ds` | api-key | ✅ 可用（Phase 0/1） |
| codebuddy-cn | `cbcn` | OAuth 设备码 | ✅ 已实现（Phase 2，需 `oauth login`） |
| antigravity | `agy` | Google OAuth PKCE | ✅ 已实现（Phase 3，需 `oauth login`） |
| openai | `openai` | api-key | ✅ 已实现（Phase 14） |
| opencode | `oc` | api-key | ✅ 已实现（Phase 15） |
| kimi | `kimi` | api-key | ✅ 已实现（Phase 15，强制流式） |
| opencode-go | `ocgo` | api-key | ✅ 已实现（Phase 18） |
| xiaomi-mimo | `mimo` | api-key | ✅ 已实现（Phase 18） |
| qwen-cloud | `qwc` | api-key | ✅ 已实现（Phase 18） |
| zai | `zai` | api-key | ✅ 已实现（Phase 18，Anthropic 兼容） |
| minimax | `mm` | api-key | ✅ 已实现（Phase 18，Anthropic 兼容） |
| codex | `cx` | OpenAI OAuth PKCE | ✅ 已实现（Phase 24，ChatGPT 订阅账号；Responses API 翻译 + 用量展示） |
| cursor | `cu` | api-key / IDE 接入 | ✅ 已实现（Phase 19/20，OpenAI 兼容；Phase 20 支持从 Cursor IDE 自动读取登录令牌） |

## 快速开始

### 构建

```bash
swift build
```

### 启动服务器

```bash
# 方式一：默认配置（监听 localhost:20427，API 端点 http://localhost:20427/v1）
swift run BinviaServer

# 方式二：指定配置/端口
swift run BinviaServer --port 20427 --config ~/.config/binvia/config.json
```

### 登录供应商（OAuth）

```bash
# 腾讯 CodeBuddy（设备码：自动打开浏览器授权）
swift run BinviaCLI oauth login codebuddy-cn

# Google Antigravity（PKCE：打开浏览器授权后把重定向地址/code 粘贴回终端）
swift run BinviaCLI oauth login antigravity

# OpenAI Codex（ChatGPT 订阅账号，PKCE：打开浏览器授权后把重定向地址/code 粘贴回终端）
swift run BinviaCLI oauth login codex
```

登录凭据自动写入 `~/.config/binvia/config.json`。

### Cursor（IDE 接入）

Cursor 支持两种认证方式，**无需单独购买 Cursor API key**（Pro/Max 订阅即可）：

- **IDE 自动发现（默认）**：Binvia 请求时自动从 Cursor IDE 的本地数据库读取登录令牌
  （`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`），携带 IDE 头走
  `https://api2.cursor.sh/v1/chat/completions`。令牌约 24h 轮换，每次请求实时读取（TTL 缓存 4h），
  无需手动维护。可在设置面板「Cursor IDE 接入」区块查看检测状态/过期时间，或用 CLI 排查：

  ```bash
  swift run BinviaCLI cursor status   # 检测 IDE 令牌：有无/过期时间/machineId
  ```

- **API Key 兜底**：设置 `CURSOR_API_KEY`（或 config `providers.cursor.credential.apiKey`）后，
  走官方公开 REST `https://api.cursor.com/v1`，与 OpenAI 兼容供应商行为一致。

> 说明：Cursor 上游为私有协议（Connect-RPC protobuf，需 HTTP/2），模型走其订阅后端；本实现仅支持 Chat Completions（无工具调用）。
> **命名模型需要 Cursor Pro/Max 套餐**（免费套餐会被上游拒绝：`Free plans can only use Auto`）。
> `CURSOR_BASE_URL` 环境变量可覆盖上游端点（测试/镜像场景）。

### 调用

```bash
# 健康检查
curl http://localhost:20427/v1/health

# 模型列表（含动态模型）
curl http://localhost:20427/v1/models

# 聊天（流式）
curl -N http://localhost:20427/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-api-key>" \
  -d '{"model":"deepseek/deepseek-v4-pro","messages":[{"role":"user","content":"hi"}],"stream":true}'

# 用量
curl http://localhost:20427/v1/usage
```

### CLI

```bash
swift run BinviaCLI providers list            # 列出供应商与模型
swift run BinviaCLI test deepseek             # 测试供应商可用性
swift run BinviaCLI oauth login codebuddy-cn  # OAuth 登录
swift run BinviaCLI cursor status             # Cursor IDE 令牌检测
swift run BinviaCLI config path               # 配置文件路径
swift run BinviaCLI serve                     # 启动服务器
```

### GUI（菜单栏应用，macOS 14+）

```bash
# 开发运行（菜单栏出现 Binvia 图标）
swift run BinviaApp

# 无界面自检（配置读写 / 服务器启停 / 热更新）
swift run BinviaApp --smoke-test

# 打包（产物含 bin/Binvia.app）
./Scripts/build.sh
open bin/Binvia.app
```

菜单栏面板支持：

- **概况 Tab**（默认页）：服务器启停（Start/Stop + 状态灯）、总请求/错误/活跃 provider/总 token 汇总、各已配置 provider 健康度列表（余额 / 配额 / token 一目了然，点击行直达对应 provider Tab）。
- **Provider Tab**：顶部 SegmentedControl 切换已配置的供应商；每个 Tab 展示头部 + 用量卡片（余额 / 配额窗口 / 模型配额，5min 轮询 + 手动刷新）、本地请求统计、最近请求明细（时间 / 模型 / token / 耗时 / 状态）、测试连接与网页看板入口。
- **网关密钥**：仅保留在设置面板；主面板右上角 `key.fill` 图标一键跳转。
- **设置 / 退出**：主面板右上角 `gearshape` / `xmark.rectangle` 图标。

**设置窗口**（点面板底部 Settings 打开）为 CodexBar 风格：左侧栏 + 右侧详情，全部配置均在面板中完成，无需手改文件：

- **服务器**：监听地址固定为本机 localhost（不可修改）；端口默认 20427，可改，保存即热更新（运行中替换 handler，无需重启）。「API 端点」区展示 `http://localhost:<端口>/v1` 并提供一键复制，供 Claude Code / opencode / curl 等配置。
- **供应商**：DeepSeek 填 API 令牌（支持带标签的多 Key 轮换，仿 CodexBar 令牌账户：标签 + 密钥 + 添加/移除）；CodeBuddy 一键设备码 OAuth 登录或粘贴 Access Token；Antigravity / Codex 一键 PKCE OAuth 登录（粘贴授权码）或粘贴 Access/Refresh Token。每个供应商支持「测试连接」与启用/停用开关。
- **用量**：供应商面板自动展示用量——DeepSeek（多 Key 余额）、Kimi（余额）、Antigravity（模型配额 + 周窗口）、Codex（5h / 7d 双配额窗口）每 5 分钟轮询 + 手动「刷新用量」；z.ai、opencode、CodeBuddy CN 上游未提供可用的公开用量 API（CodeBuddy CN 官方接口返回 500），面板提供「在网页查看」跳转对应网页看板（智谱 `bigmodel.cn/finance-center/finance/overview`、opencode `opencode.ai/zh/zen`、CodeBuddy `codebuddy.cn/profile/usage`）。
- **网关密钥**：生成/复制/删除 `sk-bv-` 网关 Key。

## 配置

配置文件：`~/.config/binvia/config.json`（`BINVIA_CONFIG` 可覆盖路径）。

```json
{
  "version": 1,
  "host": "localhost",
  "port": 20427,
  "apiKeys": ["sk-local-xxx"],
  "providers": {
    "deepseek": {
      "enabled": true,
      "apiKeys": [{ "label": "主 Key", "value": "sk-..." }],
      "credential": { "api_key": "sk-..." }
    }
  }
}
```

`providers.<id>.apiKeys` 为带标签的令牌数组（`{label, value}`）；旧格式 `["sk-..."]` 纯字符串数组仍可正常读取，加载时自动迁移（标签为密钥掩码）。未配置 `apiKeys` 时允许匿名访问（开发模式）；配置后所有 `/v1/*` 端点需携带有效 key。为兼容未带 `/v1` 前缀的客户端，`/chat/completions`、`/models`、`/health`、`/usage` 等同路径也自动归一化到 `/v1/*`。

环境变量：`DEEPSEEK_API_KEY`、`DEEPSEEK_BASE_URL`（可指向自建网关/测试 mock）、`CODEBUDDY_CN_ACCESS_TOKEN`、`ANTIGRAVITY_ACCESS_TOKEN`、`BINVIA_API_KEY` / `ROUTER_API_KEY`（恒有效的网关 key）。

## 模块结构

```
Sources/
├── BinviaCore/               # 核心库
│   ├── Model/Model.swift            # 模型元数据
│   ├── Provider/                    # Provider 协议/描述符/注册表/Chat 模型
│   ├── Router/Router.swift          # provider/model 路由
│   ├── Networking/                  # ProviderHTTPClient（重试/流式）、SSEParser、SSEJSONAggregator、ModelCache
│   ├── Config/                      # 配置读写
│   ├── Auth/APIKeyAuthenticator.swift
│   ├── Monitoring/RequestLogger.swift
│   ├── Server/                      # 本地 HTTP 服务器 + 路由分发
│   └── Providers/                   # deepseek / codebuddy-cn / antigravity / openai / opencode / kimi / opencode-go / xiaomi-mimo / qwen-cloud / zai / minimax / codex / cursor
├── BinviaServer/             # 服务器入口
├── BinviaCLI/                # CLI（含 oauth login）
└── BinviaApp/                # 菜单栏 GUI（SwiftUI）
    ├── AppState.swift               # 全局状态：配置/服务器生命周期/OAuth/Key/监控
    ├── Views/                       # MenuPanelView、OverviewTabView、ProviderTabView、RecentRequestsView、ServerStatusView 等
    └── Components/                  # StatusBadge、APIKeyInputField、OAuthLoginButton、ProviderUsageCard、ProviderHealthRow
```

## 测试与打包

```bash
make test       # swift run BinviaCheck（单元 + 集成，无需 Xcode）
make release    # release 构建 + 拷贝到 bin/
make run        # 运行服务器
```

## 文档

改动借鉴自上游的代码前，先读对应工程分析文档；分析不足时再查上游源码（均在本机）：

- **CodexBar**（菜单栏 GUI 模式、`ProviderDescriptor`/注册表、`ProviderHTTPClient`、`ConfigStore` 的来源）→ [codexbar-analysis.md](docs/codexbar-analysis.md)，源码 `/Users/wangbin/workspace/temp/my-token-route/CodexBar`
- **OmniRoute**（`provider/model` 路由、api-key 认证、SSE chat handler、供应商注册表、CodeBuddy/Antigravity 请求头与模型目录的来源）→ [omniroute-analysis.md](docs/omniroute-analysis.md)，源码 `/Users/wangbin/workspace/temp/my-token-route/OmniRoute`
- **GUI 实现**（菜单栏应用、设置窗口、OAuth 流程、metrics 轮询）→ [gui-implementation-guide.md](docs/gui-implementation-guide.md)

其余文档：

- 实现计划：[implementation-plan.md](docs/implementation-plan.md)
- 任务清单：[task.md](docs/task.md)
