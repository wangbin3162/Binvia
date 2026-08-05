use std::collections::HashSet;
use std::sync::Arc;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Serialize;

use crate::auth;
use crate::server::state::AppState;

#[derive(Debug, Serialize)]
struct ModelItem {
    id: String,
    object: &'static str,
    created: u64,
    owned_by: String,
}

#[derive(Debug, Serialize)]
struct ModelsResponse {
    object: &'static str,
    data: Vec<ModelItem>,
}

fn json_error(status: StatusCode, message: &str) -> Response {
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

pub async fn models_handler(State(state): State<Arc<AppState>>, headers: HeaderMap) -> Response {
    let token = authorization_token(&headers);
    let config = state.config.read().await;
    let authentication_required = !config.api_keys.is_empty() || auth::has_env_api_keys();

    if authentication_required
        && !token
            .as_deref()
            .is_some_and(|value| auth::is_valid_api_key(value, &config))
    {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid API key");
    }

    let enabled_models = token.as_deref().and_then(|value| {
        config
            .api_keys
            .iter()
            .find(|key| key.key == value)
            .and_then(|key| key.enabled_models.as_ref())
            .map(|models| models.iter().cloned().collect::<HashSet<_>>())
    });

    let mut seen = HashSet::new();
    let mut data = Vec::new();

    let registry = state
        .registry
        .read()
        .expect("provider registry lock poisoned");
    for descriptor in registry.ordered_descriptors(&config.provider_order) {
        let provider_config = config.providers.get(&descriptor.metadata.id);
        if !config.provider_enabled(&descriptor.metadata.id) {
            continue;
        }

        let provider_prefix = descriptor
            .metadata
            .alias
            .as_deref()
            .unwrap_or(&descriptor.metadata.id);

        for model in &descriptor.models {
            if provider_config
                .is_some_and(|value| value.disabled_models.iter().any(|id| id == &model.id))
            {
                continue;
            }

            let id = format!("{provider_prefix}/{}", model.id);
            if enabled_models
                .as_ref()
                .is_some_and(|allowed| !allowed.contains(&id))
            {
                continue;
            }
            if !seen.insert(id.clone()) {
                continue;
            }

            data.push(ModelItem {
                id,
                object: "model",
                created: 0,
                owned_by: descriptor.metadata.id.clone(),
            });
        }
    }

    (
        StatusCode::OK,
        axum::Json(ModelsResponse {
            object: "list",
            data,
        }),
    )
        .into_response()
}
