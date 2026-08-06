use std::sync::Arc;
use std::time::Instant;

use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Json, Response};
use futures::StreamExt;
use serde::Deserialize;
use serde_json::Value;

use crate::gateway::dispatch::{build_chat_stream, now_timestamp, provider_error_status, resolve_for_model};
use crate::gateway::sse_aggregator::SseAggregator;
use crate::gateway::token_extractor::extract_from_json;
use crate::monitor::{RequestLogEntry, TokenUsage};
use crate::providers::{ChatRequest, Message};
use crate::server::state::AppState;

#[derive(Deserialize)]
pub struct TestModelRequest {
    pub model: String,
    pub message: Option<String>,
}

#[derive(serde::Serialize)]
pub struct TestModelResult {
    pub success: bool,
    pub message: String,
    #[serde(rename = "latencyMs")]
    pub latency_ms: Option<f64>,
}

/// `POST /admin/api/providers/{id}/test-model`：发送最小请求（max_tokens:1）探测模型可用性。
pub async fn test_model_handler(
    State(state): State<Arc<AppState>>,
    axum::extract::Path(provider_id): axum::extract::Path<String>,
    Json(body): Json<TestModelRequest>,
) -> impl IntoResponse {
    let started = Instant::now();
    let full_model = format!("{provider_id}/{}", body.model);
    let resolved = match resolve_for_model(&state, &full_model).await {
        Ok(r) => r,
        Err(message) => {
            return Json(TestModelResult {
                success: false,
                message,
                latency_ms: Some(started.elapsed().as_secs_f64() * 1000.0),
            })
        }
    };
    let request = ChatRequest {
        model: resolved.model_id.clone(),
        messages: vec![Message {
            role: "user".to_string(),
            content: Some(Value::String(body.message.unwrap_or_else(|| "ping".to_string()))),
            name: None,
        }],
        stream: Some(true),
        temperature: None,
        max_tokens: Some(1),
        top_p: None,
    };
    match build_chat_stream(&resolved.descriptor, &resolved.base_url, &resolved.credential, request).await {
        Ok(mut stream) => match stream.next().await {
            Some(Ok(_)) => {
                state.logger.append(RequestLogEntry::new(
                    "POST".to_string(),
                    "/admin/api/test-model".to_string(),
                    Some(resolved.provider_id.clone()),
                    Some(resolved.model_id.clone()),
                    200,
                    started.elapsed().as_secs_f64() * 1000.0,
                    None,
                    None,
                ));
                Json(TestModelResult {
                    success: true,
                    message: format!("模型 {} 可用", resolved.model_id),
                    latency_ms: Some(started.elapsed().as_secs_f64() * 1000.0),
                })
            }
            Some(Err(error)) => {
                state.logger.append(RequestLogEntry::new(
                    "POST".to_string(),
                    "/admin/api/test-model".to_string(),
                    Some(resolved.provider_id.clone()),
                    Some(resolved.model_id.clone()),
                    provider_error_status(&error).as_u16(),
                    started.elapsed().as_secs_f64() * 1000.0,
                    Some(error.to_string()),
                    None,
                ));
                Json(TestModelResult {
                    success: false,
                    message: format!("模型 {} 测试失败: {}", resolved.model_id, error),
                    latency_ms: Some(started.elapsed().as_secs_f64() * 1000.0),
                })
            }
            None => {
                state.logger.append(RequestLogEntry::new(
                    "POST".to_string(),
                    "/admin/api/test-model".to_string(),
                    Some(resolved.provider_id.clone()),
                    Some(resolved.model_id.clone()),
                    502,
                    started.elapsed().as_secs_f64() * 1000.0,
                    Some("模型返回空响应".to_string()),
                    None,
                ));
                Json(TestModelResult {
                    success: false,
                    message: format!("模型 {} 返回空响应", resolved.model_id),
                    latency_ms: Some(started.elapsed().as_secs_f64() * 1000.0),
                })
            }
        },
        Err(error) => {
            state.logger.append(RequestLogEntry::new(
                "POST".to_string(),
                "/admin/api/test-model".to_string(),
                Some(resolved.provider_id.clone()),
                Some(resolved.model_id.clone()),
                provider_error_status(&error).as_u16(),
                started.elapsed().as_secs_f64() * 1000.0,
                Some(error.to_string()),
                None,
            ));
            Json(TestModelResult {
                success: false,
                message: format!("模型 {} 测试失败: {}", resolved.model_id, error),
                latency_ms: Some(started.elapsed().as_secs_f64() * 1000.0),
            })
        }
    }
}

#[derive(Deserialize)]
pub struct PlaygroundRequest {
    pub model: String,
    pub message: String,
    pub stream: Option<bool>,
}

