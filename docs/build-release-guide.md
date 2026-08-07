# Binvia 构建与发布指南

> 适用版本：v0.1.0 起（当前最新：v0.1.7）。本文档描述**本地打包**与 **GitHub Release 发布**的完整流程。

---

## 1. 发布链路总览

```
开发 → push main → CI 自动验证（构建 + 464 项测试 + GUI 自检）
                     ↓
            打 tag v0.1.0 → push tag → Release workflow 自动：
            双架构构建(arm64+x86_64) → 测试 → adhoc 签名 → tar.gz + SHA256 → GitHub Release
```

- **CI**（`.github/workflows/ci.yml`）：每次 push/PR 触发，保证代码可构建、测试全绿。
- **Release**（`.github/workflows/release.yml`）：打 `v*` tag 触发，产出正式发布包。
- 两个 workflow 都复用本地脚本 `Scripts/build.sh`，**本地与 CI 行为一致**，杜绝"在我机器上能跑"。

---

## 2. 版本管理约定

版本号只有一个源头：**`version.env`**（本地构建用）和 **git tag**（正式发布用）。

```bash
# version.env 内容
MARKETING_VERSION=0.1.0   # 对外版本号，必须与 git tag 一致（v0.1.0 → 0.1.0）
BUILD_NUMBER=1            # 构建号；CI 发布时会自动覆盖为 Actions run_number
```

**铁律**：`version.env` 里的 `MARKETING_VERSION` 必须等于要打的 tag（去掉 `v` 前缀）。
Release workflow 会**以 tag 为准覆盖** version.env，但本地构建前请先手动同步，避免混乱。

版本号注入位置：`Binvia.app/Contents/Info.plist`（`CFBundleShortVersionString` / `CFBundleVersion`），
同时写入 `BinviaGitCommit`（git 短提交）和 `BinviaBuildTime`（构建时间），便于追溯产物来源。

---

## 3. 日常开发命令（本地）

| 命令 | 作用 |
|---|---|
| `make build` | 快速 debug 构建 |
| `make test` | 跑全部测试（BinviaCheck，464 项断言） |
| `make run` | 启动本地网关服务器 |
| `make release` | **完整打包**：双架构 release 构建 + 测试 + GUI 自检 + adhoc 签名 + tar.gz + SHA256，产物在 `bin/` |
| `make clean` | 清空 `.build` 和 `bin/` |

`make release` 的常用变体：

```bash
ARCHES="arm64" make release              # 只打本机架构（快，日常自检用）
MARKETING_VERSION=0.2.0 BUILD_NUMBER=2 ./Scripts/build.sh   # 临时覆盖版本号
```

### 产物说明（bin/）

| 产物 | 说明 |
|---|---|
| `Binvia-<版本>-macos-arm64-x86_64.dmg` | **正式发布物**：带样式背景的拖入安装 DMG（仅 Binvia.app + Applications 快捷方式；布局模板 `Scripts/dmg-template.DS_Store` + 背景 `assets/dmg-background.png`，用 `Scripts/make_dmg_background.swift` 重新生成） |
| `Binvia-<版本>-macos-arm64-x86_64.tar.gz` | 免安装版备用包（含 app + 命令行工具） |
| `SHA256SUMS` | 校验和（发布时一并上传） |
| `Binvia.app` / `BinviaServer` / `BinviaCLI` | 未打包的原始产物（universal，已签名） |

命令行工具（BinviaServer / BinviaCLI）不再进 DMG，改为 curl 一键安装：
`Scripts/install-cli.sh`（发布时作为 Release 资产上传，支持版本参数与 SHA256 校验）。

验证打包结果：

```bash
lipo -info bin/BinviaApp          # 应输出 x86_64 arm64
codesign -dv bin/Binvia.app       # adhoc 模式显示 Signature=adhoc；developer 模式显示 Developer ID
plutil -p bin/Binvia.app/Contents/Info.plist   # 检查版本号
hdiutil attach bin/Binvia-*.dmg   # 挂载检查 DMG 内容（检查完 detach）
```

