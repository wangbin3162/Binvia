use std::sync::Arc;

use axum::extract::State;
use axum::response::Json;

use crate::server::state::AppState;

pub async fn usage_handler(
    State(state): State<Arc<AppState>>,
) -> Json<crate::monitor::UsageSummary> {
    Json(state.logger.summary())
}
