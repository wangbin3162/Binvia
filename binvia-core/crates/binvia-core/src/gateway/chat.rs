use std::sync::Arc;
use std::time::Instant;

use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use futures::{StreamExt, stream};
use serde_json::Value;

use crate::auth;
use crate::gateway::anthropic;
use crate::gateway::sse_aggregator::SseAggregator;
use crate::gateway::token_extractor::extract_from_json;
use crate::monitor::{RequestLogEntry, TokenUsage};
use crate::providers::{
    ChatRequest, ChatStream, OpenAICompatibleProvider, Provider, ProviderError,
};
use crate::router::normalize_model_name;
use crate::server::state::AppState;

fn authorization_token(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::to_string)
        .or_else(|| {
            headers
                .get("X-API-Key")
                .and_then(|value| value.to_str().ok())
                .map(str::to_string)
        })
}

fn request_model(body: &[u8]) -> Option<String> {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .get("model")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
}

fn record_request(
    state: &AppState,
    started: Instant,
    provider_id: Option<String>,
    model: Option<String>,
    status: StatusCode,
    error: Option<String>,
    tokens: Option<TokenUsage>,
) {
    state.logger.append(RequestLogEntry::new(
        "POST".to_string(),
        "/v1/chat/completions".to_string(),
        provider_id,
        model,
        status.as_u16(),
        started.elapsed().as_secs_f64() * 1000.0,
        error,
        tokens,
    ));
}

fn failure_response(
    state: &AppState,
    started: Instant,
    provider_id: Option<String>,
    model: Option<String>,
    status: StatusCode,
    message: impl Into<String>,
) -> Response {
    let message = message.into();
    record_request(
        state,
        started,
        provider_id,
        model,
        status,
        Some(message.clone()),
        None,
    );
    (
        status,
        axum::Json(serde_json::json!({
            "error": {
                "message": message,
                "type": "invalid_request_error"
            }
        })),
    )
        .into_response()
}

fn provider_error_status(error: &ProviderError) -> StatusCode {
    match error {
        ProviderError::MissingCredentials => StatusCode::SERVICE_UNAVAILABLE,
        ProviderError::HttpStatus { status, .. } if status.as_u16() == 429 => {
            StatusCode::TOO_MANY_REQUESTS
        }
        _ => StatusCode::BAD_GATEWAY,
    }
}

fn provider_error_response(
    state: &AppState,
    started: Instant,
    provider_id: String,
    model: String,
    error: ProviderError,
) -> Response {
    failure_response(
        state,
        started,
        Some(provider_id),
        Some(model),
        provider_error_status(&error),
        error.to_string(),
    )
}

struct StreamState {
    stream: ChatStream,
    state: Arc<AppState>,
    started: Instant,
    provider_id: String,
    model: String,
    usage: Option<TokenUsage>,
    done: bool,
    logged: bool,
}

impl StreamState {
    fn log_once(&mut self, status: StatusCode, error: Option<String>) {
        if self.logged {
            return;
        }
        self.logged = true;
        record_request(
            &self.state,
            self.started,
            Some(self.provider_id.clone()),
            Some(self.model.clone()),
            status,
            error,
            self.usage.take(),
        );
    }
}

impl Drop for StreamState {
    fn drop(&mut self) {
        if !self.logged {
            self.log_once(
                StatusCode::BAD_GATEWAY,
                Some("stream closed before completion".to_string()),
            );
        }
    }
}

fn streaming_response(
    state: Arc<AppState>,
    started: Instant,
    provider_id: String,
    model: String,
    upstream: ChatStream,
) -> Response {
    let body_stream = stream::unfold(
        StreamState {
            stream: upstream,
            state,
            started,
            provider_id,
            model,
            usage: None,
            done: false,
            logged: false,
        },
        |mut state| async move {
            if state.done {
                return None;
            }

            match state.stream.next().await {
                Some(Ok(chunk)) => {
                    if let Some(usage) = chunk.usage.as_ref().and_then(extract_from_json) {
                        state.usage = Some(usage);
                    }

                    match serde_json::to_string(&chunk) {
                        Ok(json) => Some((Ok(Bytes::from(format!("data: {json}\n\n"))), state)),
                        Err(error) => {
                            let message = error.to_string();
                            state.done = true;
                            state.log_once(StatusCode::BAD_GATEWAY, Some(message.clone()));
                            Some((Err(std::io::Error::other(message)), state))
                        }
                    }
                }
                Some(Err(error)) => {
                    let status = provider_error_status(&error);
                    let message = error.to_string();
                    state.done = true;
                    state.log_once(status, Some(message.clone()));
                    Some((Err(std::io::Error::other(message)), state))
                }
                None => {
                    state.done = true;
                    state.log_once(StatusCode::OK, None);
                    Some((Ok(Bytes::from("data: [DONE]\n\n")), state))
                }
            }
        },
    );

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from_stream(body_stream))
        .expect("valid SSE response")
}

