# OpenAI Responses / Anthropic Messages 兼容计划

> 制定日期：2026-08-11
> 前置依赖：`docs/streaming-alignment-omniroute-plan.md`（先完成该计划的
> Phase 1-4，再开始本计划）
> 参考：OmniRoute `src/app/api/v1/responses/route.ts`、
> `src/app/api/v1/messages/route.ts`、`open-sse/translator/`

## 1. 背景与目标

Binvia 当前只暴露 OpenAI Chat Completions（`/v1/chat/completions`）。目标是
在流式服务健壮化完成之后，新增两个入站格式：

1. `/v1/responses`：OpenAI Responses API，供 Codex CLI
   （`wire_api = "responses"`）、OpenAI Responses SDK 等客户端直接调用；
2. `/v1/messages`：Anthropic Messages API，供 Claude Code、Anthropic SDK
   等客户端直接调用。

上游保持不变：所有 provider 仍然走 OpenAI 兼容 `/chat/completions`，网关负责
请求翻译和响应翻译。

范围：

- 第一版支持文本、流式、工具调用（function calling）、usage；
- 多模态、web_search/file_search 等高级工具列为后续；
- `/v1/chat/completions` 行为不变，现有客户端不受影响。

## 2. 与流式健壮性计划的关系

两个计划不冲突，是分层关系：

| 层 | 计划 | 内容 |
|---|---|---|
| 服务健壮性 | `streaming-alignment-omniroute-plan.md` | 超时、错误传播、finish_reason、early EOF 重试、JSON 转 SSE |
| 格式兼容 | 本计划 | 入站格式识别、请求/响应翻译、Responses/Anthropic SSE 事件生成 |

本计划直接依赖流式计划的 Phase 1-4：

- `SSEStreamNormalizer` 提供事件级流处理；
- readiness / idle 超时与错误码复用；
- non-2xx 状态保真复用；
- early EOF 重试复用。

流式计划已预留的修改点见其第 10 节：normalizer 引入 `StreamFormat`，
结束标记与合成 terminal chunk 按 format 分发，`errorPayload` 按客户端格式输出。

## 3. 当前现状

| 项 | Binvia | OmniRoute |
|---|---|---|
| `/v1/chat/completions` | 有 | 有 |
| `/v1/responses` | 无 | 有，委托统一 `handleChat` |
| `/v1/messages` | 无 | 有，委托统一 `handleChat` |
| 格式识别 | 无（固定 chat） | `detectFormatFromEndpoint`：路径 + body 双识别 |
| 请求翻译 | 无 | `open-sse/translator/request/*` |
| 响应翻译 | 无 | `open-sse/translator/response/*` |
| 流式响应翻译 | 无 | `chatCore` 按 source/target format 组装 transform stream |

OmniRoute 关键参考：

- [responses/route.ts](/Users/wangbin/workspace/temp/my-token-route/OmniRoute/src/app/api/v1/responses/route.ts:80)；
- [messages/route.ts](/Users/wangbin/workspace/temp/my-token-route/OmniRoute/src/app/api/v1/messages/route.ts:49)；
- [provider.ts](/Users/wangbin/workspace/temp/my-token-route/OmniRoute/open-sse/services/provider.ts:88) 格式识别；
- [translator/request](/Users/wangbin/workspace/temp/my-token-route/OmniRoute/open-sse/translator/request) 与
  [translator/response](/Users/wangbin/workspace/temp/my-token-route/OmniRoute/open-sse/translator/response) 翻译器。

## 4. 目标架构

```
客户端（Codex / Anthropic SDK / OpenAI Responses SDK）
  → /v1/responses 或 /v1/messages
  → InboundFormatDetector       路径 + body 识别 sourceFormat
  → RequestTranslator           Responses/Claude → 内部 ChatRequest
  → Router + Provider          复用现有模型路由与上游调用
  → 上游 OpenAI Chat 流
  → SSEStreamNormalizer        复用流式计划（format 策略按 sourceFormat 分发）
  → ResponseTranslator          Chat SSE/JSON → Responses/Claude SSE/JSON
  → HTTPServer.writeResponse → 客户端
```

新增模块建议：

```
Sources/BinviaCore/Translation/
├── StreamFormat.swift            枚举：openaiChat / responses / anthropic
├── InboundFormatDetector.swift   路径 + body 识别
├── Responses/ResponsesRequestTranslator.swift
├── Responses/ResponsesResponseTranslator.swift
├── Anthropic/AnthropicRequestTranslator.swift
└── Anthropic/AnthropicResponseTranslator.swift
```

