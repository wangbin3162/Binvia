# Binvia — AI 协作说明

macOS 本地 AI 供应商聚合网关：在本机端口上暴露 OpenAI 兼容 API，把请求路由到
DeepSeek、腾讯 CodeBuddy 等 8 家供应商。纯 Swift + 原生 POSIX socket，**零第三方依赖**。

## 改代码之前

按顺序读，别跳：

1. **`LESSONS.md`** — 近期踩过的坑和拦住它们的规则。**改代码前必读**，读完再动手。
2. **`docs/code-standards.md`** — 什么算「做完了」，提交信息怎么写，多久复盘一次。
3. 改到 `docs/` 里已有模块 → 先读对应文档，再改代码（见下方「文档索引」）。

这三份文件的分工：本文件说「去哪找」，`LESSONS.md` 装近期错题（**会毕业，所以短**），
`docs/code-standards.md` 装已经站住的硬规矩。

## 项目结构

```
Sources/
├── BinviaCore/        # 核心库：Provider 协议/注册表、Router、Auth、Config、Networking、Server、Monitoring
│   └── Providers/         # deepseek / codebuddy-cn / opencode 等（每供应商一个目录）
├── BinviaServer/      # 服务器入口 main.swift
├── BinviaCLI/          # CLI：providers / test / oauth / config / serve
├── BinviaApp/          # 菜单栏 GUI（SwiftUI + AppKit），含 --smoke-test
└── BinviaCheck/        # 自包含测试可执行（非 XCTest）
```

- 源码：`Sources/`（5 个 target，见 `Package.swift`，全部启用 `StrictConcurrency`）
- 文档：`docs/`
- 构建产物：`bin/`、`.build/` —— **不要手改**，改生成它的源
- 生成物：`Sources/BinviaApp/Components/ProviderIcons.swift` 由 `Scripts/embed_svgs.sh`
  从 `Sources/BinviaApp/Resources/ProviderIcon-*.svg` 生成 —— **不要手改，改 SVG 后重跑脚本**

## 构建与测试

本机只有 Command Line Tools、无 Xcode，因此 **`swift test` 不可用**（无 xctest），
测试是一个可执行 target。

- `swift build` — 构建全部 target
- `make test`（= `swift run BinviaCheck`）— 跑全部测试；退出码 0 = 通过，1 = 有失败
- `make run`（= `swift run BinviaServer`）— 起服务；可加 `--port N` / `--config PATH`
- `swift run BinviaCLI providers list` — 列出供应商与模型
- `swift run BinviaCLI test <provider|alias>` — 供应商可用性测试
- `swift run BinviaApp --smoke-test` — GUI 无界面自检（构建需 Xcode，见下）
- `make release`（= `./Scripts/build.sh`）— 发布构建 + 自检，产物到 `bin/`
- `make clean` — 删除 `.build` 与 `bin`

**测试不支持按用例筛选**：没有 `run(name) { }` 过滤开关，要跑子集只能临时注释掉
`Sources/BinviaCheck/main.swift` 里的 `run(...)` 调用。

测试环境要求：入口把 `BINVIA_CONFIG` 指向不存在的临时路径，并在用例内
`unsetenv`/`setenv` 凭据变量后 `defer` 还原。**新测试不得读写
`~/.config/binvia/config.json`** 或真实凭据。

### 工具链限制（2026-10-13 实测，会变的）

- ✅ `BinviaCore` / `BinviaServer` / `BinviaCLI` / `BinviaCheck` 本机可构建，`make test` 全绿。
- ❌ **`BinviaApp` 本机构建不了**：SwiftUI 的 `@State` 等宏需要 `SwiftUIMacros` 插件，
  该插件只随 Xcode 提供（报错 `plugin for module 'SwiftUIMacros' not found`）。
  GUI 改动只能在有 Xcode 的机器或 CI（`macos-26` runner 自带 Xcode）上真实验证；
  本机跑不了就在提交信息里写「未验证」。

## 硬性规矩

- **不许破坏用户已有的东西**：不改用户手写的配置项，不覆盖未提交的改动，
  不删非本工具生成的文件。配置路径 `~/.config/binvia/config.json` 属于用户数据。
