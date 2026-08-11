# Binvia

> 本地 AI 供应商聚合路由网关 —— 一个应用同时连接 DeepSeek、腾讯 CodeBuddy 等 8 家供应商，在本地提供 **OpenAI 兼容 API**，并自带菜单栏监控面板。

Binvia 是运行在 macOS 上的本地应用（菜单栏 GUI + 命令行 + 后台服务），把多家 AI 供应商聚合到一个本地端点 `http://localhost:20427/v1`：

- **Claude Code、opencode** 等工具只需配置一个 OpenAI 兼容端点 + 一个网关 Key，即可调用所有供应商；
- 一个面板统管全部供应商：余额/配额、请求统计、最近请求、一键测试连接；
- 纯 Swift + 原生 socket 实现，**零第三方依赖**，所有请求只从你的机器直连上游，数据不出本机。

## 功能

- **多供应商聚合**：一个 OpenAI 兼容端点路由到 DeepSeek / CodeBuddy 等 8 家供应商
- **模型路由**：`provider/model` 语法或别名（`ds` / `cbcn`），裸模型名自动归属
- **OpenAI / Anthropic 兼容 API**：`/v1/chat/completions`（流式 + 非流式）、`/v1/responses`（非流式 + 流式）、`/v1/messages`（非流式 + 流式）、`/v1/models`、`/v1/usage`、`/v1/health`
- **多入站格式**：Codex CLI（`wire_api = "responses"`）可直接使用 `/v1/responses`；Claude Code / Anthropic SDK 可直接使用 `/v1/messages`
- **网关 Key 认证**：`sk-bv-` 开头网关 Key 白名单；上游多 Key 自动轮换（401/403 时切换）
- **SSE 流式透传**：逐事件实时转发；强制流式上游对非流式客户端自动聚合为 JSON
- **可靠重试**：408/429/5xx 指数退避重试，尊重 `Retry-After` 头
- **OAuth 免 Key**：CodeBuddy 浏览器授权登录，无需手动填 Key
- **菜单栏监控**：服务器启停、供应商健康度、余额/配额窗口、请求明细（时间/模型/token/耗时/状态）
- **配置即改即生效**：设置面板改端口、加 Key、启停供应商，保存即热更新，无需重启

## 已接入供应商

| 供应商 | 别名 | 认证方式 |
|---|---|---|
| DeepSeek | `ds` | API Key |
| 腾讯 CodeBuddy | `cbcn` | OAuth 设备码 |
| opencode | `oc` | API Key |
| Kimi（月之暗面） | `kimi` | API Key |
| opencode-go | `ocgo` | API Key |
| 小米 MiMo | `mimo` | API Key |
| 智谱 z.ai | `zai` | API Key |
| MiniMax | `mm` | API Key |

## 下载

