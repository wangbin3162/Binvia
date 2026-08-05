# Binvia Web 管理面板实现计划

> 制定日期：2026-08-05
> 范围：**仅 Web 管理面板**（原 Windows 支持计划已废弃，Windows 移植不再考虑）。
> 形态：`BinviaServer` 内置管理面板 —— 浏览器访问 `http://localhost:<port>/` 完成监控、配置、测试、网关 Key 管理。
> 前端技术：**Vite + Vue 3 + TypeScript**，独立 `web/` 目录；构建产物内嵌进 BinviaServer 二进制（单文件交付）。

---

## 1. 背景与目标

当前监控/配置能力全部在 macOS 菜单栏 GUI（BinviaApp）里，无头场景（服务器、SSH 机器、CI）无法使用。目标：

1. `BinviaServer` 自带 Web 管理面板，覆盖现有 GUI 的核心能力：**概览监控、Provider 管理、请求日志、网关 Key、设置**。
2. 前端独立工程 `web/`（Vite + Vue 3 + TS），开发期用 Vite dev server 联调，发布期构建后**内嵌进服务器二进制**，保持"单文件交付、零运行时依赖"。
3. macOS GUI 用户同步受益（浏览器也能看面板）；不影响现有 `/v1/*` 网关 API。

**非目标**：Windows 编译/分发（已明确不做）、替换 macOS GUI、移动端适配（浏览器自适应即可，不做专门 App）。

## 2. 技术决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 前端框架 | **Vite + Vue 3 + TypeScript** | 用户指定；TS 对 admin API 契约友好（类型即文档） |
| UI 组件库 | **不引入**（手写 CSS） | 保持零依赖精神；面板组件简单（卡片/表格/表单）；无 CDN 请求，断网可用 |
| 状态/请求 | Composition API + 原生 `fetch` | 不引入 pinia/axios，面板规模不需要 |
| 开发联调 | Vite dev server（默认 5173）+ proxy 到 `127.0.0.1:20427` | 热更新迭代，后端无改动 |
| 发布形态 | `vite build` → 内联单文件 HTML → **base64 内嵌 Swift 字符串** | 单二进制交付（install-cli.sh 不变）；base64 规避 JS 转义问题 |
| 内嵌文件 | `Sources/BinviaCore/Server/WebPanelAssets.swift` **提交入库** | 保证任何机器 `swift build` 不依赖 node；`web/dist/` gitignore |
| 认证 | 复用原设计：默认 loopback 免密；配 `admin_password` 后 token 登录 | 与网关 `/v1/*` 的 gateway key 体系相互独立 |

> 关于"零依赖"约束：AGENTS.md 的零依赖指 **Swift 运行时依赖**。Vite/Vue 是**构建期**工具链（node_modules 不进入交付物），产物为静态资源内嵌二进制，不违背约束。若未来不想引入 node 工具链，可退回手写单文件 HTML 方案（备选，见 §11）。

## 3. 目录结构

```
Binvia/
├── web/                          # 前端工程（独立目录）
│   ├── package.json              # vite / vue / typescript 等 devDependencies
│   ├── vite.config.ts            # dev proxy → 127.0.0.1:20427
│   ├── tsconfig.json
│   ├── index.html                # Vite 入口
│   ├── scripts/
│   │   └── embed.mjs             # 构建后：内联 assets → 生成 WebPanelAssets.swift（base64）
│   └── src/
│       ├── main.ts               # Vue 入口
│       ├── App.vue               # 布局：顶栏 + Tab 导航
│       ├── api/
│       │   ├── client.ts         # fetch 封装（token、错误处理）
│       │   └── types.ts          # admin API 类型（与后端契约对齐）
│       ├── views/
│       │   ├── OverviewView.vue  # 概览：Summary 卡片 + Provider 健康度
│       │   ├── ProvidersView.vue # Provider 卡片：用量/凭据/测试/启用
│       │   ├── LogsView.vue      # 请求日志表格（2s 轮询）
│       │   ├── KeysView.vue      # 网关 Key 管理
│       │   └── SettingsView.vue  # 服务器设置
│       └── styles/main.css       # 手写样式（系统字体栈，浅色为主）
├── Sources/BinviaCore/
│   ├── Server/ServerState.swift      # 新增：可变配置盒 + 热更新回调 + admin token
│   ├── Server/WebPanel.swift         # 新增：admin API 编排 + HTML 服务
│   ├── Server/WebPanelAssets.swift   # 新增：内嵌 HTML（base64，由 embed.mjs 生成）
│   └── Server/RouteHandler.swift     # 修改：GET / 与 /admin/* 分支
├── Sources/BinviaServer/main.swift   # 修改：ServerState 接线 + 面板地址打印
├── Sources/BinviaApp/AppState.swift  # 修改：RouteHandler 构造适配（若签名变化）
└── Sources/BinviaCheck/main.swift    # 修改：新增 WebPanelTests
```

