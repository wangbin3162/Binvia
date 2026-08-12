# OpenAI Responses / Anthropic Messages 兼容计划

> 制定日期：2026-08-11
> 前置依赖：`docs/streaming-alignment-omniroute-plan.md`（先完成该计划的
> Phase 1-4，再开始本计划）
> 实施状态：阶段 A/B/C/D 已完成（Responses 非流式 + 流式、Anthropic 非流式 + 流式、
> `BINVIA_ENABLE_RESPONSES` / `BINVIA_ENABLE_MESSAGES` 开关、单元/集成测试）；
> 真实 Codex CLI（`wire_api = "responses"`）一轮对话已通过；真实 Claude Code 一轮对话
> 待本机安装 Claude CLI 后收尾。工具兼容：原生 function / namespace 拍平转发，
> web_search 等高级工具第一版跳过，未知工具类型仍返回 400。
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
| `previous_response_id` | 用持久化会话表还原历史消息；无法还原时 400 |
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
| `BINVIA_SERVER_TOOLS` | `0` | 开启后 `web_search` / `file_search` 原样透传上游 |
| `BINVIA_STREAM_HEARTBEAT_THRESHOLD_MS` | `2000` | 流式首字节心跳阈值（毫秒） |
| `BINVIA_STREAM_HEARTBEAT_INTERVAL_MS` | `2000` | 流式心跳帧间隔（毫秒） |

`previous_response_id` 会话表持久化到 `~/.config/binvia/responses-sessions.json`
（`BINVIA_CONFIG` 已设置时同目录），上限 200 条 / TTL 24h。

## 9. 风险与注意事项

- Responses 与 Anthropic 的 SSE 事件顺序是强契约，Codex/Claude Code 对事件
  顺序敏感，必须先做事件序 mock 测试再接真实客户端；
- 工具调用是最大复杂度：chat 的 `tool_calls` 增量要正确映射成
  `function_call_arguments` / `tool_use`，且 id/index 不能错位；
- 推理内容不能丢：上游 `reasoning_content` 要映射到
  `response.reasoning_summary_text.*` / `thinking_delta`；
- `previous_response_id` 需要跨请求状态，已做持久化版（JSON 原子写 + 0600），重启仍可续接；
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

## 12. 后续实现计划（v1.1：高级工具 / 多模态 / 会话 / 协议打磨）

> 实施状态（2026-08-11）：阶段 F-H（工具闭环、多模态、会话持久化）与阶段 I/J
> （Anthropic 协议完善、错误帧 / CORS / 心跳）已实现，`make test` 全量回归通过
> （770 项断言）。真实 Codex 多轮工具调用与 Claude Code 真实验证待客户端环境
> 具备后收尾。后续计划按 P0 → P2 排列。

### 阶段 F：工具调用闭环（P0，Codex 优先）✅ 已实现

目标：让 Codex CLI 的多轮工具调用（MCP namespace、apply_patch 等）完整可用，
并让 `web_search` / `file_search` 具备明确的能力开关，而不是一律跳过。

#### F1 请求侧工具收集对齐 OmniRoute ✅ 已实现

现状：

- `ResponsesRequestTranslator` 只读取顶层 `tools`，忽略 input items 里的
  `{type:"additional_tools", tools:[...]}`；
- namespace 拍平直接拼 `"\(namespace).\(name)"`，与 OmniRoute 的
  `"\(namespace)__\(leaf)"` + 64 字符 hash 截断规则不一致，跨 namespace 同名
  子工具可能仍冲突。

改造：

- 新增 `ResponsesToolCollector`（纯函数）：合并顶层 `tools` 与 input items 中
  的 `additional_tools`，显式顶层声明优先，同名 namespace 合并；
- 引入 `flattenNamespaceToolName`：`ns` 缺失保留 leaf；leaf 已含 `__` 不重复
  加前缀；超过 64 字符用确定性 hash 截断（参考 OmniRoute
  `namespaceFlatten.ts`）；
- `ResponsesRequestTranslator.translate` 改为消费收集结果，保留 Chat 兼容
  与 Responses 原生两种工具形态（第一版已支持）。

参考：OmniRoute
`open-sse/translator/request/openai-responses/additionalTools.ts`、
`namespaceFlatten.ts`。

验收：

- fixtures 覆盖 `additional_tools`、同名 namespace 合并、64 字符截断；
- `make test` 全量通过。

#### F2 namespace 工具身份回传 ✅ 已实现

现状：拍平后丢失 `{namespace, name}`，Responses 响应里的 `function_call` 只有
拍平后的 name，Codex 对 MCP namespace 子工具的 dispatch 可能出错。

改造：

