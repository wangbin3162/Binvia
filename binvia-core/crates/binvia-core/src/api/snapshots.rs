use std::sync::Arc;

use axum::extract::State;
use axum::response::{IntoResponse, Json};

use crate::server::state::AppState;

pub async fn snapshots_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let snapshots = state.usage_cache.all();
    Json(serde_json::json!({ "snapshots": snapshots }))
}
