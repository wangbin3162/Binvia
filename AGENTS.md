# Repository Guidelines

Binvia is a macOS local AI-provider aggregation gateway. It exposes an OpenAI-compatible API (`/v1/chat/completions`, `/v1/models`, `/v1/usage`, `/v1/health`) on a local port and routes requests to DeepSeek, Tencent CodeBuddy, and Google Antigravity. Pure Swift + native POSIX sockets, **zero third-party dependencies**.

## Project Structure & Module Organization

Swift Package (5 targets, `Package.swift`), all with `StrictConcurrency` enabled:

```
Sources/
├── BinviaCore/        # 核心库：Provider 协议/注册表、Router、Auth、Config、Networking、Server、Monitoring
│   └── Providers/         # deepseek / codebuddy-cn / antigravity（每供应商一个目录）
├── BinviaServer/      # 服务器入口 main.swift
├── BinviaCLI/          # CLI：providers / test / oauth / config / serve
├── BinviaApp/          # 菜单栏 GUI（SwiftUI + AppKit），含 --smoke-test
└── BinviaCheck/        # 自包含测试可执行（非 XCTest）
```

Docs live in `docs/`. Build artifacts in `bin/` and `.build/`. Scripts in `Scripts/`.

## Build, Test, and Development Commands

The machine runs only Command Line Tools (no Xcode/xctest), so **`swift test` is unavailable**. Tests run as an executable.

- `swift build` — build all targets
- `make test` (= `swift run BinviaCheck`) — run the full test suite; exit 0 = pass, 1 = failures
- `make run` (= `swift run BinviaServer`) — start the server; add `--port N` / `--config PATH`
- `swift run BinviaCLI providers list` — list providers and models
- `swift run BinviaCLI test <provider|alias>` — availability test
- `swift run BinviaApp` — run the menu-bar GUI
- `swift run BinviaApp --smoke-test` — headless self-check
- `make release` (= `./Scripts/build.sh`) — release build + self-check, output to `bin/`
- `make clean` — remove `.build` and `bin/`

## Coding Style & Naming Conventions

- **Language**: Swift 6.2, macOS 14+. All targets use `enableUpcomingFeature("StrictConcurrency")` — write `Sendable`-conformant, `@MainActor`-aware code.
- **Comments & docs**: Chinese, matching existing style in `README.md` and source files.
- **Dependencies**: none. Prefer Foundation/AppKit; do not introduce third-party packages without strong justification.
- **Provider pattern**: implement `Provider` (in `Sources/BinviaCore/Provider/Provider.swift`), add a `ProviderDescriptor`, and register one line in `Providers/ProviderCatalog.swift`. Update the provider table in `README.md`.
- **Indentation**: 4 spaces, matching existing source.

## Testing Guidelines

Tests live in `Sources/BinviaCheck/main.swift` using a minimal in-house assertion framework (`expectEqual` / `True` / `False` / `Nil` / `Throws`), grouped via `run(name) { }`. **No XCTest, no per-case filtering** — to run a subset, temporarily comment out `run(...)` lines in the entry.

Network tests use two mock styles: `URLProtocolMock` (URLSession-layer, for retry-policy tests) and a real local `HTTPServer` as a mock upstream (for SSE/integration tests). The test entry sets `BINVIA_CONFIG` to a `/tmp` path and clears credential env vars — never let a new test read or write the real local config.

Add tests for any change to shared behavior (routing, auth, retry, SSE aggregation, config parsing).

## Commit & Pull Request Guidelines

This repo has no Git history available locally, so follow conventional, descriptive commit messages: imperative mood, short summary line, e.g. `Add retry-after header handling in ProviderHTTPClient`.

PRs should:
- Reference the relevant module/provider in the title or description.
- Include verification output (`make test` result; `curl` against a running server for API changes; `--smoke-test` for GUI changes).
- Keep changes scoped to the request — no unrelated refactors, no opportunistic reformatting.

## Reference Documentation

`docs/` holds analysis reports for the two upstream projects this codebase borrows from. Read the relevant report **before** modifying code derived from it; consult the upstream source only when the report is insufficient.

- **CodexBar** (macOS menu-bar AI usage monitor, Swift) — source of the `ProviderDescriptor`/registry, `ProviderHTTPClient`, `ConfigStore`, and menu-bar GUI patterns. Read `docs/codexbar-analysis.md` first; if needed, inspect the source at `/Users/wangbin/workspace/temp/my-token-route/CodexBar`.
- **OmniRoute** (AI routing gateway, TypeScript) — source of the `provider/model` routing syntax, api-key auth, SSE chat handler, provider registry, and the CodeBuddy/Antigravity request headers and model catalogs. Read `docs/omniroute-analysis.md` first; if needed, inspect the source at `/Users/wangbin/workspace/temp/my-token-route/OmniRoute`.
- **GUI** — menu-bar app, settings window, OAuth flows, and metrics polling must follow `docs/gui-implementation-guide.md`.

## Notes

- Config file: `~/.config/binvia/config.json` (`BINVIA_CONFIG` overrides). Credential env vars: `DEEPSEEK_API_KEY`, `CODEBUDDY_CN_ACCESS_TOKEN`, `ANTIGRAVITY_ACCESS_TOKEN`. Gateway keys: `BINVIA_API_KEY` / `ROUTER_API_KEY`.
- Forced-streaming upstreams (CodeBuddy, Antigravity) aggregate SSE to JSON for non-streaming clients via `SSEJSONAggregator`; follow this pattern for new OAuth-based providers.
- `HTTPServer.setHandler()` supports runtime hot-replacement of the route handler — the GUI's hot-reload depends on it; don't break this contract.

## Lessons

踩坑记录与经验沉淀在仓库根目录 `lessons.md`（SwiftUI Form/TextField 布局、列表按索引操作等）。**改动 GUI 布局或列表增删改逻辑前，先阅读 `lessons.md` 中相关条目，避免重复踩坑。**