### 签名模式

`build.sh` 支持三种签名模式（环境变量 `BINVIA_SIGNING`）：

| 模式 | 用途 | 命令 |
|---|---|---|
| `adhoc`（默认） | 本地自用/未公证分发 | 零成本 |
| `developer` | 正式公证分发 | `BINVIA_SIGNING=developer DEVELOPER_ID_CERT="Developer ID Application: 名字 (TEAMID)" ./Scripts/build.sh` |
| `none` | 调试 | `BINVIA_SIGNING=none ./Scripts/build.sh` |

`developer` 模式使用 hardened runtime（`--options runtime`），是 Apple 公证的硬性前置。

---

## 4. 发布正式版本（标准流程）

> 前提：代码已提交并 push 到 `main`，CI 已跑绿。

### 步骤一：确认版本号

```bash
cat version.env          # 确认 MARKETING_VERSION 就是要发布的版本
```

### 步骤二：本地完整自检（可选但推荐）

```bash
make release             # 双架构构建 + 测试 + 签名，确认本地全绿
```

### 步骤三：提交并打 tag

```bash
git add version.env Scripts/build.sh .github/
git commit -m "Prepare release v0.1.0"
git push origin main

git tag v0.1.0           # tag 名必须带 v 前缀，版本号与 version.env 一致
git push origin v0.1.0   # 推送 tag 即触发 Release workflow
```

### 步骤四：等待并校验（约 10-15 分钟）

1. 打开 https://github.com/wangbin3162/Binvia/actions → 看到 `Release` workflow 运行。
2. 全部步骤绿后，打开 https://github.com/wangbin3162/Binvia/releases
3. 确认：`Binvia-0.1.x-macos-arm64-x86_64.dmg` + tar.gz + `install-cli.sh` + `SHA256SUMS` 已上传，标题为对应版本。
4. （可选）下载 DMG，本地验证：

```bash
shasum -a 256 -c SHA256SUMS        # 校验完整性
open Binvia-0.1.x-macos-arm64-x86_64.dmg   # 打开确认样式背景与拖入安装
```

**发布完成。** 下一版本只需重复步骤一~四（版本号递增）。

---

## 5. 手动触发发布（备用）

不依赖 tag，在 Actions 页面手动运行 `Release` workflow：

- 进入 https://github.com/wangbin3162/Binvia/actions → 左侧 `Release` → `Run workflow`
- 填版本号（如 `0.1.0`），点击运行

效果与 tag 触发相同，但**不会创建 tag**（Release 会指向默认分支 HEAD）。
日常请优先使用 tag 流程，手动触发仅用于补发/测试。

---

## 6. 版本发布记录

| 版本 | 日期 | 内容 | 产物（bin/） |
|---|---|---|---|
| v0.1.7 | 2026-08-07 | 模型列表修复（对齐/重名操作/上下文填充）；/v1/models 附带 context_length（见下） | `Binvia-0.1.7-macos-arm64-x86_64.dmg` / `.tar.gz` |
| v0.1.6 | 2026-08-06 | 移除 Cursor 供应商支持；禁用 provider 不轮询用量/不显示 Tab；MiniMax/Zai 切 OpenAI 兼容（见下） | `Binvia-0.1.6-macos-arm64-x86_64.dmg` / `.tar.gz` |
| v0.1.5 | 2026-08-06 | 请求响应速度优化（见下） | `Binvia-0.1.5-macos-arm64-x86_64.dmg` / `.tar.gz` |

### v0.1.7 变更内容

- **模型列表设置面板修复**：输入框与表头对齐（macOS Form 中 TextField 必须加 `.labelsHidden()`
  才尊重 `.frame(width:)`，否则塌缩成 prompt 决定的固有宽度——经验见 `lessons.md`）；
  「菜单显示名」「实际请求模型」输入框加宽、「上下文窗口」收窄。