## 4. 架构与数据流

```
浏览器 (Vue SPA)
  │  fetch
  ▼
HTTPServer ──> RouteHandler
                ├── GET  /             → WebPanel.htmlResponse()（内嵌 HTML）
                ├── GET|POST /admin/*  → WebPanel admin API（可选 token 认证）
                └── /v1/*              → 现有网关路由（不变）
admin API ──> ServerState（配置盒）──> ConfigStore.save
                                  └──> onConfigChanged ──> HTTPServer.setHandler（热更新）
admin API ──> RequestLogger.shared / UsageCache / Provider.testConnection（全部现成）
```

**路由分发**（`RouteHandler.handle`）：

```swift
switch (request.method, request.path) {
case ("GET", "/"):                     // WebPanel.htmlResponse()
case ("GET", "/admin/api/overview"):   // 认证
case ("GET", "/admin/api/entries"):    // 认证
case ("GET", "/admin/api/providers"):  // 认证
case ("GET", "/admin/api/snapshots"):  // 认证
case ("GET", "/admin/api/config"):     // 认证（凭据掩码）
case ("POST", "/admin/api/login"):     // 免认证
case ("POST", "/admin/api/config"):    // 认证（保存+热更新）
case ("POST", "/admin/api/usage/refresh"):        // 认证
case ("POST", "/admin/api/providers/*/test"):     // 认证
case ("POST", "/admin/api/keys"):                 // 认证
case ("DELETE", "/admin/api/keys/*"):             // 认证
default: 现有 /v1/* 路由
}
```

**⚠️ 回归点**：`normalizePath`（`RouteHandler.swift:37`）会给裸路径补 `/v1` 前缀，必须放行 `/admin` 前缀（`hasPrefix("/v1") || hasPrefix("/admin")` 时不补前缀）。

## 5. ServerState 设计

```swift
public final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var config: RouteConfig
    private var onConfigChanged: (@Sendable (RouteConfig) -> Void)?
    private var adminToken: String?

    public func get() -> RouteConfig
    public func update(_ mutate: (inout RouteConfig) -> Void)   // 变更 → onConfigChanged
    public func saveAndReload() throws                          // ConfigStore.save + update
    public func verifyPassword(_ password: String) -> Bool      // 成功则轮换 token
    public func isAuthorized(_ token: String?) -> Bool          // 未设密码 → true
}
```

`BinviaServer/main.swift` 接线（与 `AppState.applyConfigHotReload` 同机制，复用 `HTTPServer.setHandler` 热替换）：

```swift
let state = ServerState(config: config)
var handler = RouteHandler(config: config, state: state)
let server = HTTPServer { request in try await handler.handle(request) }
state.onConfigChanged = { newConfig in
    let newHandler = RouteHandler(config: newConfig, state: state)
    server.setHandler { request in try await newHandler.handle(request) }
}
```

## 6. admin API 规格

