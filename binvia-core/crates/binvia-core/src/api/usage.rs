use std::sync::Arc;

use axum::extract::State;
use axum::response::{IntoResponse, Json};
use chrono::Utc;

use crate::monitor::usage_cache::ProviderUsageSnapshot;
use crate::server::state::AppState;

pub async fn refresh_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let config = state.config.read().await;
    let provider_ids: Vec<String> = config.providers.keys().cloned().collect();
    drop(config);

    let mut snapshots = serde_json::Map::new();
    for provider_id in provider_ids {
        let snapshot = ProviderUsageSnapshot {
            provider_id: provider_id.clone(),
            balance: None,
            currency: None,
            balances: Vec::new(),
            quota_windows: Vec::new(),
            model_quotas: Vec::new(),
            raw_json: None,
            fetched_at: Utc::now().to_rfc3339(),
            error: None,
        };
        state.usage_cache.set(provider_id.clone(), snapshot.clone());
        snapshots.insert(provider_id, serde_json::to_value(snapshot).unwrap());
    }

    Json(serde_json::json!({ "snapshots": snapshots }))
}