- 新增请求级 `ResponsesToolIdentityMap`（`wireName -> {namespace, name}`），
  由 `ResponsesRequestTranslator` 返回给 `RouteHandler`；
- `ResponsesResponseTranslator` / `ResponsesStreamTranslator` 接收该 map，
  输出 `function_call` item 时把 `name` 还原为 leaf，并补充 `namespace` 字段；
- map 只随单次请求传递，不进入 ChatRequest 编解码，避免污染 rawBody。

参考：OmniRoute
`open-sse/translator/response/openai-responses/requestToolIdentity.ts`、
`responsesToolItem.ts`、`openai-responses.ts` 的 `closeToolCall`。

验收：

- mock 上游返回 `mcp__fs.read`，客户端收到
  `{type:"function_call", name:"read", namespace:"mcp__fs"}`；
- 真实 Codex CLI 完成至少一轮「模型调用 MCP/apply_patch 工具 → 提交
  function_call_output → 继续回答」的多轮对话。

#### F3 工具参数增量去重 ✅ 已实现

现状：`ResponsesStreamTranslator` / `AnthropicStreamTranslator` 直接
`buffer += arguments`；上游若重复发送完整快照（常见于部分兼容实现），
参数会重复拼接。

改造：

- 新增共享 `appendToolCallArgumentDelta(existing:incoming:)`：
  - incoming 与 existing 相同 → 保持原值；
  - incoming 以 existing 开头（完整快照增长）→ 整体替换；
  - 其余视为增量碎片 → 原样追加；
  - incoming 为对象/数组 → `JSON.stringify` 后进入同一逻辑；
  - 禁止模糊前后缀裁剪，避免把合法增量 `ll` 截成 `l`。
- 两个流式 translator 统一改用该函数。

参考：OmniRoute `open-sse/utils/toolCallArguments.ts`。

验收：mock 分别发送增量碎片与完整快照，客户端拼出的 `arguments` 不重复、
不截断。

#### F4 web_search / file_search 高级工具 ✅ 已实现

现状：第一版跳过，Codex 能对话但无法使用搜索/文件检索。

改造（不做猜测性降级）：

- 新增 provider 级能力开关：`BINVIA_SERVER_TOOLS`（默认 `0`，保持第一版
  跳过行为）；
- 开关开启后，`web_search` / `file_search` 保留原始工具定义透传到 Chat
  请求体（上游 OpenAI 兼容端点若支持则直接可用）；
- 上游返回 400 时**不自动降级重试**，原样透传错误并记录工具类型，
  符合「禁止兜底、猜测性修补」原则；
- 入站仍允许 Anthropic versioned web search 形态
  （`web_search_20250305` 等）识别为同一类。

参考：OmniRoute `openai-responses.ts` 的 `WEB_SEARCH_TOOL_TYPES` /
`TOOL_SEARCH_TOOL_TYPES`、`claude-to-openai.ts` 的
`convertClaudeServerWebSearchTool`。

验收：开关开启时 mock 上游收到 web_search 工具；关闭时跳过；未知工具类型
仍 400。

### 阶段 G：多模态（P1）✅ 已实现

目标：Responses `input_image` / `input_file` 与 Anthropic `image` 块能双向
翻译，不再只保留文本。

#### G1 Responses 入站 ✅ 已实现

- `input_image` → Chat `image_url` part（`image_url` 支持字符串或对象形态）；
- `input_file` → Chat file part（`file_data` / `file_id` / `file_url` /
  `filename` 映射，参考 OmniRoute 的 `file` / `document` 分支）；
- `ChatContentPart` 增加 file 相关可选字段，并保持宽容解码。

参考：OmniRoute `openai-responses.ts` 的 `input_image` / `input_file` 转换。

#### G2 Anthropic 入站 ✅ 已实现

- `image` 块（`source.type == base64|url`）→ `image_url` part；
- `tool_result` 内容里的 image 提升为后续 user 消息（OpenAI `tool` 消息不能
  带图片），文本部分留在 tool 消息。

参考：OmniRoute `claude-to-openai.ts` 的 `image` / `tool_result` 分支。

#### G3 出站 ✅ 已实现

- Chat `image_url` → Responses `output_image` / Anthropic `image` block；
- 非流式与流式两个响应翻译器都输出图片 content block；
- 多模态 content 数组在 `chatMessageJSON` 中保留 parts，不再退化成
  `textValue` 拼接。

验收：

- fixtures 双向翻译 base64 / URL 图片与 file part；
- `make test` 全量通过；
- 真实客户端发图（可选，视环境）。

风险：base64 图片可能显著放大请求/日志体积，翻译层需对 `rawBody` 与日志
大小做上限保护。

