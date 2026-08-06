use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use futures::{StreamExt, Stream, stream};
use reqwest::StatusCode;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::config::ProviderCredential;
use crate::providers::{ChatChunk, ChatRequest, ChunkChoice, Delta, ProviderError};

/// Anthropic `max_tokens` 默认值（上游必填）。
pub const DEFAULT_MAX_TOKENS: u32 = 4096;
/// Anthropic 版本头值。
pub const ANTHROPIC_VERSION: &str = "2023-06-01";

/// OpenAI `ChatRequest` → Anthropic `/v1/messages` 请求体。
pub fn make_anthropic_request(
    model: &str,
    messages: &[crate::providers::Message],
    system: Option<&str>,
    max_tokens: Option<u32>,
    stream: bool,
    temperature: Option<f64>,
    top_p: Option<f64>,
) -> Value {
    let mut body = json!({
        "model": model,
        "max_tokens": max_tokens.unwrap_or(DEFAULT_MAX_TOKENS),
        "stream": stream,
    });
    if let Some(system) = system {
        if !system.is_empty() {
            body["system"] = Value::String(system.to_string());
        }
    }
    let mut anthropic_messages = Vec::new();
    for message in messages {
        if message.role == "system" || message.role == "developer" {
            continue;
        }
        let role = if message.role == "assistant" {
            "assistant"
        } else {
            "user"
        };
        let content = message
            .content
            .as_ref()
            .map(extract_text)
            .unwrap_or_default();
        anthropic_messages.push(json!({"role": role, "content": content}));
    }
    if anthropic_messages.is_empty() {
        anthropic_messages.push(json!({"role": "user", "content": ""}));
    }
    body["messages"] = Value::Array(anthropic_messages);
    if let Some(temp) = temperature {
        body["temperature"] = json!(temp);
    }
    if let Some(top) = top_p {
        body["top_p"] = json!(top);
    }
    body
}

fn extract_text(content: &Value) -> String {
    if let Some(s) = content.as_str() {
        return s.to_string();
    }
    if let Some(arr) = content.as_array() {
        return arr
            .iter()
            .filter_map(|part| {
                part.get("text")
                    .and_then(Value::as_str)
                    .or_else(|| part.as_str().map(|s| s))
                    .map(str::to_string)
            })
            .collect::<Vec<_>>()
            .join("");
    }
    String::new()
}

/// 把一条 Anthropic SSE payload 翻译为 OpenAI `chat.completion.chunk` JSON。
/// 返回 `None` 表示可忽略的事件。
pub fn translate_sse_payload(
    payload: &Value,
    model: &str,
    id: &str,
    created: u64,
    has_emitted_role: &mut bool,
    last_stop_reason: &mut Option<String>,
) -> Option<Value> {
    let event_type = payload.get("type").and_then(Value::as_str)?;
    match event_type {
        "message_start" | "content_block_start" | "message_stop" => None,
        "content_block_delta" => {
            let delta = payload.get("delta")?;
            if delta.get("type").and_then(Value::as_str) != Some("text_delta") {
                return None;
            }
            let text = delta.get("text").and_then(Value::as_str)?;
            let mut chunk_delta = serde_json::Map::new();
            if !*has_emitted_role {
                chunk_delta.insert("role".to_string(), Value::String("assistant".to_string()));
                *has_emitted_role = true;
            }
            if !text.is_empty() {
                chunk_delta.insert("content".to_string(), Value::String(text.to_string()));
            }
            if chunk_delta.is_empty() {
                return None;
            }
            Some(make_chunk(model, id, created, Value::Object(chunk_delta), None))
        }
        "message_delta" => {
            let delta = payload.get("delta")?;
            let reason = map_stop_reason(delta.get("stop_reason").and_then(Value::as_str));
            *last_stop_reason = Some(reason.to_string());
            Some(make_chunk(model, id, created, json!({}), Some(reason)))
        }
        _ => None,
    }
}

fn make_chunk(model: &str, id: &str, created: u64, delta: Value, finish_reason: Option<&str>) -> Value {
    json!({
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{
            "index": 0,
            "delta": delta,
            "finish_reason": finish_reason,
        }]
    })
}