## 5. Responses API 转换规则

### 5.1 请求：Responses → Chat

| Responses 字段 | Chat 映射 |
|---|---|
| `input`（字符串） | `[{role:"user", content: input}]` |
| `input`（数组） | 逐项转换：`message` → 普通消息；`function_call_output` → `tool` 消息；`reasoning` 项第一版跳过 |
| `instructions` | 追加 `system` 消息 |
| `tools[].type == "function"` | Chat `function` tool（name/description/parameters） |
| `tools` 非 function 类型 | 第一版返回 400 明确不支持 |
| `stream` | 透传 |
| `max_output_tokens` | `max_tokens` |
| `reasoning` | 有上游支持时映射 `reasoning_effort`，否则剥离 |
| `previous_response_id` | 第一版用内存会话表还原历史消息；无法还原时 400 |
| `temperature` / `top_p` | 透传 |

### 5.2 非流式响应：Chat JSON → Response

```
{
  "id": "resp_xxx",
  "object": "response",
  "created_at": 1720000000,
  "status": "completed",
  "model": "...",
  "output": [
    {
      "type": "message",
      "id": "msg_xxx",
      "role": "assistant",
      "content": [
        {"type": "output_text", "text": "...", "annotations": []}
      ]
    },
    {
      "type": "function_call",
      "id": "fc_xxx",
      "call_id": "call_xxx",
      "name": "...",
      "arguments": "{}"
    }
  ],
  "usage": {...}
}
```

`status` 映射：`finish_reason=stop|tool_calls` → `completed`；
`length|content_filter` → `incomplete`。

### 5.3 流式响应：Chat SSE → Responses SSE

| Chat chunk | Responses SSE |
|---|---|
| `delta.content` | `response.output_text.delta` |
| `delta.reasoning_content` | `response.reasoning_summary_text.delta`（Codex 推理展示） |
| `delta.tool_calls` | `response.function_call_arguments.delta` |
| `finish_reason` | `response.completed` |
| 流开始 | `response.created` + `response.output_item.added` |
| 流结束 | `data: [DONE]` |

事件顺序要求：

```
response.created
response.output_item.added
response.output_text.delta  (可多次)
response.output_text.done
response.output_item.done
response.function_call_arguments.delta (工具调用时)
response.function_call_arguments.done
response.completed
data: [DONE]
```

第一版以 Codex CLI 兼容为主，事件字段参考 OmniRoute
`open-sse/utils/responsesStreamHelpers.ts`。

## 6. Anthropic Messages 转换规则

### 6.1 请求：Claude → Chat

| Anthropic 字段 | Chat 映射 |
|---|---|
| `system`（字符串或 blocks） | `system` 消息 |
| `messages[].role` | 映射 `assistant`/`user` |
| `messages[].content` blocks | text → 文本；`tool_result` → `tool` 消息；`tool_use` → assistant `tool_calls` |
| `max_tokens` | `max_tokens` |
| `tools[].input_schema` | Chat function tool 的 parameters |
| `stream` | 透传 |
| `thinking` | 有上游支持时映射 reasoning，否则剥离 |

### 6.2 响应：Chat SSE → Anthropic SSE

| Chat chunk | Anthropic SSE |
|---|---|
| `delta.content` | `content_block_delta`（`text_delta`） |
| `delta.reasoning_content` | `content_block_delta`（`thinking_delta`） |
| `delta.tool_calls` | `content_block_start`（`tool_use`）+ `input_json_delta` |
| `finish_reason` | `message_delta.stop_reason` |
| 流开始 | `message_start` + `content_block_start` |
| 流结束 | `message_stop` |

`stop_reason` 映射：

- `stop` / `tool_calls` → `end_turn`；
- `length` → `max_tokens`；
- `content_filter` → `refusal`；
- 其它保留原始值，不伪装。

## 7. 实施阶段

### 阶段 A：流式核心多格式化

前置：先完成 `streaming-alignment-omniroute-plan.md` 的 Phase 1-4。

内容：

- 引入 `StreamFormat` 枚举与 format 策略；
- `SSEStreamNormalizer` 支持按 format 识别结束标记、合成 terminal chunk、
  决定是否输出 `[DONE]`；
- `errorPayload` 按 `client_format` 输出对应错误帧；
- `TokenUsageExtractor` 保持通用，不绑定 chat 字段。

验收：

- `/v1/chat/completions` 行为与流式计划完成后一致；
- 新增 format 策略不影响既有测试；
- `make test` 全量通过。