/// `POST /admin/api/playground`：管理员身份聊天（绕过 gateway key）。
/// `stream=true` 返回 SSE；`stream=false` 聚合返回 `{content, tokens, error}`。
pub async fn playground_handler(
    State(state): State<Arc<AppState>>,
    Json(body): Json<PlaygroundRequest>,
) -> Response {
    let started = Instant::now();
    let resolved = match resolve_for_model(&state, &body.model).await {
        Ok(r) => r,
        Err(message) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": message})),
            )
                .into_response();
        }
    };
    let request = ChatRequest {
        model: resolved.model_id.clone(),
        messages: vec![Message {
            role: "user".to_string(),
            content: Some(Value::String(body.message.clone())),
            name: None,
        }],
        stream: Some(true),
        temperature: None,
        max_tokens: None,
        top_p: None,
    };
    let stream = match build_chat_stream(
        &resolved.descriptor,
        &resolved.base_url,
        &resolved.credential,
        request,
    )
    .await
    {
        Ok(s) => s,
        Err(error) => {
            return (
                provider_error_status(&error),
                Json(serde_json::json!({"error": error.to_string()})),
            )
                .into_response();
        }
    };

    // 默认流式返回。
    if !body.stream.unwrap_or(true) {
        return aggregate_playground(state, started, resolved, stream).await;
    }

    let provider_id = resolved.provider_id.clone();
    let model_id = resolved.model_id.clone();
    let state_for_drop = Arc::clone(&state);
    let started_for_drop = started;
    let sse_body = futures::stream::unfold(
        PlaygroundStreamState {
            stream,
            done: false,
            logged: false,
        },
        move |mut st| {
            let state = Arc::clone(&state_for_drop);
            let provider_id = provider_id.clone();
            let model_id = model_id.clone();
            async move {
                if st.done {
                    return None;
                }
                match st.stream.next().await {
                    Some(Ok(chunk)) => {
                        let json = serde_json::to_string(&chunk).unwrap_or_else(|_| "{}".to_string());
                        Some((Ok::<Bytes, std::io::Error>(Bytes::from(format!("data: {json}\n\n"))), st))
                    }
                    Some(Err(error)) => {
                        st.done = true;
                        st.logged = true;
                        state.logger.append(RequestLogEntry::new(
                            "POST".to_string(),
                            "/admin/api/playground".to_string(),
                            Some(provider_id),
                            Some(model_id),
                            502,
                            started_for_drop.elapsed().as_secs_f64() * 1000.0,
                            Some(error.to_string()),
                            None,
                        ));
                        Some((
                            Ok::<Bytes, std::io::Error>(Bytes::from(format!(
                                "data: {}\n\ndata: [DONE]\n\n",
                                serde_json::json!({"error": error.to_string()})
                            ))),
                            st,
                        ))
                    }
                    None => {
                        st.done = true;
                        if !st.logged {
                            st.logged = true;
                            state.logger.append(RequestLogEntry::new(
                                "POST".to_string(),
                                "/admin/api/playground".to_string(),
                                Some(provider_id),
                                Some(model_id),
                                200,
                                started_for_drop.elapsed().as_secs_f64() * 1000.0,
                                None,
                                None,
                            ));
                        }
                        Some((Ok::<Bytes, std::io::Error>(Bytes::from("data: [DONE]\n\n")), st))
                    }
                }
            }
        },
    );
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from_stream(sse_body))
        .expect("valid SSE response")
}

struct PlaygroundStreamState {
    stream: crate::providers::ChatStream,
    done: bool,
    logged: bool,
}

async fn aggregate_playground(
    state: Arc<AppState>,
    started: Instant,
    resolved: crate::gateway::dispatch::ResolvedProvider,
    mut stream: crate::providers::ChatStream,
) -> Response {
    let provider_id = resolved.provider_id.clone();
    let model_id = resolved.model_id.clone();
    let mut aggregator = SseAggregator::new(model_id.clone());
    let mut error: Option<String> = None;
    while let Some(result) = stream.next().await {
        match result {
            Ok(chunk) => aggregator.push(&chunk),
            Err(err) => {
                error = Some(err.to_string());
                break;
            }
        }
    }
    if let Some(message) = error {
        state.logger.append(RequestLogEntry::new(
            "POST".to_string(),
            "/admin/api/playground".to_string(),
            Some(provider_id),
            Some(model_id),
            502,
            started.elapsed().as_secs_f64() * 1000.0,
            Some(message.clone()),
            None,
        ));
        return (
            StatusCode::BAD_GATEWAY,
            Json(serde_json::json!({"error": message})),
        )
            .into_response();
    }
    let response = aggregator.finish();
    let tokens: Option<TokenUsage> = response.usage.as_ref().and_then(extract_from_json);
    let content = response
        .choices
        .first()
        .and_then(|c| c.message.content.as_ref())
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    state.logger.append(RequestLogEntry::new(
        "POST".to_string(),
        "/admin/api/playground".to_string(),
        Some(provider_id),
        Some(model_id),
        200,
        started.elapsed().as_secs_f64() * 1000.0,
        None,
        tokens.clone(),
    ));
    Json(serde_json::json!({
        "content": content,
        "tokens": tokens,
        "created": now_timestamp(),
    }))
    .into_response()
}
