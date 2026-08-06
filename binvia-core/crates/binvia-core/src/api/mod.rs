pub mod config;
pub mod entries;
pub mod keys;
pub mod login;
pub mod overview;
pub mod providers;
pub mod snapshots;
pub mod test;
pub mod usage;

use std::sync::Arc;

use axum::Router;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};
use axum::routing::{delete, get, post};

use crate::server::state::AppState;

pub fn admin_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/overview", get(overview::overview_handler))
        .route("/entries", get(entries::entries_handler))
        .route("/providers", get(providers::providers_handler))
        .route(
            "/providers/{provider_id}/test",
            post(providers::test_handler),
        )
        .route(
            "/providers/{provider_id}/test-model",
            post(test::test_model_handler),
        )
        .route("/playground", post(test::playground_handler))
        .route("/snapshots", get(snapshots::snapshots_handler))
        .route("/config", get(config::get_config_handler))
        .route("/config", post(config::post_config_handler))
        .route("/keys", post(keys::create_key_handler))
        .route("/keys/{key_value}", delete(keys::delete_key_handler))
        .route("/usage/refresh", post(usage::refresh_handler))
        .fallback(fallback_handler)
}

async fn fallback_handler() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({"error": "Not Found"})),
    )
}