- **生成物不手改**：`Sources/BinviaApp/Components/ProviderIcons.swift`（改 SVG 源后跑脚本）。
- **改动前先确认范围**：超出本次目标的重构另开一次提交（验收第 6 条）。
- **`HTTPServer.setHandler()` 的热替换契约不能破**：GUI 热重载依赖它运行时替换路由处理器。
- **新增供应商时三处一起改**：实现 `Provider`、加 `ProviderDescriptor`、
  在 `Sources/BinviaCore/Providers/ProviderCatalog.swift` 注册一行，并更新 `README.md` 的供应商表。
- **强制流式上游**（如 CodeBuddy）对非流式客户端必须走 `SSEJSONAggregator` 聚合成 JSON；
  新增此类供应商照此模式办。

## 约定

- **语言**：Swift 6.2，macOS 14+。注释与文档用**中文**，与 `README.md` 及现有源码一致。
- **并发**：所有 target 启用 `StrictConcurrency` —— 写 `Sendable` 一致的、`@MainActor` 明确的代码。
- **格式**：4 空格缩进（无 linter / formatter 配置，靠人工保持一致）。
- **依赖**：**零第三方依赖**。优先 Foundation/AppKit；不加包，除非有充分理由。

## 提交信息

三段式，缺一段都算没写完：

```
<scope>: <用户看到的变化，用行为描述，不用实现描述>

为什么：<谁报的 / 什么场景触发的 / 不这么改会怎样>
改了什么：<哪些行为面变了；边界在哪>
跑了什么：<具体命令 + 具体结果数字>；没试过：<明确列出没验证的部分>
```

最后一段是这套流程真正起作用的地方：写清楚跑了什么、**以及没跑什么**，
是后面审查能判断「这次改动能不能信」的唯一依据。没跑的检查写「未跑」，
不要省略、不要写「应该没问题」。

> 现状（2026-10-13）：最近 40 个提交里只有 10 个有 ≥3 行正文。这条是**新增要求**，
> 不是在描述既有习惯；历史里 42 次 `update：...` 式标题不要继续沿用。

详细规范和示例见 `docs/code-standards.md`。

## 复盘

- **什么时候复盘**：**发版前**（提升 `version.env` 的 `MARKETING_VERSION` / 打 tag 之前），或每约 20 个提交；
  出现**返工**（同一个东西改了两次以上）时立刻复盘一次。
- **怎么复盘**：读这段时间的提交，找出返工过的、不该合进来的、验证太薄的，
  写成错题追加到 `LESSONS.md`（现有错题则复发次数 +1）。
- **毕业规则**：同一条错题被独立踩到 **3 次** → 移进 `docs/code-standards.md`，从错题本删掉。
- **`LESSONS.md` 上限 ≤ 5 条错题**（按条数数），超了就必须先毕业一条。

复盘用的完整提示词见 `docs/code-standards.md` 第三节。

## 文档索引

`docs/` 存放本项目借鉴的两个上游项目的分析报告（CodexBar / OmniRoute）。
改到从它们派生出的代码时**先读对应报告**；报告不够再查上游源码
（`/Users/wangbin/workspace/temp/my-token-route/{CodexBar,OmniRoute}`）。

| 文档 | 什么时候读 |
| --- | --- |
| [`LESSONS.md`](LESSONS.md) | **改代码前必读** |
| [`docs/code-standards.md`](docs/code-standards.md) | 提交前、复盘时 |
| [`docs/gui-implementation-guide.md`](docs/gui-implementation-guide.md) | 改菜单栏/设置窗口/OAuth/指标轮询之前 |
| [`docs/build-release-guide.md`](docs/build-release-guide.md) | 发版、改打包脚本之前 |
| [`docs/codexbar-analysis.md`](docs/codexbar-analysis.md) | 改 Provider 注册表 / HTTP 客户端 / ConfigStore 之前 |
| [`docs/omniroute-analysis.md`](docs/omniroute-analysis.md) | 改路由语法 / 认证 / SSE 处理之前 |
| [`README.md`](README.md) | 改对外行为、供应商列表时同步 |
