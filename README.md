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

## 快速开始

### 构建

```bash
swift build
```

### 启动服务器

```bash
# 方式一：默认配置（端口 8231）
swift run BinviaServer

# 方式二：指定配置/端口
swift run BinviaServer --port 8231 --config ~/.config/binvia/config.json
```

### 登录供应商（OAuth）

```bash
# 腾讯 CodeBuddy（设备码：自动打开浏览器授权）
swift run BinviaCLI oauth login codebuddy-cn

# Google Antigravity（PKCE：打开浏览器授权后把重定向地址/code 粘贴回终端）
swift run BinviaCLI oauth login antigravity
```

登录凭据自动写入 `~/.config/binvia/config.json`。

### 调用

```bash
# 健康检查
curl http://127.0.0.1:8231/v1/health

# 模型列表（含动态模型）
curl http://127.0.0.1:8231/v1/models

# 聊天（流式）
curl -N http://127.0.0.1:8231/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-api-key>" \
  -d '{"model":"deepseek/deepseek-v4-pro","messages":[{"role":"user","content":"hi"}],"stream":true}'

# 用量
curl http://127.0.0.1:8231/v1/usage
```

### CLI

```bash
swift run BinviaCLI providers list            # 列出供应商与模型
swift run BinviaCLI test deepseek             # 测试供应商可用性
swift run BinviaCLI oauth login codebuddy-cn  # OAuth 登录
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

- **服务器启停**：Start/Stop 一键控制本地代理，状态灯实时显示。
- **Provider 入口**：点 Provider 行/齿轮直接打开设置窗口对应配置页。
- **网关 API Key**：生成 `sk-tg-` 开头的 Key，复制/删除，持久化到 `config.json`。
- **用量监控**：每 2 秒刷新各 Provider 请求/错误统计。

**设置窗口**（点面板底部 Settings 打开）为 CodexBar 风格：左侧栏 + 右侧详情，全部配置均在面板中完成，无需手改文件：

- **服务器**：修改监听端口/地址，保存即热更新（运行中替换 handler，无需重启）。
- **供应商**：DeepSeek 填 API Key（支持多 Key 轮换）；CodeBuddy 一键设备码 OAuth 登录或粘贴 Access Token；Antigravity 一键 PKCE OAuth 登录（粘贴授权码）或粘贴 Access/Refresh Token。每个供应商支持「测试连接」与启用/停用开关。
- **网关密钥**：生成/复制/删除 `sk-tg-` 网关 Key。

## 配置

配置文件：`~/.config/binvia/config.json`（`BINVIA_CONFIG` 可覆盖路径）。

```json
{
  "version": 1,
  "host": "127.0.0.1",
  "port": 8231,
  "apiKeys": ["sk-local-xxx"],
  "providers": {
    "deepseek": {
      "enabled": true,
      "credential": { "api_key": "sk-..." }
    }
  }
}
```

未配置 `apiKeys` 时允许匿名访问（开发模式）；配置后所有 `/v1/*` 端点需携带有效 key。

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
│   └── Providers/                   # deepseek / codebuddy-cn / antigravity / openai / opencode / kimi / opencode-go / xiaomi-mimo / qwen-cloud / zai / minimax
├── BinviaServer/             # 服务器入口
├── BinviaCLI/                # CLI（含 oauth login）
└── BinviaApp/                # 菜单栏 GUI（SwiftUI）
    ├── AppState.swift               # 全局状态：配置/服务器生命周期/OAuth/Key/监控
    ├── Views/                       # MenuPanelView、ServerStatusView、ProviderListView 等
    └── Components/                  # StatusBadge、APIKeyInputField、OAuthLoginButton
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