fn map_stop_reason(raw: Option<&str>) -> &'static str {
    match raw {
        Some("max_tokens") => "length",
        _ => "stop",
    }
}

/// 构造上游 Anthropic 请求（POST `{base}?beta=true`，x-api-key + anthropic-version）。
pub fn build_upstream_request(
    base_url: &str,
    request: &ChatRequest,
    credential: &ProviderCredential,
) -> Result<reqwest::RequestBuilder, ProviderError> {
    let key = credential
        .api_key
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or(ProviderError::MissingCredentials)?;
    let system: String = request
        .messages
        .iter()
        .filter(|m| m.role == "system" || m.role == "developer")
        .filter_map(|m| m.content.as_ref().map(|c| extract_text(c)))
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n");
    let body = make_anthropic_request(
        &request.model,
        &request.messages,
        if system.is_empty() { None } else { Some(&system) },
        request.max_tokens,
        true,
        request.temperature,
        request.top_p,
    );
    let url = format!(
        "{}?beta=true",
        base_url.trim_end_matches('/')
    );
    let client = crate::networking::HttpClient::shared();
    Ok(client
        .inner()
        .post(&url)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json")
        .header("x-api-key", key)
        .header("anthropic-version", ANTHROPIC_VERSION)
        .json(&body))
}

/// 流式：上游 Anthropic SSE → 翻译为 OpenAI `ChatChunk` 流（末尾 [DONE]）。
pub fn translate_stream(
    upstream: impl Stream<Item = Result<Bytes, reqwest::Error>> + Send + 'static,
    model: String,
) -> crate::providers::ChatStream {
    let created = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    let upstream_id = format!("chatcmpl-{}", Uuid::new_v4());

    let stream = stream::unfold(
        TranslateState {
            upstream: Box::pin(upstream),
            buffer: Vec::new(),
            eof: false,
            model,
            created,
            id: upstream_id,
            has_emitted_role: false,
            last_stop_reason: None,
            done: false,
        },
        |mut state| async move {
            if state.done {
                return None;
            }
            loop {
                if let Some(event) = take_sse_event(&mut state.buffer) {
                    let text = String::from_utf8_lossy(&event);
                    let data: String = text
                        .lines()
                        .filter_map(|line| line.strip_prefix("data:"))
                        .map(|s| s.trim_start())
                        .collect::<Vec<_>>()
                        .join("\n");
                    if data.is_empty() {
                        continue;
                    }
                    if data == "[DONE]" {
                        state.done = true;
                        return None;
                    }
                    let Ok(json): Result<Value, _> = serde_json::from_str(&data) else {
                        continue;
                    };
                    // 捕获上游 message id。
                    if json.get("type").and_then(Value::as_str) == Some("message_start") {
                        if let Some(mid) = json
                            .get("message")
                            .and_then(|m| m.get("id"))
                            .and_then(Value::as_str)
                        {
                            state.id = mid.to_string();
                        }
                        continue;
                    }
                    if let Some(chunk) = translate_sse_payload(
                        &json,
                        &state.model,
                        &state.id,
                        state.created,
                        &mut state.has_emitted_role,
                        &mut state.last_stop_reason,
                    ) {
                        let choice = chunk.get("choices").and_then(|c| c.get(0));
                        let delta_value = choice
                            .and_then(|c| c.get("delta"))
                            .cloned()
                            .unwrap_or_default();
                        let finish_reason = choice
                            .and_then(|c| c.get("finish_reason"))
                            .and_then(Value::as_str)
                            .map(str::to_string);
                        let chat_chunk = ChatChunk {
                            id: state.id.clone(),
                            object: "chat.completion.chunk".to_string(),
                            created: state.created,
                            model: state.model.clone(),
                            choices: vec![ChunkChoice {
                                index: 0,
                                delta: serde_json::from_value(delta_value).unwrap_or(Delta {
                                    role: None,
                                    content: None,
                                }),
                                finish_reason,
                            }],
                            usage: None,
                        };
                        return Some((Ok(chat_chunk), state));
                    }
                    continue;
                }
                if state.eof {
                    state.done = true;
                    return None;
                }
                match state.upstream.next().await {
                    Some(Ok(bytes)) => state.buffer.extend_from_slice(&bytes),
                    Some(Err(error)) => {
                        return Some((Err(ProviderError::Http(error)), state));
                    }
                    None => {
                        state.eof = true;
                        if !state.buffer.is_empty() {
                            state.buffer.extend_from_slice(b"\n\n");
                        } else {
                            return None;
                        }
                    }
                }
            }
        },
    );
    Box::pin(stream)
}

