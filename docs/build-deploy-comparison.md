# Binvia 与 CodexBar 构建 / GitHub 部署配置对比与借鉴建议

> 分析日期：2026-08-03
> 对比对象：`/Users/wangbin/workspace/temp/my-token-route/CodexBar`
> 结论速览：Binvia 构建链路完整但缺少**代码签名、版本管理、跨平台构建**；GitHub 侧**完全没有 `.github/`**，无 CI / 无 Release 发布。CodexBar 在这三方面均有成熟实践可参考。

---

## 1. 构建方面对比

### 1.1 Package.swift

| 维度 | Binvia | CodexBar |
|---|---|---|
| 平台 | 仅 `.macOS(.v14)`，全部 target 无条件 | macOS 14 + `#if os(macOS)` 条件编译，Core/CLI 支持 Linux |
| 依赖 | 零外部依赖（设计约束） | Sparkle / Commander / swift-crypto / swift-log / KeyboardShortcuts / Vortex / SweetCookieKit |
| target 数 | 5 个（Core + Server + CLI + App + Check） | 10+（含 testTarget、systemLibrary、按平台拆分） |
| 测试 | 1 个自包含可执行 `BinviaCheck`（无 XCTest，`make test`） | 3 个 `testTarget`（SwiftTesting）+ 分片脚本 |
| 关键差异 | — | **用 `#if os(macOS)` 隔离 GUI target，Core + CLI 可跨 Linux 构建**（`Package.swift:35-42,144-199`） |

> Binvia 的 `BinviaCore` 用 POSIX socket + Foundation，理论上同样可在 Linux 构建 `BinviaServer`/`BinviaCLI`/`BinviaCheck`——这是能否在 GitHub Actions 上跑 CI、发 Linux 产物的前提。

### 1.2 构建 / 打包脚本

| 维度 | Binvia（`Scripts/build.sh`，86 行） | CodexBar（`Scripts/` 50+ 脚本） |
|---|---|---|
| 构建 | `swift build -c release` + BinviaCheck + `--smoke-test` | `package_app.sh`：多架构 + `lipo` universal + `strip` + 双签名模式 |
| 签名 | 无 | adhoc / Developer ID 双模式（`CODEXBAR_SIGNING`），`xattr -cr` 清理属性 |
| 版本 | Info.plist 硬编码 `0.1.0` | `version.env`（MARKETING_VERSION/BUILD_NUMBER）+ git commit/timestamp 注入 |
| 架构 | 仅 host arch | `ARCHES="arm64 x86_64"` 支持 universal |
| 附加 | 手写 `.app` bundle | entitlements、Sparkle 嵌入、widget extension、dSYM |
| 发布 | 无 | `mac-release` + `.mac-release.env` 编排、`sign-and-notarize.sh` 公证 |
| 质量 | 无 lint/format 配置 | `.swiftformat` / `.swiftlint.yml` / `lint.sh` / `install_lint_tools.sh` |

### 1.3 质量工具

- **Binvia**：无 `.swiftformat`、无 `.swiftlint.yml`，测试为单个自包含可执行。
- **CodexBar**：swiftformat + swiftlint 齐全，且在 CI 上强制（`ci.yml` 中 `lint` job）。

---

## 2. GitHub 部署配置对比

**Binvia 完全没有 `.github/` 目录**——尽管已配置 remote（`github: wangbin3162/Binvia.git`），但无任何 workflow、无 tag、无 Release。

**CodexBar 有 3 个 workflow**：

| workflow | 触发 | 职责 |
|---|---|---|
| `ci.yml` | push/PR | 路径门控（path gate）决定是否跑 macOS 测试；lint + macOS 测试 2-shard + Linux musl CLI 构建；`actions/cache` 缓存 swiftly 工具链；`concurrency.cancel-in-progress` |
| `release-cli.yml` | `release` / 手动 | 6 平台矩阵（linux x64/arm64、linux-musl x64/arm64、macos arm64/x86_64）→ 构建 → smoke test → `tar.gz` + `.sha256` → `gh release upload` → Homebrew tap dispatch |
| `upstream-monitor.yml` | 定时（周一/四） | 检查上游仓库新 commit，自动建/更 issue |

