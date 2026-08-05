# Rust 网关构建

Rust 网关位于 `binvia-core/`，可独立构建和运行：

```bash
make rust-build
make rust-test
make rust-release
```

开发运行：

```bash
BINVIA_CONFIG=/tmp/binvia-config.json cargo run --manifest-path binvia-core/Cargo.toml -p binvia-gateway --bin binvia
```

默认监听 `127.0.0.1:20427`。配置路径可由 `BINVIA_CONFIG` 覆盖。生产构建会先构建根目录 `web/`，同步到 `binvia-core/web/dist/`，再在编译期嵌入二进制。

当前网关已提供：

- `GET /` Web 面板
- `GET /v1/health`
- `GET /v1/models`
- `POST /v1/chat/completions`
- `GET/POST /v1/usage`
- `/admin/api/*` 配置、日志、Key 和用量接口

真实 Provider 用量查询、OAuth 登录、跨平台守护进程停止命令仍属于后续切片。
