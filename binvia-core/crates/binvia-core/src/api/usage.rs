use std::sync::Arc;

use axum::extract::State;
use axum::response::{IntoResponse, Json};
use chrono::Utc;
use futures::future::join_all;

use crate::monitor::usage_cache::ProviderUsageSnapshot;
use crate::provider::catalog::builtin_providers;
use crate::server::state::AppState;

pub async fn refresh_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    refresh_all(&state).await;
    let snapshots = state.usage_cache.all();
    Json(serde_json::json!({ "snapshots": snapshots }))
}

/// 并发抓取全部已配置（含 env 凭据）provider 的用量，写缓存。
pub async fn refresh_all(state: &Arc<AppState>) {
    let providers: Vec<(String, crate::config::ProviderConfig, crate::config::ProviderCredential)> = {
        let config = state.config.read().await;
        builtin_providers()
            .into_iter()
            .map(|descriptor| {
                let id = descriptor.metadata.id.clone();
                let provider_config = config
                    .providers
                    .get(&id)
                    .cloned()
                    .unwrap_or_default();
                let credential = config.credential_for(&id);
                (id, provider_config, credential)
            })
            .collect()
    };

    let tasks: Vec<_> = providers
        .into_iter()
        .map(|(id, provider_config, credential)| {
            let state = Arc::clone(state);
            async move {
                if !credential.has_any() {
                    return;
                }
                let snapshot = crate::usage::fetch_usage(&id, &provider_config, &credential).await;
                state.usage_cache.set(id.clone(), snapshot);
            }
        })
        .collect();
    join_all(tasks).await;
}

/// 单 provider 抓取（供 OAuth 登录成功后立即刷新）。
pub async fn refresh_one(state: &AppState, provider_id: &str) -> ProviderUsageSnapshot {
    let (provider_config, credential) = {
        let config = state.config.read().await;
        let provider_config = config
            .providers
            .get(provider_id)
            .cloned()
            .unwrap_or_default();
        let credential = config.credential_for(provider_id);
        (provider_config, credential)
    };
    if !credential.has_any() {
        return ProviderUsageSnapshot {
            provider_id: provider_id.to_string(),
            balance: None,
            currency: None,
            balances: Vec::new(),
            quota_windows: Vec::new(),
            model_quotas: Vec::new(),
            raw_json: None,
            fetched_at: Utc::now().to_rfc3339(),
            error: Some("未配置凭据".to_string()),
        };
    }
    let snapshot = crate::usage::fetch_usage(provider_id, &provider_config, &credential).await;
    state.usage_cache.set(provider_id.to_string(), snapshot.clone());
    snapshot
}
