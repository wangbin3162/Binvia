use std::sync::Arc;

use axum::extract::{Query, State};
use axum::response::{IntoResponse, Json};
use serde::Deserialize;

use crate::server::state::AppState;

#[derive(Deserialize)]
pub struct EntriesQuery {
    pub limit: Option<usize>,
}

pub async fn entries_handler(
    State(state): State<Arc<AppState>>,
    Query(query): Query<EntriesQuery>,
) -> impl IntoResponse {
    let limit = query.limit.unwrap_or(50).min(500);
    let entries = state.logger.entries(limit);
    Json(serde_json::json!({ "entries": entries }))
}