### 阶段 H：previous_response_id 会话持久化（P1）✅ 已实现

现状：`ResponsesSessionStore` 为内存版（重启失效、上限 200），未知 id 返回
200 空历史，未按计划文档「无法还原时 400」处理。

改造：

- 持久化到 `~/.config/binvia/responses-sessions.json`（原子写、0600 权限），
  或复用仓库已有 SQLite3 依赖建表；
- 条目含 `responseID -> {messages, createdAt}`，TTL 24h，启动与写入时清理，
  上限 200 条；
- 未知 / 过期 `previous_response_id` 返回 400
  `{"error":"unknown previous_response_id"}`；
- 流式与非流式完成路径统一写入（现有逻辑迁移到持久化 store）；
- `ResponsesSessionStore` 抽成协议 + 文件实现，RouteHandler 通过注入使用，
  便于测试替换。

参考：OmniRoute `open-sse/utils/responsesStatePolicy.ts` 的
preserve / strip / auto 模式语义（我们保留本地还原语义，不依赖上游 state）。

验收：

- 重启进程后仍可用 previous_response_id 续接；
- 未知 id 返回 400；
- TTL 过期与 200 条上限测试通过。

### 阶段 I：Anthropic 协议完善（P2）✅ 已实现

现状：第一版已覆盖文本、thinking、tool_use / tool_result、usage；以下字段
仍缺失。

改造：

- 请求：`stop_sequences` → Chat `stop`；`tool_choice`（auto / any / tool）
  转 Chat `tool_choice`（ChatRequest 增加可选字段或放入 rawBody）；
- 请求：`cache_control` 在 provider 支持时保留（参考 OmniRoute
  `_preserveCacheControl`），默认剥离；
- 请求：`redacted_thinking` 保留占位，不丢弃；
- 响应：`message_delta.usage` 细分（`cache_read_input_tokens` 已有基础，
  补 `cache_creation_input_tokens`）；
- 流式：tool_use 的 id 与 name 分 chunk 到达时，延迟
  `content_block_start` 直到 name 可用（第一版已部分实现，补充边界测试）。

参考：OmniRoute `claude-to-openai.ts`、`openai-to-claude.ts`。

验收：fixtures 覆盖 stop_sequences / tool_choice / cache_control /
redacted_thinking；`make test` 全量通过；Claude Code 真实验证（可选，环境
具备时补充）。

### 阶段 J：协议打磨与发布收尾（P2）✅ 已实现（真实客户端验证待环境）

目标：把 Responses / Anthropic 的错误帧、心跳、CORS 与发布流程对齐到
OmniRoute 的成熟度。

改造：

- 错误帧：流式错误统一输出 `event: response.failed` / `event: error`，非流式
  错误 JSON 结构与 OpenAI / Anthropic 官方 error 对象对齐；
- 心跳：参考 OmniRoute `earlyStreamKeepalive.ts`，在首个有用字节前的等待期
  给 Codex 客户端发 `response.in_progress` 心跳（阈值按模型可配），避免
  Codex 5s 首字节看门狗断连；
- CORS / OPTIONS：按 OmniRoute `responses/route.ts`、`messages/route.ts`
  补 `Access-Control-Allow-*`；
- 回归：`/v1/chat/completions` 行为不变；
- 发布：`make release` 产物自检 + `BinviaApp --smoke-test` + 真实 Codex
  工具调用循环回归。

### 里程碑与优先级

| 优先级 | 阶段 | 内容 | 状态 | 客户端验收 |
|---|---|---|---|---|
| P0 | F | 工具收集、namespace 身份回传、参数去重 | 已实现 | 真实 Codex 工具调用多轮（待客户端环境） |
| P1 | G | 多模态双向翻译 | 已实现 | 真实客户端发图（可选） |
| P1 | H | previous_response_id 持久化 | 已实现 | 重启续接 + 400 语义（mock 已覆盖） |
| P2 | I | Anthropic 字段完善 | 已实现 | Claude Code（可选） |
| P2 | J | 错误帧 / 心跳 / CORS / 发布 | 已实现 | `make release` 回归 |

### 风险与约束

- F2 修改 namespace wire name 规则会改变现有 Codex 行为，必须先回归真实
  Codex 一轮对话，再进多轮工具测试；
- 高级工具透传依赖上游能力，禁止自动降级掩盖上游 400；
- 多模态 base64 体积大，翻译层需要体积上限保护；
- 会话持久化引入文件 I/O，需保证 RouteHandler 热更新与并发写不受影响；
- 所有新翻译器继续保持纯函数 / 无共享可变状态，便于单测。