### 阶段 B：`/v1/responses` 非流式

内容：

- `RouteHandler` 增加 `POST /v1/responses`；
- `ResponsesRequestTranslator` 把请求翻译成内部 `ChatRequest`；
- 上游非流式 JSON 响应翻译成 Response 对象；
- `previous_response_id` 先用内存会话表，后续再评估持久化。

验收：

- mock 上游返回 OpenAI chat JSON，`/v1/responses` 返回合法 Response JSON；
- 工具调用、usage 字段正确；
- 不支持的 tool 类型返回明确 400；
- `make test` 全量通过。

### 阶段 C：`/v1/responses` 流式（Codex 兼容）

内容：

- `ResponsesResponseTranslator` 实现 Chat SSE → Responses SSE；
- 覆盖文本、推理、工具调用、`[DONE]` 顺序；
- 接入 `SSEStreamNormalizer` 的 format 策略；
- 用 mock 上游模拟 Codex 常用请求。

验收：

- curl 流式响应事件顺序正确；
- 工具调用可被 Codex 识别并继续下一轮；
- 断流/超时/非 2xx 走流式计划的错误码；
- 真实 Codex CLI 配置：

```toml
[model_providers.binvia]
name = "Binvia"
base_url = "http://127.0.0.1:20427/v1"
env_key = "BINVIA_API_KEY"
wire_api = "responses"
```

### 阶段 D：`/v1/messages` Anthropic

内容：

- `RouteHandler` 增加 `POST /v1/messages`；
- `AnthropicRequestTranslator` / `AnthropicResponseTranslator`；
- 非流式 JSON 与流式 SSE 都支持；
- 工具调用、thinking 内容、usage 映射。

验收：

- mock 上游下 `/v1/messages` 非流式和流式响应合法；
- Claude Code 或 Anthropic SDK 能完成一轮对话；
- `make test` 全量通过。

### 阶段 E：回归与发布

内容：

- 三个端点共享的路由、认证、白名单、用量日志回归；
- README / `docs/build-release-guide.md` 更新；
- 发布前完整验证。

验收：

- `make test` 全量通过；
- `swift run BinviaApp --smoke-test` 通过；
- `make release` 产物自检通过；
- Codex CLI 与 Claude Code 各完成一次真实对话。

## 8. 配置与开关

建议新增环境变量（默认开启，便于灰度关闭）：

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `BINVIA_ENABLE_RESPONSES` | `1` | 关闭后 `/v1/responses` 返回 404 |
| `BINVIA_ENABLE_MESSAGES` | `1` | 关闭后 `/v1/messages` 返回 404 |

`previous_response_id` 会话表建议加上限（如 200 条 / 24h），防止内存无界增长。

## 9. 风险与注意事项

- Responses 与 Anthropic 的 SSE 事件顺序是强契约，Codex/Claude Code 对事件
  顺序敏感，必须先做事件序 mock 测试再接真实客户端；
- 工具调用是最大复杂度：chat 的 `tool_calls` 增量要正确映射成
  `function_call_arguments` / `tool_use`，且 id/index 不能错位；
- 推理内容不能丢：上游 `reasoning_content` 要映射到
  `response.reasoning_summary_text.*` / `thinking_delta`；
- `previous_response_id` 需要跨请求状态，先做内存版，重启即失效；
- 不要伪造结束原因：`content_filter` 等要映射成 `incomplete`/`refusal`，
  不能改成 `completed`；
- 多模态、web_search、file_search 第一版明确 400，避免半支持状态；
- 所有新翻译器保持纯函数，方便单测；不要在翻译层引入共享可变状态。

## 10. 验证方式

自动化：

- 请求翻译 fixtures：Responses/Anthropic JSON → ChatRequest；
- 响应翻译 fixtures：Chat JSON/SSE → Responses/Anthropic JSON/SSE；
- SSE 事件顺序断言；
- 工具调用、推理、usage、错误帧；
- `make test` 全量通过。

手工：

- curl `/v1/responses` 非流式与流式；
- curl `/v1/messages` 非流式与流式；
- Codex CLI `wire_api = "responses"` 一轮真实对话；
- Claude Code 一轮真实对话；
- `/v1/chat/completions` 回归不变。

## 11. 结论

建议顺序：

1. 先完成流式健壮性计划；
2. 再按本计划阶段 A → C → D 实施，`/v1/responses`（Codex）优先；
3. `/v1/messages`（Anthropic）随后；
4. 每个阶段都跑 mock 集成与真实客户端验证后再进下一阶段。