- **重名条目按索引操作**：删除/编辑/下拉填充全部按列表索引定位（`remove(at:)` / `[index]`），
  新增同名模型后删一个不再误删两个、填充不再覆盖到其他行。
- **下拉填充自动带入上下文窗口**：选择「获取模型列表」的模型时，自动把供应商目录中的真实
  `contextLength` 填入输入框（Kimi/CodeBuddy/Antigravity 等静态目录带真实值）；
  上游接口未提供（如 DeepSeek 动态拉取）时保留默认 1_000_000。
- **/v1/models 附带 `context_length`**：响应每项模型新增该字段（来自设置面板条目，
  默认 1_000_000），客户端可据此展示各模型上下文窗口。
- **新增 `lessons.md` 踩坑记录**：SwiftUI Form/TextField 布局、列表按索引操作两条经验；
  `AGENTS.md` 尾部新增引用；移除已被 AGENTS.md 取代的 `CLAUDE.md` / `CODEBUDDY.md`。

### v0.1.6 变更内容

- **移除 Cursor 供应商支持**：删除 Cursor provider 及其 IDE 登录令牌检测（`CursorCredentialStore`）、
  私有协议 RPC（HTTP/2 Connect-RPC / protobuf）、用量查询器与模型目录；同时移除 `BinviaCLI cursor` 子命令、
  GUI 的「Cursor IDE 接入 / 手动导入账号」区块与 `ProviderCredential.machineId` 字段。
  新增供应商为 9 家（DeepSeek / CodeBuddy / Antigravity / opencode / Kimi / opencode-go / MiMo / z.ai / MiniMax）。
- **禁用 provider 不再获取用量与显示 Tab**：`AppState.refreshAllUsage` 只轮询已启用 provider（不再打
  禁用供应商的用量接口）；主面板 Tab / 健康度列表（`configuredProviders`）与「活跃 provider 数」
  均要求「已启用且已配置凭据」，与 `RouteHandler` 的 `/v1/models` 判定口径一致。
  设置面板侧栏仍展示全部 provider，可随时重新启用。
- **MiniMax / z.ai 切换 OpenAI 兼容端点**：`/v1/chat/completions` + `Authorization: Bearer`，
  rawBody 透传（天然支持工具调用），移除 Anthropic 兼容共享执行器（`AnthropicCompatChatExecutor` / `AnthropicEnvelopeTranslator`）。

### v0.1.5 优化内容

针对「开启服务后总觉得慢」的根因修复（实测数据）：

- **`/v1/models` 跳无凭据 provider 动态获取**：`RouteHandler.handleModels` 仅对有凭据的 provider
  调 `listModels`，无凭据直接静态目录。实测 `62s → 冷 14.6s → 热 0.008s`。
- **非流式请求 12s 超时封顶**：`ProviderHTTPClient.data` 对用量查询/模型列表/探测统一超时封顶
  （URLSession 默认 60s，上游不可达时会拖住分钟级）；流式请求不受影响。
- **用量刷新并行化**：`AppState.refreshAllUsage` 改为 `withTaskGroup`，单个用量接口慢不再拖住全部。
- **Antigravity 失败缓存**：动态模型获取失败时写缓存（300s TTL），避免每次 `/v1/models` 重复打上游；
  TTL 过期自动重试上游。

---

## 7. 注意事项与常见问题

### 7.1 Gatekeeper 拦截（预期行为）

产物是 **adhoc 签名、未经过 Apple 公证**，首次从网上下载打开时，
Gatekeeper 可能提示"无法验证开发者"。这是个人项目的正常现象，解决方式：

- 右键 Binvia.app → 打开 → 确认；或
- 系统设置 → 隐私与安全性 → 点击「仍要打开」；或
- 终端执行 `xattr -cr /Applications/Binvia.app` 清除隔离属性