| 端点 | 方法 | 请求 | 响应 |
|---|---|---|---|
| `/` | GET | — | `text/html`（内嵌面板） |
| `/admin/api/login` | POST | `{"password":"..."}` | `{"token":"..."}` / 401 |
| `/admin/api/overview` | GET | — | `{server:{running,host,port}, summary, totals:{requests,errors,activeProviders,promptTokens,completionTokens,totalTokens}}` |
| `/admin/api/entries` | GET | `?limit=50` | `{entries:[RequestLogEntry]}` 倒序 |
| `/admin/api/providers` | GET | — | `{providers:[{id,alias,displayName,authType,configured,enabled,region,modelCount}]}` |
| `/admin/api/snapshots` | GET | — | `{snapshots:[String:ProviderUsageSnapshot]}` |
| `/admin/api/usage/refresh` | POST | — | 强制刷新全部用量，返回新快照 |
| `/admin/api/providers/{id}/test` | POST | `{"model":"可选"}` | `{success,message}` |
| `/admin/api/config` | GET | — | 完整 `RouteConfig`，**凭据掩码**（apiKey/accessToken 只回掩码） |
| `/admin/api/config` | POST | 完整或部分 config | 校验 + 保存 + 热更新 |
| `/admin/api/keys` | POST | `{}` 或 `{"key":"sk-bv-...","enabledModels":[...]}` | 新建/更新网关 key |
| `/admin/api/keys/{key}` | DELETE | — | 删除网关 key |

- **认证**：除 login 外，所有 `/admin/api/*` 校验 `Authorization: Bearer <token>`；未配置 `admin_password` 时全部放行（默认仅 loopback 监听）。
- **掩码只影响回显**：`GET /admin/api/config` 掩码，`POST /admin/api/config` 提交完整凭据原样保存。
- **复用现有能力**：overview 从 `RequestLogger.shared.summary()` 推导；snapshots 用 `UsageCache`；test 用 `Provider.testConnection`；热更新复用 `setHandler`。

## 7. RouteConfig 新增字段（兼容旧配置）

```jsonc
{
  "version": 2,
  "host": "localhost",
  "port": 20427,
  "web_panel_enabled": true,    // 默认 true；false 时 GET / 与 /admin/* 返回 404
  "admin_password": null,       // 非 null 时面板需登录
  "api_keys": [],
  "providers": {}
}
```

`RouteConfig.swift` 增加 `webPanelEnabled: Bool = true`、`adminPassword: String? = nil`，`init(from:)` 用 `decodeIfPresent` 回退（与既有 `region` 模式一致）。

## 8. 前端页面设计（对齐现有 GUI 信息架构）

- **顶栏**：服务器状态灯、监听地址 `http://<host>:<port>`、版本号。
- **Tab**：概览 / Provider / 请求日志 / 网关 Keys / 设置。
- **概览**：Summary 卡片（总请求/总错误/活跃 Provider/总 Token）+ Provider 健康度列表（余额/配额）。
- **Provider**：每 Provider 卡片 —— 认证类型、配置状态、用量快照、「测试连通性」、凭据编辑（API Key 多 Key 列表 / Access Token / OAuth 状态）、启用开关、region 选择。
- **请求日志**：表格（时间/模型/token/耗时/状态），倒序，**2s 轮询**。
- **网关 Keys**：Key 列表（掩码）+ 生成/删除 + enabledModels 白名单编辑。
- **设置**：port / webPanelEnabled / adminPassword / autoOpenBrowser + 保存。

**刷新节奏**：overview + entries 2s；snapshots 5min + 手动刷新；写操作为触发式。
**登录流程**：未配密码直接加载；配了密码 → JS 检查 localStorage token → 无则弹密码框 → `POST /admin/api/login` → 存 token 重载。

## 9. 开发 / 构建 / 联调流程

```bash
# 开发（两个终端）
make run                          # 后端：BinviaServer（:20427）
cd web && npm install && npm run dev   # 前端：Vite dev（:5173，proxy 到 20427）

# 发布构建
cd web && npm run build            # → web/dist/
node web/scripts/embed.mjs         # → 重新生成 WebPanelAssets.swift
make release                       # 内嵌新面板的完整打包
```

- `web/vite.config.ts` dev proxy：`/admin`、`/v1`、`/` → `http://127.0.0.1:20427`。
- `embed.mjs` 逻辑：读 `dist/index.html` + `dist/assets/*.js|css` → 内联替换 `<script src>` / `<link href>` → 单文件 HTML → **base64** → 写 `WebPanelAssets.swift`（`static let htmlBase64 = "..."`）。
- `WebPanelAssets.swift` **提交入库**（swift build 不依赖 node）；`web/dist/`、`web/node_modules/` 进 `.gitignore`。
- Makefile 增加 `make web`（= `cd web && npm install && npm run build && node scripts/embed.mjs`）。

