# 流式服务对齐 OmniRoute 优化计划

> 制定日期：2026-08-11
> 参考：OmniRoute `open-sse/utils/stream.ts`、`open-sse/utils/streamReadiness.ts`、
> `open-sse/utils/streamFailureFinalization.ts`、`src/shared/utils/runtimeTimeouts.ts`
> 关联现状：Binvia 已完成 Phase 0（中途错误传播、基础 finish_reason 补发、60s 流式空闲超时），
> 并已实施 Phase 1-5（事件级 SSE 归一化、readiness/idle 超时、非 2xx 状态保真、
> early EOF 重试与错误分类、JSON 转 SSE 与 finish_reason 归一化）

## 1. 背景与目标

用户场景：两个 agent 同时通过 Binvia 使用同一模型时，偶发
`Error: Stream ended without finish_reason`，或请求长时间挂起。

上一轮已定位并修复本地网关的核心缺陷：

- 首个 chunk 之后的上游错误会被吞掉，导致本地连接挂起或静默 EOF；
- 流正常结束但缺少 `finish_reason` 时，客户端 SDK 会报
  `Stream ended without finish_reason`。

本轮目标是继续对齐 OmniRoute 的流式服务实现，让 Binvia 对 OpenAI 兼容
流式客户端做到：

1. 流协议完整：结束前必有 `finish_reason`，且顺序在 `[DONE]` 之前；
2. 超时明确：上游不发首包、中途停流都能在可配置时间内失败，而不是无限挂起；
3. 错误可识别：非 2xx、流中断、空闲超时返回明确状态码/错误码；
4. 短暂故障可恢复：首包前早断（early EOF）做一次安全重试；
5. 异常上游可兼容：忽略 `stream:true` 返回 JSON 的上游不再破坏客户端解析。

范围说明：只对齐「本地网关流式服务」部分。不做 OmniRoute 的多格式翻译
（Anthropic/Gemini/Responses）、MITM、组合路由、多账号熔断回退。

## 2. 当前现状

### 2.1 Binvia 流式链路

| 模块 | 现状 |
|---|---|
| `HTTPServer` | accept 循环 + 每连接独立 `Task.detached`，并发能力正常 |
| `ProviderHTTPClient.stream(for:)` | 逐字节透传；非 2xx 错误 body 以 200 透传；已加 60s 空闲超时封顶 |
| `ProviderHTTPClient.streamThrowing(for:)` | 非 2xx 抛错，DeepSeek/Kimi/CodeBuddy 使用；已加 60s 空闲超时封顶 |
| `RouteHandler.firstChunk` | 已修复：剩余流出错时 `finish(throwing:)`，不再挂起 |
| `RouteHandler.responseStream` | 已修复：中途错误转成 SSE error / JSON error |
| `TokenUsageExtractor` | 已新增 `sawFinishReason`，流正常结束时补发 `finish_reason: stop` |

### 2.2 与 OmniRoute 的主要差距

| 能力 | OmniRoute | Binvia 当前 |
|---|---|---|
| 事件级 SSE 解析 | 有完整 transform 管线，跨 chunk 缓冲事件 | 只有 `SSEParser` 用于旁路解析，透传仍是字节级 |
| 缺 finish_reason 时补发 | 在 `[DONE]` 之前插入合成 chunk，并统一发 `[DONE]` | EOF 后追加合成 chunk，不补 `[DONE]`；若上游已发 `[DONE]` 则顺序错误 |
| 首事件 readiness 超时 | 默认 80s，按历史/工具/推理等级自适应到 180s | 无独立 readiness 超时，依赖 URLSession 60s |
| 流空闲超时 | 600s 默认，看门狗每 10s 检查，env 可配 | 60s URLRequest 封顶，无看门狗、无心跳 |
| 非 2xx 状态保真 | 握手期直接返回正确状态码 | Generic/OpenCode/Zai/MiniMax 等仍把上游 4xx 变 200 |
| early EOF 重试 | 首包前早断自动重试一次 | 无 |
| 错误分类 | `stream_idle_timeout` / `stream_pipeline_error` / `client_disconnected` | 仅通用 `upstream_error` |
| JSON 上游响应转 SSE | 有 `maybeConvertJsonBodyToSse` | 无 |
| finish_reason 归一化 | `safety` → `content_filter`、`max_tokens` → `length` 等 | 无 |

## 3. 可行性分析

结论：可行。全部能力都可以用 Foundation + 现有 `SSEParser` 实现，不需要引入
第三方依赖，不改变 Binvia 的零依赖约束。