从 [GitHub Releases](https://github.com/wangbin3162/Binvia/releases) 下载最新版本：

- `Binvia-<版本>-macos-arm64-x86_64.dmg`（**推荐**）—— 安装包：打开后拖入即安装，同时支持 Apple Silicon（M 系列）与 Intel Mac
- `Binvia-<版本>-macos-arm64-x86_64.tar.gz` —— 免安装版（解压即用）
- `install-cli.sh` —— 命令行工具安装脚本（可选，见下方「命令行工具」）
- `SHA256SUMS` —— 校验和文件

```bash
# 校验下载完整性（可选，但推荐）
shasum -a 256 -c SHA256SUMS
```

**系统要求**：macOS 14.0+（Sonoma 及以上）

## 安装

### 方式一：DMG 安装包（推荐）

1. 双击打开下载的 `.dmg` 文件；
2. 把 **Binvia.app** 拖入窗口内的「Applications」快捷方式；
3. 到「应用程序」中打开 Binvia 即可（首次打开如被拦截，右键 → 打开 → 确认）。

> 只装 GUI 即可完整使用（服务器内嵌在应用中，菜单栏点 Start 即启动网关）。

### 方式二：免安装版（tar.gz）

```bash
tar -xzf Binvia-<版本>-macos-arm64-x86_64.tar.gz
mv Binvia.app /Applications/
```

### 命令行工具（可选）

`BinviaServer` / `BinviaCLI` 供无头部署、终端操作使用（日常使用无需安装）：

```bash
# 安装到 /usr/local/bin（需输入开机密码）
curl -fsSL https://github.com/wangbin3162/Binvia/releases/latest/download/install-cli.sh | bash
```

> **首次打开提示**：当前版本为 adhoc 签名、未做 Apple 公证，首次打开若被 Gatekeeper 拦截，
> 请右键 Binvia.app → 打开 → 确认；或在「系统设置 → 隐私与安全性」中点击「仍要打开」。

## 快速开始

### 方式一：菜单栏应用（推荐）

1. 打开 `Binvia.app`，菜单栏出现 Binvia 图标；
2. 点击图标 → 齿轮图标进入**设置** → **供应商**；
3. 填入 API Key 或一键 OAuth 登录 → 点「测试连接」确认可用；
4. 回到主面板点击 **Start** 启动服务器（默认端口 20427）；
5. 在 Claude Code、opencode 等工具中配置：

```
API 端点: http://localhost:20427/v1
API Key:  设置 → 网关密钥 中生成（sk-bv- 开头）
```

### 方式二：命令行

```bash
# 启动服务器（默认监听 http://localhost:20427/v1）
BinviaServer

# 列出供应商与模型
BinviaCLI providers list

# 测试供应商可用性
BinviaCLI test deepseek

# OAuth 登录（CodeBuddy）
BinviaCLI oauth login codebuddy-cn
```

### 调用示例

```bash
# 健康检查
curl http://localhost:20427/v1/health

# 模型列表（含各供应商动态模型，附带 context_length 上下文窗口）
curl http://localhost:20427/v1/models

# 聊天（流式）
curl -N http://localhost:20427/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-bv-xxx" \
  -d '{"model":"ds/deepseek-v4-pro","messages":[{"role":"user","content":"hi"}],"stream":true}'

# OpenAI Responses API（Codex CLI 兼容）
curl -N http://localhost:20427/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-bv-xxx" \
  -d '{"model":"ds/deepseek-v4-pro","input":"hi","stream":true}'

# Anthropic Messages API（Claude Code 兼容）
curl -N http://localhost:20427/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: sk-bv-xxx" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"ds/deepseek-v4-pro","max_tokens":1024,"stream":true,"messages":[{"role":"user","content":"hi"}]}'

# 用量统计
curl http://localhost:20427/v1/usage
```

模型名支持三种写法：`供应商/模型`（`deepseek/deepseek-v4-pro`）、别名（`ds/deepseek-v4-pro`）、裸模型名（自动归属到唯一匹配的供应商）。

## 配置

配置文件：`~/.config/binvia/config.json`（可用环境变量 `BINVIA_CONFIG` 覆盖路径）。日常配置推荐在 GUI 设置面板完成；文件格式示例：

```json
{
  "version": 1,
  "host": "localhost",
  "port": 20427,
  "apiKeys": ["sk-local-xxx"],
  "providers": {
    "deepseek": {
      "enabled": true,
      "apiKeys": [{ "label": "主 Key", "value": "sk-..." }]
    }
  }
}
```

环境变量：

| 变量 | 作用 |
|---|---|
| `DEEPSEEK_API_KEY` | DeepSeek API Key |
| `CODEBUDDY_CN_ACCESS_TOKEN` | CodeBuddy Access Token |
| `BINVIA_API_KEY` / `ROUTER_API_KEY` | 恒有效的网关 Key |
| `BINVIA_CONFIG` | 配置文件路径覆盖 |
| `OPENCODE_COOKIE` / `OPENCODE_GO_COOKIE` | OpenCode / OpenCode Go 浏览器会话 Cookie（用量查询，也可在 GUI 设置面板填写） |
| `OPENCODE_WORKSPACE_ID` / `OPENCODE_GO_WORKSPACE_ID` | 跳过 workspace 发现，强制指定（接受 `wrk_...` 或完整 URL） |
| `OPENCODE_GO_LOCAL_DIR` | 覆盖本地 opencode 数据目录（默认 `~/.local/share/opencode`） |
| `OPENCODE_GO_QUOTA_URL` | 显式覆盖 OpenCode Go web 配额端点（默认端点上游未公开，仅供测试） |
| `BINVIA_STREAM_READINESS_TIMEOUT` | 首个事件超时（秒），默认 60 |
| `BINVIA_STREAM_IDLE_TIMEOUT` | 两次事件之间的空闲超时（秒），默认 120 |
| `BINVIA_STREAM_EARLY_EOF_RETRY` | 首包前早断最大重试次数，默认 1（0 关闭） |
| `BINVIA_ENABLE_RESPONSES` | 关闭后 `/v1/responses` 返回 404，默认开启 |
| `BINVIA_ENABLE_MESSAGES` | 关闭后 `/v1/messages` 返回 404，默认开启 |

> 未配置任何 Key 时为开发模式（匿名访问）；配置后所有 `/v1/*` 端点均需携带有效网关 Key。

## 从源码构建

```bash
swift build          # 构建
make test            # 运行全部测试（694 项断言，无需 Xcode）
make run             # 启动服务器
make release         # 完整打包（双架构 + 签名 + DMG/tar.gz），产物在 bin/
```

GUI 开发运行：`swift run BinviaApp`（菜单栏应用）；发布物为 `bin/Binvia-<版本>-macos-arm64-x86_64.dmg`。正式发布流程见 `docs/build-release-guide.md`。

## 致谢

- 菜单栏 GUI 模式与供应商注册表/HTTP 客户端模式借鉴 [CodexBar](https://github.com/steipete/CodexBar)
- 模型路由语法与上游供应商请求头设计参考 OmniRoute