---

## 3. 可借鉴建议（按性价比排序）

### 3.1 高价值 / 低成本

1. **加最小 CI（最大差距，优先做）**
   新建 `.github/workflows/ci.yml`：macOS runner 上跑 `swift build` + `make test`（`swift run BinviaCheck`）+ `BinviaApp --smoke-test`。
   借鉴点：`actions/cache` 缓存 `.build`、`concurrency.cancel-in-progress`、固定 toolchain 版本。
   注意：Binvia 测试是自包含可执行，无需 XCTest，runner 自带 Xcode 即可，比 CodexBar 更简单。

2. **Linux 构建/分发**
   Binvia 本质是网关服务器，headless 使用场景天然适合 Linux 部署。
   参考 CodexBar 的 Linux CLI 构建路径，把 `BinviaServer`/`BinviaCLI`/`BinviaCheck` 跨到 Linux（需先验证；POSIX socket + Foundation 可行性高）。
   附带收益：CI 可跑在更便宜的 ubuntu runner 上。

3. **简化版 release workflow**
   参考 `release-cli.yml` 的矩阵模式，做 tag 触发构建：macOS arm64/x86_64（可选 universal）+ 打 `tar.gz` + `.sha256` + 上传 GitHub Releases。
   顺带解决 `Scripts/build.sh` 无产物命名、无版本号、单架构问题。
   Homebrew tap dispatch 部分不需要。

### 3.2 纯增量 / 低风险

4. **版本管理**
   把 `0.1.0` 从 `Scripts/build.sh` 抽到 `version.env`（`MARKETING_VERSION` / `BUILD_NUMBER`），构建时注入 Info.plist 并写入 git commit/timestamp。
   参考：CodexBar `Scripts/package_app.sh:272-273,285-286`。

5. **至少 adhoc 代码签名**
   Binvia 的 `.app` 目前完全未签名，拷给别人会被 Gatekeeper 拦。
   参考：CodexBar 默认 `CODEXBAR_SIGNING=adhoc`（`codesign --force --sign -`）+ `xattr -cr` 清理属性，零证书成本。
   **重要约束**：Binvia 是本地代理服务器，**不能**像 CodexBar widget 那样开 sandbox entitlement，借鉴时只取签名部分。

6. **（可选）universal 二进制**
   `build.sh` 支持 `ARCHES="arm64 x86_64"` + `lipo` 合成。
   参考：CodexBar `Scripts/package_app.sh:70-78,351-369`。

### 3.3 不建议借鉴（过度设计）

- Sparkle 自动更新、notarization、Homebrew tap、widget extension —— 依赖签名证书与第三方，且 Binvia 是零依赖个人项目。
- path-gate 复杂 CI 矩阵 —— 单用户项目过度设计。
- `upstream-monitor.yml` —— Binvia 与 CodexBar/OmniRoute 是文档借鉴关系而非 fork，价值有限（除非想定时盯上游变化）。

---

## 4. 落地清单（Checklist）

- [ ] `.github/workflows/ci.yml`：`swift build` + `make test` + `--smoke-test`
- [ ] 验证 Linux 构建 `BinviaServer`/`BinviaCLI`/`BinviaCheck`
- [ ] `.github/workflows/release.yml`：tag 触发，macOS 双架构产物 + GitHub Releases 上传
- [ ] `version.env`（MARKETING_VERSION / BUILD_NUMBER）+ build.sh 注入 Info.plist
- [ ] `build.sh` 增加 adhoc 代码签名 + `xattr -cr`
- [ ] （可选）`build.sh` 支持 `ARCHES` universal 构建