| 计划项 | 可行性 | 关键点 |
|---|---|---|
| 事件级 SSE 归一化 | 高 | `SSEParser` 已能跨 chunk 产出完整事件；重建输出时保留原始事件文本即可不丢字段 |
| readiness 超时 | 高 | `firstChunk` 在响应头发出前执行，用 `Task.sleep` 竞争首个事件即可 |
| 空闲看门狗 | 高 | 在 `responseStream` 内记录最后事件时间，每 10s 检查一次 |
| 非 2xx 状态保真 | 高 | 把 Generic/OpenCode/Zai 等从 `stream(for:)` 切到 `streamThrowing(for:)` 或按状态提前返回 |
| early EOF 重试 | 中 | 只在响应头发出前且未产生任何输出时重试一次，安全性可控 |
| JSON 响应转 SSE | 中 | 首个事件非 `data:`/`event:`/注释时，按 JSON completion 合成 SSE |
| finish_reason 归一化 | 高 | 在 `TokenUsageExtractor` / `SSEJSONAggregator` 中做小映射表 |

主要技术风险：

- 逐字节透传改为事件级重建后，可能改变上游原始字节序。缓解：输出事件时
  原样使用 `SSEParser` 返回的完整事件文本，只补 `\n\n`，不重新序列化；
- `firstChunk` 超时需要取消仍在运行的上游读取任务，否则超时后后台任务可能
  继续占用连接。缓解：provider 流已设置 `continuation.onTermination` 取消，
  超时路径同时取消 drain task；
- readiness 超时如果太短会误杀长推理模型。缓解：默认值放宽，支持 env 覆盖，
  按模型/请求体大小可加缓冲（对齐 OmniRoute 的 `streamReadinessPolicy`）。

## 4. 必要性分析

按用户可见收益和改动成本分级：

| 优先级 | 项目 | 必要性 |
|---|---|---|
| P0 | 流协议完整（finish_reason 在 `[DONE]` 前） | 高。直接消除 `Stream ended without finish_reason` |
| P0 | 非 2xx 状态保真 | 高。上游 429/400 目前被伪装成 200，客户端误报且不可重试 |
| P0 | 首事件 readiness 超时 | 高。上游只回头部不发 body 时，当前仍可能长时间挂起 |
| P1 | 流空闲看门狗 | 中。缓解中途停流；现有 60s 封顶已提供基础保护 |
| P1 | early EOF 单次重试 | 中。减少并发高峰的偶发失败，收益直接对应本问题 |
| P1 | 错误分类与日志 | 中。`/v1/usage` 才能看出失败原因，而不是一律 200 |
| P2 | JSON 响应转 SSE | 低。自定义 provider 场景才常见 |
| P2 | finish_reason 归一化 | 低。Binvia 目前主要接 OpenAI 兼容上游 |
| P2 | SSE 心跳 | 低。本地回环客户端通常不需要保活 |

建议：P0 和 P1 值得做；P2 视维护成本决定是否纳入。

## 5. 目标架构

```
Provider chat 原始流（字节）
  → UpstreamStatusGate     非 2xx 在响应头发出前转成正确状态码
  → StreamReadinessGate    首事件超时 + early EOF 单次重试
  → SSEStreamNormalizer    跨 chunk 解析事件、跟踪 finish_reason、
                           暂存 [DONE]、补发合成结束 chunk
  → RouteHandler.responseStream
  → IdleWatchdog           超过空闲阈值时回传 stream_idle_timeout
  → HTTPServer.writeResponse → 客户端
```

新增模块建议放在 `Sources/BinviaCore/Networking/`，保持与 `SSEParser`、
`SSEJSONAggregator` 同层。

## 6. 实施阶段

### Phase 0：中途错误传播与基础结束标记（已完成）

- `firstChunk` 剩余流错误 `finish(throwing:)`；
- `responseStream` 错误转 SSE error / JSON error；
- 流正常结束且缺 `finish_reason` 时补发 `finish_reason: stop`；
- `ProviderHTTPClient` 增加 60s 流式空闲超时封顶；
- 回归测试：`make test` 535 项断言通过。

### Phase 1：SSEStreamNormalizer 事件级归一化（已完成）

目标：把字节透传升级为事件级透传，保证结束块顺序正确。

新增 `Sources/BinviaCore/Networking/SSEStreamNormalizer.swift`：

- 输入：上游 chunk 流；
- 内部复用 `SSEParser`，跨 chunk 累积事件；
- 输出：`AsyncThrowingStream<Data, Error>`；
- 行为：
  - 普通 `data:` / `event:` / 注释事件按原文本输出（补 `\n\n`）；
  - `data: [DONE]` 暂存，不立即转发；
  - 跟踪是否出现过非空 `finish_reason`（工具调用时归一化为 `tool_calls`）；
  - 流结束时：若缺 `finish_reason`，先输出合成结束 chunk，再输出暂存的
    `[DONE]`（没有则补发 `[DONE]`）；
- 首个完整事件不是 SSE 时，标记为 JSON body 模式，交给 Phase 5 处理。