**约定**：改了前端必须跑 `make web` 并把生成的 `WebPanelAssets.swift` 一起提交，否则面板不更新。

## 10. 测试计划（BinviaCheck 新增 `WebPanelTests`）

| 用例 | 断言 |
|---|---|
| `GET /` 返回 200 + `text/html` + 含 `id="app"` | 面板可加载 |
| `GET /admin/api/overview` 200 + JSON 含 `summary` | 监控可用 |
| 配置 `admin_password` 后：无 token 401 → 登录 200 拿 token → 带 token 200 | 认证三态 |
| `POST /admin/api/config` 关闭某 provider 后 `/v1/models` 立即变化 | 热更新 |
| `POST /admin/api/keys` 新增后网关 key 可鉴权（401 → 200） | Key 管理 |
| `GET /admin/api/config` 不含明文 apiKey | 凭据掩码 |
| `POST /admin/api/providers/*/test`（URLProtocol mock） | 测试连通性 |
| `web_panel_enabled=false` 时 `/` 返回 404 | 开关生效 |

沿用现有「本地真实 HTTPServer 当 mock」模式；测试入口不碰真实配置。

## 11. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 引入 node 工具链与"零依赖"哲学冲突 | 低 | 明确边界：零依赖指 Swift 运行时；node 仅构建期。备选：若坚持无 node，退回手写单文件 HTML（admin API 不变，只换前端载体） |
| 内嵌 HTML 体积（Vue 产物 ~150-250KB，base64 后 +33%） | 低 | 可接受；面板单文件无图片资源；必要时 vite 开启 minify 默认已开 |
| `normalizePath` 放行 `/admin` 的回归 | 中 | §4 已标注为回归点；BinviaCheck 补 `/admin` 前缀用例 |
| `RouteHandler` 构造签名变化影响 AppState/BinviaCheck 调用点 | 中 | 全部调用点适配 + 全量测试回归 |
| StrictConcurrency 闭包捕获（热更新回调） | 中 | `ServerState` 为 `@unchecked Sendable`，回调在 handler 调用点同步执行；与 `AppState.applyConfigHotReload` 同机制 |
| admin API 扩大攻击面 | 中 | 默认 loopback + 可选密码；文档明示安全边界（勿在公网开 `host=0.0.0.0` 且不设密码） |

## 12. 实施切片（按序，每片可独立验证）

| 切片 | 内容 | 验证 |
|---|---|---|
| **S1 后端骨架** | `ServerState` + RouteConfig 新字段 + `normalizePath` 放行 + `GET /` 返回占位 HTML + ServerState 接线 | `make test` 全绿；`curl :20427/` 200 |
| **S2 admin API** | 全部端点 + 认证 + 凭据掩码 + 热更新 + `webPanelEnabled` 开关 | BinviaCheck 新增 WebPanelTests 全绿 |
| **S3 前端脚手架** | `web/` 工程（vite+vue3+ts）+ dev proxy + 概览 Tab + 顶栏 | 浏览器 dev 模式可见概览数据 |
| **S4 前端全量** | Provider / 日志 / Keys / 设置 四个 Tab + 登录流程 + toast | 全功能走查（对照 GUI 行为） |
| **S5 内嵌与发布** | `embed.mjs` + `make web` + build.sh 集成 + README/发布指南更新 | `make release` 产物面板可用；安装包内无需额外文件 |

## 13. 验收标准（全部完成后）

1. `make test` 全绿（含 WebPanelTests 新套件，无回归）。
2. 浏览器打开 `http://127.0.0.1:20427/`：概览/Provider/日志/Keys/设置全部可用；配置保存即时生效（热更新）；凭据回显全部掩码。
3. `web_panel_enabled=false` 时 `/` 与 `/admin/*` 404，`/v1/*` 不受影响。
4. `make release` 产物（DMG/tar.gz/install-cli.sh 安装的 BinviaServer）**单文件**包含面板 —— 无需附带任何前端文件。
5. macOS GUI 无回归（`BinviaApp --smoke-test` 通过）。
