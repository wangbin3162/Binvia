use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};

use crate::server::state::AppState;

pub async fn login_handler(
    State(state): State<Arc<AppState>>,
    Json(body): Json<serde_json::Value>,
) -> impl IntoResponse {
    let password = match body.get("password").and_then(|v| v.as_str()) {
        Some(p) => p.to_string(),
        None => {
            return (
                StatusCode::UNAUTHORIZED,
                Json(serde_json::json!({"error": "Unauthorized"})),
            )
                .into_response();
        }
    };

    let config = state.config.read().await;
    if !config.web_panel_enabled {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "Not Found"})),
        )
            .into_response();
    }
    let Some(ref admin_password) = config.admin_password else {
        return (StatusCode::OK, Json(serde_json::json!({"token": ""}))).into_response();
    };

    if admin_password.is_empty() {
        return (StatusCode::OK, Json(serde_json::json!({"token": ""}))).into_response();
    }

    if password != *admin_password {
        return (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"error": "Unauthorized"})),
        )
            .into_response();
    }

    drop(config);
    let token = uuid::Uuid::new_v4().to_string();
    *state.admin_token.write().await = Some(token.clone());
    (StatusCode::OK, Json(serde_json::json!({"token": token}))).into_response()
}