设计约束（为后续格式兼容预留）：

- 第一版就引入 `StreamFormat`（当前仅 `.openaiChat`），normalizer 不硬编码
  “结束标记 = `choices[0].finish_reason`”；
- 结束标记识别与合成 terminal chunk 由 format 策略提供：
  - OpenAI Chat：`choices[0].finish_reason` + `[DONE]`；
  - Responses：`response.completed` / `status`；
  - Anthropic：`message_delta.stop_reason`；
- 这样后续新增 `/v1/responses`、`/v1/messages` 时，normalizer 只需注册新的
  format 策略，不需要重写事件边界逻辑。

接入点：`RouteHandler.responseStream` 的 `for try await chunk in remaining`
改为消费 `SSEStreamNormalizer`；`TokenUsageExtractor` 可保留在 normalizer
之后做 usage 旁路，或合并进 normalizer。

验收：

- mock 上游把事件拆成任意 byte 边界，输出事件内容不变；
- 上游发 `[DONE]` 但不发 finish_reason，客户端收到的顺序是
  `finish_reason chunk` → `[DONE]`；
- 上游完全不发结束标记，客户端收到合成 `finish_reason: stop` → `[DONE]`；
- `make test` 全量通过。

### Phase 2：readiness 与空闲超时（已完成）

目标：首事件和流空闲都有明确上限，且可配置。

实施：

- `ProviderHTTPClient` 常量改为可读 env：
  - `BINVIA_STREAM_READINESS_TIMEOUT`，默认 60s；
  - `BINVIA_STREAM_IDLE_TIMEOUT`，默认 120s；
- `firstChunk` 用 `withThrowingTaskGroup` 竞争首个事件与 readiness 超时；
  超时返回 504 + `stream_readiness_timeout`，不再把连接交给客户端；
- `responseStream` 增加空闲看门狗：每 10s 检查最后事件时间，超过
  `BINVIA_STREAM_IDLE_TIMEOUT` 时回传 SSE error（`stream_idle_timeout`）并结束；
- 长推理场景参考 OmniRoute：按请求体大小、消息数、工具数、模型名加缓冲
  （首版可只做固定默认 + env 覆盖，不实现完整策略）。

验收：

- mock 上游返回 200 但永不发 body：客户端在 readiness 超时内收到 504；
- mock 上游发几个 chunk 后停流：客户端收到 `stream_idle_timeout` 错误；
- `BINVIA_STREAM_READINESS_TIMEOUT=5` 时超时时间约为 5s；
- `make test` 全量通过。

### Phase 3：非 2xx 状态保真（已完成）

目标：上游 4xx/5xx 在响应头发出前转成正确 HTTP 状态码。

实施：

- `GenericOpenAIProvider`、`OpenCodeProvider`、`ZaiProvider`、
  `MiniMaxProvider`、`XiaomiMimoProvider` 等从 `stream(for:)` 切到
  `streamThrowing(for:)`，或在 provider 内解析非 2xx；
- `RouteHandler` 在 `firstChunk` 阶段已能捕获错误并返回 502；对 401/403/429
  保留上游状态码或映射为 401/403/429，而不是统一 502；
- 保持 DeepSeek / Kimi / CodeBuddy 现有轮换逻辑不变。

验收：

- mock 上游返回 400/429/502，curl 看到对应状态码和上游错误 body；
- 非流式和流式客户端行为一致；
- 现有 key 轮换测试不回归；
- `make test` 全量通过。

### Phase 4：early EOF 重试与错误分类（已完成）

目标：首包前早断自动重试一次；日志能区分失败类型。

实施：

- 在 readiness 阶段定义 `StreamErrorCode`：
  - `stream_readiness_timeout`
  - `stream_idle_timeout`
  - `stream_early_eof`
  - `upstream_error`
  - `client_disconnected`
- 只在响应头发出前且未产生任何输出时，对 `stream_early_eof` 重试一次
  （对齐 OmniRoute `shouldRetryStreamEarlyEof`，最多一次）；
- `RequestLogEntry` 增加可选 `errorCode` 字段，`/v1/usage` 返回；
- 错误体里带 `code` 字段。

验收：

- mock 上游第一次空流、第二次正常：客户端拿到正常结果，日志记录一次重试；
- mock 上游连续两次空流：返回 502 + `stream_early_eof`；
- 流中途断连不再重试（已产生输出，重试会造成重复内容）；
- `make test` 全量通过。

### Phase 5（已完成）：JSON 响应转 SSE 与 finish_reason 归一化

目标：兼容忽略 `stream:true` 的上游，和 Gemini 等非 OpenAI 结束原因。

实施：

- `SSEStreamNormalizer` 检测 JSON completion body，按
  `id/model/created/choices[0].delta/finish_reason` 合成 SSE chunk；
