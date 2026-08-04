# Binvia 构建与发布指南

> 适用版本：v0.1.0 起。本文档描述**本地打包**与 **GitHub Release 发布**的完整流程。

---

## 1. 发布链路总览

```
开发 → push main → CI 自动验证（构建 + 698 项测试 + GUI 自检）
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
| `make test` | 跑全部测试（BinviaCheck，698 项断言） |
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
| `Binvia.app` | 菜单栏 GUI（LSUIElement），**universal**（arm64 + x86_64），adhoc 签名 |
| `BinviaServer` / `BinviaCLI` | 服务端与 CLI 可执行文件，universal，adhoc 签名 |
| `Binvia-<版本>-macos-arm64-x86_64.tar.gz` | 三者打包，**发布用** |
| `SHA256SUMS` | 压缩包校验和（发布时一并上传，用户可验证完整性） |

验证打包结果：

```bash
lipo -info bin/BinviaApp          # 应输出 x86_64 arm64
codesign -dv bin/Binvia.app       # 应显示 Signature=adhoc
plutil -p bin/Binvia.app/Contents/Info.plist   # 检查版本号
```

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
3. 确认：`Binvia-0.1.0-macos-arm64-x86_64.tar.gz` + `SHA256SUMS` 已上传，标题为 `Binvia 0.1.0`。
4. （可选）下载压缩包，本地解压验证：

```bash
shasum -a 256 -c SHA256SUMS        # 校验完整性
open Binvia.app                    # 确认能启动
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

## 6. 注意事项与常见问题

### 6.1 Gatekeeper 拦截（预期行为）

产物是 **adhoc 签名、未经过 Apple 公证**，首次从网上下载打开时，
Gatekeeper 可能提示"无法验证开发者"。这是个人项目的正常现象，解决方式：

- 右键 Binvia.app → 打开 → 确认；或
- 系统设置 → 隐私与安全性 → 点击「仍要打开」；或
- 终端执行 `xattr -cr /Applications/Binvia.app` 清除隔离属性

未来若需要无提示安装：购买 Apple Developer 证书（$99/年），在 build.sh 中增加
Developer ID 签名 + notarization（参见 `docs/build-deploy-comparison.md` §3.3，当前有意不做）。

### 6.2 CI 里没有 Xcode 也能跑？

GitHub Actions 的 `macos-15` runner 自带 Xcode，`swift build` 直接可用。
若未来 GitHub 下线该 runner 标签，把 `ci.yml` / `release.yml` 中的 `macos-15` 换成
仍可用的标签（如 `macos-14`、`macos-26`）即可。

### 6.3 多架构构建的 "swift-version file not registered" 错误

这是 SwiftPM 的已知问题：顺序执行 `swift build --arch arm64` 和 `--arch x86_64` 时，
顶层 `.build/release` 符号链接会在两架构间翻转，导致第二次构建报错。
`build.sh` 已用**每架构独立 `--scratch-path`**（`.build/<arch>/`）规避，不要再改回
共享 `.build` 的写法。

### 6.4 版本号与 tag 不一致会怎样？

Release workflow 以 **tag 为准**（tag `v0.2.0` + version.env 里 `0.1.0` → 产物为 0.2.0，
version.env 被覆盖）。本地构建则以 version.env 为准。所以**改版本号务必两处同步**。

### 6.5 测试在 CI 上会不会依赖真实网络？

不会。BinviaCheck 的 698 项断言全部使用 mock（`URLProtocolMock` + 本地 `HTTPServer`），
测试入口会把 `BINVIA_CONFIG` 指到 `/tmp` 并清空凭据环境变量，不会触碰真实配置与上游。

---

## 7. 本次构建改造清单（相对旧版 build.sh）

- [x] 版本号从 `version.env` 读取，注入 Info.plist（不再硬编码 0.1.0），附带 git commit / 构建时间
- [x] 默认双架构构建（`ARCHES="arm64 x86_64"`），`lipo` 合成 universal 产物
- [x] adhoc 代码签名 + `xattr -cr`（零证书成本；未开 sandbox entitlement）
- [x] 打包 `tar.gz` + `SHA256SUMS`，可直接上传发布
- [x] 构建前清理 `bin/`，避免旧产物残留
- [x] `.github/workflows/ci.yml`：push/PR 自动构建 + 测试 + 打包自检
- [x] `.github/workflows/release.yml`：tag 触发，自动发布 GitHub Release
