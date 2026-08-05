use std::sync::Arc;

use axum::extract::State;
use axum::response::{IntoResponse, Json};
use serde::Serialize;

use crate::server::state::AppState;

#[derive(Serialize)]
pub struct ServerInfo {
    pub running: bool,
    pub host: String,
    pub port: u16,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SummaryInfo {
    pub total_requests: u64,
    pub total_errors: u64,
    pub active_providers: usize,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderInfo {
    pub id: String,
    pub display_name: String,
    pub configured: bool,
    pub enabled: bool,
}

#[derive(Serialize)]
pub struct OverviewResponse {
    pub server: ServerInfo,
    pub summary: SummaryInfo,
    pub providers: Vec<ProviderInfo>,
}

use crate::provider::catalog::builtin_providers;

pub async fn overview_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let config = state.config.read().await;
    let summary = state.logger.summary();
    let catalog = builtin_providers();

    let active_providers = catalog
        .iter()
        .filter(|descriptor| {
            config.provider_enabled(&descriptor.metadata.id)
                && config.credential_for(&descriptor.metadata.id).has_any()
        })
        .count();

    let providers: Vec<ProviderInfo> = catalog
        .into_iter()
        .map(|d| {
            let id = d.metadata.id.clone();
            ProviderInfo {
                id,
                display_name: d.metadata.display_name,
                configured: config.credential_for(&d.metadata.id).has_any(),
                enabled: config.provider_enabled(&d.metadata.id),
            }
        })
        .collect();

    Json(OverviewResponse {
        server: ServerInfo {
            running: true,
            host: config.host.clone(),
            port: config.port,
        },
        summary: SummaryInfo {
            total_requests: summary.total_requests,
            total_errors: summary.total_errors,
            active_providers,
            prompt_tokens: summary.prompt_tokens,
            completion_tokens: summary.completion_tokens,
            total_tokens: summary.total_tokens,
        },
        providers,
    })
}