- `TokenUsageExtractor` / `SSEJSONAggregator` 增加归一化映射：
  - `max_tokens` → `length`
  - `safety` / `recitation` / `prohibited_content` → `content_filter`
  - `malformed_function_call` 等保留原始值，不伪装成 `stop`
- 参考 OmniRoute `open-sse/utils/finishReason.ts`。

验收：

- mock 上游对 `stream:true` 返回 JSON：客户端收到合法 SSE；
- 聚合非流式响应时 `finish_reason` 归一化正确；
- `make test` 全量通过。

### Phase 6：文档与发布验证

- README 环境变量表补充 `BINVIA_STREAM_*`；
- `docs/build-release-guide.md` 更新版本说明；
- 回归：
  - `make test` 全量通过；
  - `swift run BinviaApp --smoke-test` 通过；
  - `make release` 产物自检通过。

## 7. 常量与配置

| 环境变量 | 默认值 | 作用 |
|---|---|---|
| `BINVIA_STREAM_READINESS_TIMEOUT` | 60s | 首个事件超时 |
| `BINVIA_STREAM_IDLE_TIMEOUT` | 120s | 两次事件之间的空闲超时 |
| `BINVIA_STREAM_EARLY_EOF_RETRY` | 1 | 首包前早断最大重试次数（0 关闭） |

默认值选择依据：

- 60s readiness 覆盖绝大多数模型首 token 延迟，长推理可通过 env 调大；
- 120s idle 比当前 URLSession 默认 60s 更宽容，避免误杀慢速流；
- Binvia 是本地回环网关，不需要 OmniRoute 默认 600s 那么宽松。

## 8. 风险与注意事项

- 事件级重建必须保留原始事件文本，不能只保留 `data:` 值，否则会丢
  `event:`、注释、自定义字段；
- 合成 `finish_reason: stop` 只用于“正常结束但缺结束标记”；错误路径必须
  携带错误体和错误码，不能伪装成成功；
- early EOF 重试只在响应头发出前进行，收到首个有用事件后绝不重试；
- 空闲看门狗与 readiness 超时都要能取消底层上游任务，避免连接泄漏；
- 所有新行为必须用本地 mock 上游测试，不能依赖真实网络；
- 保持 StrictConcurrency：新增 normalizer/看门狗不要在 `@unchecked Sendable`
  之外共享可变状态。

## 9. 验证方式

自动化：

- `make test` 全量通过；
- 新增 `BinviaCheck` 套件覆盖：
  - 事件跨 chunk 切分与原文保留；
  - `[DONE]` 顺序与合成 finish_reason；
  - readiness 超时、idle 超时；
  - 非 2xx 状态保真；
  - early EOF 重试与禁止重试边界；
  - JSON body 转 SSE；
  - finish_reason 归一化。

手工：

- 8 并发健康流全部正常；
- 断流场景 0.5s 内结束并返回错误；
- 空流场景 readiness 超时内返回 504；
- `curl /v1/usage` 能看到 `errorCode`。

## 10. 后续 Responses / Anthropic 兼容需要修改的点

本计划完成时只服务 `/v1/chat/completions`。若后续新增 OpenAI Responses 与
Anthropic Messages 兼容，需要对本计划做以下修改（详细方案见
`docs/openai-responses-anthropic-compatibility-plan.md`）：

1. `SSEStreamNormalizer` 从 `StreamFormat.openaiChat` 单格式升级为多格式：
   结束标记、合成 terminal chunk、`[DONE]` 是否输出都改为按 format 分发；
2. `TokenUsageExtractor` / finish_reason 跟踪保留为通用事件级能力，但
   “finish_reason 字段位置”由 format 策略解析，避免写成 chat 专属；
3. `errorPayload` 改为按客户端格式输出：
   - OpenAI Chat：`{"error": ...}`；
   - Responses：`error` SSE frame + `response.failed`；
   - Anthropic：`event: error`；
4. `RouteHandler` 增加格式分发表：`/v1/chat/completions`、
   `/v1/responses`、`/v1/messages` 先统一翻译成内部 ChatRequest，
   响应再翻译回客户端格式；
5. Phase 2 的 readiness / idle 超时与错误码保持不变，错误元数据增加
   `client_format` 字段；
6. Phase 4 的 early EOF 重试规则不变，但“是否已产生输出”的判断按 format
   策略实现（Responses 首个 `response.output_text.delta`、Anthropic 首个
   `content_block_delta`）。

## 11. 结论与建议

建议按 Phase 1 → 2 → 3 → 4 实施，完成后即可覆盖用户遇到的两类问题：

- 并发下上游断流不再表现为无限挂起或 `Stream ended without finish_reason`；
- 上游限流/报错能被客户端正确识别和重试。

Phase 5 是否实施取决于自定义 provider 的实际使用频率；Phase 6 随发布流程走。