pub async fn chat_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let started = Instant::now();
    let log_model = request_model(&body);
    let mut request: ChatRequest = match serde_json::from_slice(&body) {
        Ok(request) => request,
        Err(error) => {
            return failure_response(
                &state,
                started,
                None,
                log_model,
                StatusCode::BAD_REQUEST,
                format!("invalid chat completion request: {error}"),
            );
        }
    };
    request.model = normalize_model_name(&request.model);

    let token = authorization_token(&headers);
    let (authentication_required, valid_token, enabled_models) = {
        let config = state.config.read().await;
        let valid_token = token
            .as_deref()
            .is_some_and(|value| auth::is_valid_api_key(value, &config));
        let enabled_models = token.as_deref().and_then(|value| {
            config
                .api_keys
                .iter()
                .find(|key| key.key == value)
                .and_then(|key| key.enabled_models.clone())
        });
        (
            !config.api_keys.is_empty() || auth::has_env_api_keys(),
            valid_token,
            enabled_models,
        )
    };

    if authentication_required && !valid_token {
        return failure_response(
            &state,
            started,
            None,
            Some(request.model),
            StatusCode::UNAUTHORIZED,
            "Invalid API key",
        );
    }

    if enabled_models.as_ref().is_some_and(|models| {
        !models
            .iter()
            .any(|model| normalize_model_name(model) == request.model)
    })
    {
        return failure_response(
            &state,
            started,
            None,
            Some(request.model),
            StatusCode::UNAUTHORIZED,
            "Model is not enabled for this API key",
        );
    }

    let resolution = {
        let resolver = state.resolver.read().expect("route resolver lock poisoned");
        resolver.resolve(&request.model)
    };
    let Some(resolution) = resolution else {
        return failure_response(
            &state,
            started,
            None,
            Some(request.model),
            StatusCode::BAD_REQUEST,
            "Unknown model",
        );
    };
    let provider_id = resolution.provider_id.clone();
    let model_id = resolution.model_id.clone();
    let descriptor = state
        .registry
        .read()
        .expect("provider registry lock poisoned")
        .get(&provider_id)
        .cloned();
    let Some(descriptor) = descriptor else {
        return failure_response(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::BAD_REQUEST,
            "Unknown provider",
        );
    };

    if !descriptor.models.iter().any(|model| model.id == model_id) {
        return failure_response(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::BAD_REQUEST,
            "Unknown model for provider",
        );
    }

    let provider_config = {
        let config = state.config.read().await;
        config
            .providers
            .get(&provider_id)
            .cloned()
            .unwrap_or_default()
    };

    if !provider_config.enabled {
        return failure_response(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::SERVICE_UNAVAILABLE,
            "Provider is disabled",
        );
    }
    if provider_config
        .disabled_models
        .iter()
        .any(|disabled| disabled == &model_id)
    {
        return failure_response(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::BAD_REQUEST,
            "Model is disabled for provider",
        );
    }
    let credential = {
        let config = state.config.read().await;
        config.credential_for(&provider_id)
    };
    if !credential.has_any() {
        return failure_response(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::SERVICE_UNAVAILABLE,
            "Provider credentials are missing",
        );
    }

    let Some(base_url) = descriptor.base_url.clone() else {
        return failure_response(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::SERVICE_UNAVAILABLE,
            "Provider endpoint is not configured",
        );
    };

    request.model = model_id.clone();

    // Anthropic 兼容上游（zai / minimax）：恒流式，SSE 翻译为 OpenAI chunk。
    if descriptor.anthropic_compat {
        let upstream_request = match anthropic::build_upstream_request(&base_url, &request, &credential) {
            Ok(r) => r,
            Err(error) => {
                return failure_response(
                    &state,
                    started,
                    Some(provider_id),
                    Some(model_id),
                    StatusCode::SERVICE_UNAVAILABLE,
                    error.to_string(),
                );
            }
        };
        let response = match upstream_request.send().await {
            Ok(r) => r,
            Err(error) => {
                return failure_response(
                    &state,
                    started,
                    Some(provider_id),
                    Some(model_id),
                    StatusCode::BAD_GATEWAY,
                    ProviderError::from(error).to_string(),
                );
            }
        };
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            let error = ProviderError::HttpStatus {
                status,
                body: body.clone(),
            };
            return failure_response(
                &state,
                started,
                Some(provider_id),
                Some(model_id),
                provider_error_status(&error),
                error.to_string(),
            );
        }
        let translated = anthropic::translate_stream(response.bytes_stream(), model_id.clone());
        let wants_stream = request.stream.unwrap_or(false);
        if wants_stream {
            return streaming_response(state, started, provider_id, model_id, translated);
        }
        // 非流式：聚合翻译后的 OpenAI SSE。
        let mut upstream = translated;
        let mut aggregator = SseAggregator::new(model_id.clone());
        while let Some(result) = upstream.next().await {
            match result {
                Ok(chunk) => aggregator.push(&chunk),
                Err(error) => {
                    return provider_error_response(&state, started, provider_id, model_id, error);
                }
            }
        }
        let response = aggregator.finish();
        let tokens = response.usage.as_ref().and_then(extract_from_json);
        record_request(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::OK,
            None,
            tokens,
        );
        return (StatusCode::OK, axum::Json(response)).into_response();
    }

    let provider = if provider_id == "codebuddy-cn" {
        OpenAICompatibleProvider::with_headers(
            provider_id.clone(),
            base_url,
            vec![
                ("Accept".to_string(), "text/event-stream".to_string()),
                (
                    "User-Agent".to_string(),
                    "CLI/2.108.1 CodeBuddy/2.108.1".to_string(),
                ),
                ("X-Product".to_string(), "SaaS".to_string()),
                ("X-IDE-Type".to_string(), "CLI".to_string()),
                ("X-IDE-Name".to_string(), "CLI".to_string()),
                ("X-Requested-With".to_string(), "XMLHttpRequest".to_string()),
                ("x-codebuddy-request".to_string(), "1".to_string()),
            ],
        )
    } else {
        OpenAICompatibleProvider::new(provider_id.clone(), base_url)
    };
    let wants_stream = request.stream.unwrap_or(false);

    if wants_stream {
        if !descriptor.supports_streaming {
            return failure_response(
                &state,
                started,
                Some(provider_id),
                Some(model_id),
                StatusCode::BAD_REQUEST,
                "Provider does not support streaming",
            );
        }

        return match provider.chat_stream(request, Some(&credential)).await {
            Ok(stream) => streaming_response(state, started, provider_id, model_id, stream),
            Err(error) => provider_error_response(&state, started, provider_id, model_id, error),
        };
    }

    if descriptor.force_stream {
        let upstream = match provider.chat_stream(request, Some(&credential)).await {
            Ok(stream) => stream,
            Err(error) => {
                return provider_error_response(&state, started, provider_id, model_id, error);
            }
        };
        let mut upstream = upstream;
        let mut aggregator = SseAggregator::new(model_id.clone());
        while let Some(result) = upstream.next().await {
            match result {
                Ok(chunk) => aggregator.push(&chunk),
                Err(error) => {
                    return provider_error_response(&state, started, provider_id, model_id, error);
                }
            }
        }

        let response = aggregator.finish();
        let tokens = response.usage.as_ref().and_then(extract_from_json);
        record_request(
            &state,
            started,
            Some(provider_id),
            Some(model_id),
            StatusCode::OK,
            None,
            tokens,
        );
        return (StatusCode::OK, axum::Json(response)).into_response();
    }

    match provider.chat(request, Some(&credential)).await {
        Ok(response) => {
            let tokens = response.usage.as_ref().and_then(extract_from_json);
            record_request(
                &state,
                started,
                Some(provider_id),
                Some(model_id),
                StatusCode::OK,
                None,
                tokens,
            );
            (StatusCode::OK, axum::Json(response)).into_response()
        }
        Err(error) => provider_error_response(&state, started, provider_id, model_id, error),
    }
}
