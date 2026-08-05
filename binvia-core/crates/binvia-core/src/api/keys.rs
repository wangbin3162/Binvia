use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use serde::Deserialize;

use crate::config::GatewayKeyConfig;
use crate::server::state::AppState;

#[derive(Deserialize)]
pub struct CreateKeyRequest {
    pub key: Option<String>,
    #[serde(alias = "enabledModels")]
    pub enabled_models: Option<Vec<String>>,
}

pub async fn create_key_handler(
    State(state): State<Arc<AppState>>,
    Json(body): Json<CreateKeyRequest>,
) -> impl IntoResponse {
    let key_value = body.key.unwrap_or_else(|| {
        let uuid = uuid::Uuid::new_v4().to_string().replace("-", "");
        let short = &uuid[..24];
        format!("sk-bv-{}", short)
    });

    let new_key = GatewayKeyConfig {
        key: key_value.clone(),
        enabled_models: body.enabled_models,
    };
    let enabled_models = new_key.enabled_models.clone();

    let mut config = state.config.write().await;
    let existing = config.api_keys.iter_mut().find(|k| k.key == key_value);
    match existing {
        Some(k) => {
            k.enabled_models = new_key.enabled_models.clone();
        }
        None => {
            config.api_keys.push(new_key);
        }
    }

    let store = crate::config::store::ConfigStore::new();
    if let Err(error) = store.save(&config) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": error.to_string()})),
        )
            .into_response();
    }

    Json(serde_json::json!({
        "key": key_value,
        "enabledModels": enabled_models
    }))
    .into_response()
}

pub async fn delete_key_handler(
    State(state): State<Arc<AppState>>,
    Path(key_value): Path<String>,
) -> impl IntoResponse {
    let mut config = state.config.write().await;
    let initial_len = config.api_keys.len();
    config.api_keys.retain(|k| k.key != key_value);

    let store = crate::config::store::ConfigStore::new();
    if config.api_keys.len() != initial_len {
        if let Err(error) = store.save(&config) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": error.to_string()})),
            )
                .into_response();
        }
    }

    (StatusCode::OK, Json(serde_json::json!({"status": "ok"}))).into_response()
}