**升级为公证版**（消除所有警告）：购买 Apple Developer 会员（$99/年）后：

1. 在 developer.apple.com 创建 **Developer ID Application** 证书并装入钥匙串；
2. 用 developer 模式重新打包：
   `BINVIA_SIGNING=developer DEVELOPER_ID_CERT="Developer ID Application: 名字 (TEAMID)" ./Scripts/build.sh`
3. 对 DMG 整体公证 + 装订：

```bash
xcrun notarytool submit bin/Binvia-<版本>-macos-arm64-x86_64.dmg \
  --key AuthKey_XXXX.p8 --key-id XXXX --issuer-id XXXX-XXXX --wait
xcrun stapler staple bin/Binvia-<版本>-macos-arm64-x86_64.dmg
```

公证后用户双击直接打开，无任何警告。证书与凭证均为私密资产，勿提交到仓库；
CI 自动化签名需将证书导出为 .p12 加密后存为 repo secret。

### 7.2 CI 里没有 Xcode 也能跑？

GitHub Actions 的 `macos-26` runner 自带 Xcode，`swift build` 直接可用。
选 `macos-26`（arm64 + SDK 26）是为了与本机开发环境（Swift 6.3 / SDK 26）一致：
旧 SDK 编译的 app 在 macOS 26 上不会套用新的 SwiftUI 圆角/边框设计。
若未来 GitHub 调整 runner 标签，把 `ci.yml` / `release.yml` 中的 `macos-26` 换成
仍可用的同代标签即可（同时保持 setup-swift 版本与本机一致）。

### 7.3 多架构构建的 "swift-version file not registered" 错误

这是 SwiftPM 的已知问题：顺序执行 `swift build --arch arm64` 和 `--arch x86_64` 时，
顶层 `.build/release` 符号链接会在两架构间翻转，导致第二次构建报错。
`build.sh` 已用**每架构独立 `--scratch-path`**（`.build/<arch>/`）规避，不要再改回
共享 `.build` 的写法。

### 7.4 版本号与 tag 不一致会怎样？

Release workflow 以 **tag 为准**（tag `v0.2.0` + version.env 里 `0.1.0` → 产物为 0.2.0，
version.env 被覆盖）。本地构建则以 version.env 为准。所以**改版本号务必两处同步**。

### 7.5 测试在 CI 上会不会依赖真实网络？

不会。BinviaCheck 的 464 项断言全部使用 mock（`URLProtocolMock` + 本地 `HTTPServer`），
测试入口会把 `BINVIA_CONFIG` 指到 `/tmp` 并清空凭据环境变量，不会触碰真实配置与上游。

---

## 8. 本次构建改造清单（相对旧版 build.sh）

- [x] 版本号从 `version.env` 读取，注入 Info.plist（不再硬编码 0.1.0），附带 git commit / 构建时间
- [x] 默认双架构构建（`ARCHES="arm64 x86_64"`），`lipo` 合成 universal 产物
- [x] 签名双模式：adhoc（默认）/ developer（公证前置，hardened runtime）/ none
- [x] **带样式 DMG**：背景图（`Scripts/make_dmg_background.swift` 生成）+ Finder 布局模板（`Scripts/dmg-template.DS_Store`），拖入安装；仅含 Binvia.app
- [x] **命令行工具 curl 安装**：`Scripts/install-cli.sh`（版本参数 + SHA256 校验），Release 资产随版本发布
- [x] tar.gz 备用包 + `SHA256SUMS`（含 DMG）
- [x] 构建前清理 `bin/`，避免旧产物残留
- [x] `.github/workflows/ci.yml`：push/PR 自动构建 + 测试 + 打包自检
- [x] `.github/workflows/release.yml`：tag 触发，自动发布 DMG + tar.gz + install-cli.sh 到 GitHub Releases