struct TranslateState {
    upstream: std::pin::Pin<Box<dyn Stream<Item = Result<Bytes, reqwest::Error>> + Send>>,
    buffer: Vec<u8>,
    eof: bool,
    model: String,
    created: u64,
    id: String,
    has_emitted_role: bool,
    last_stop_reason: Option<String>,
    done: bool,
}

fn take_sse_event(buffer: &mut Vec<u8>) -> Option<Vec<u8>> {
    let lf = buffer.windows(2).position(|w| w == b"\n\n");
    let crlf = buffer.windows(4).position(|w| w == b"\r\n\r\n");
    let (pos, len) = match (lf, crlf) {
        (Some(l), Some(c)) if c < l => (c, 4),
        (Some(l), _) => (l, 2),
        (None, Some(c)) => (c, 4),
        (None, None) => return None,
    };
    let event = buffer[..pos].to_vec();
    buffer.drain(..pos + len);
    Some(event)
}

/// 非 2xx 响应体 → `ProviderError`。
pub fn upstream_error(status: StatusCode, body: String) -> ProviderError {
    ProviderError::HttpStatus { status, body }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::Message;

    #[test]
    fn make_anthropic_request_lifts_system_to_top_level() {
        let messages = vec![
            Message {
                role: "system".to_string(),
                content: Some(Value::String("you are helpful".to_string())),
                name: None,
            },
            Message {
                role: "user".to_string(),
                content: Some(Value::String("hi".to_string())),
                name: None,
            },
        ];
        let body = make_anthropic_request("glm-5.2", &messages, Some("you are helpful"), None, true, None, None);
        assert_eq!(body["system"], "you are helpful");
        assert_eq!(body["max_tokens"], DEFAULT_MAX_TOKENS);
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"], "hi");
        assert_eq!(body["stream"], true);
    }

    #[test]
    fn translate_text_delta_emits_role_once() {
        let payload = json!({
            "type": "content_block_delta",
            "delta": {"type": "text_delta", "text": "hello"}
        });
        let mut role = false;
        let mut stop = None;
        let chunk = translate_sse_payload(&payload, "m", "id", 1, &mut role, &mut stop).unwrap();
        assert_eq!(chunk["choices"][0]["delta"]["role"], "assistant");
        assert_eq!(chunk["choices"][0]["delta"]["content"], "hello");

        let payload2 = json!({
            "type": "content_block_delta",
            "delta": {"type": "text_delta", "text": " world"}
        });
        let chunk2 = translate_sse_payload(&payload2, "m", "id", 1, &mut role, &mut stop).unwrap();
        assert!(chunk2["choices"][0]["delta"].get("role").is_none());
        assert_eq!(chunk2["choices"][0]["delta"]["content"], " world");
    }

    #[test]
    fn translate_message_delta_maps_stop_reason() {
        let payload = json!({
            "type": "message_delta",
            "delta": {"stop_reason": "max_tokens"}
        });
        let mut role = true;
        let mut stop = None;
        let chunk = translate_sse_payload(&payload, "m", "id", 1, &mut role, &mut stop).unwrap();
        assert_eq!(chunk["choices"][0]["finish_reason"], "length");
        assert_eq!(stop, Some("length".to_string()));
    }

    #[test]
    fn translate_ignores_metadata_events() {
        let mut role = false;
        let mut stop = None;
        for ty in ["message_start", "content_block_start", "message_stop", "ping"] {
            let payload = json!({"type": ty});
            assert!(translate_sse_payload(&payload, "m", "id", 1, &mut role, &mut stop).is_none());
        }
    }
}
