use std::collections::HashSet;
use std::sync::Arc;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::{Deserialize, Serialize};

use crate::auth;
use crate::provider::descriptor::Model;
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
    let (authentication_required, valid_token, enabled_models, provider_order, provider_configs) = {
        let config = state.config.read().await;
        let authentication_required = !config.api_keys.is_empty() || auth::has_env_api_keys();
        let valid_token = token
            .as_deref()
            .is_some_and(|value| auth::is_valid_api_key(value, &config));
        let enabled_models = token.as_deref().and_then(|value| {
            config
                .api_keys
                .iter()
                .find(|key| key.key == value)
                .and_then(|key| key.enabled_models.as_ref())
                .map(|models| models.iter().cloned().collect::<HashSet<_>>())
        });
        let provider_configs: Vec<(String, crate::config::ProviderConfig, crate::config::ProviderCredential)> = {
            let mut entries: Vec<_> = config
                .providers
                .iter()
                .map(|(id, p)| (id.clone(), p.clone(), config.credential_for(id)))
                .collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            entries
        };
        (
            authentication_required,
            valid_token,
            enabled_models,
            config.provider_order.clone(),
            provider_configs,
        )
    };

    if authentication_required && !valid_token {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid API key");
    }

    let mut seen = HashSet::new();
    let mut data = Vec::new();

    let descriptors: Vec<_> = {
        let registry = state
            .registry
            .read()
            .expect("provider registry lock poisoned");
        registry
            .ordered_descriptors(&provider_order)
            .into_iter()
            .cloned()
            .collect()
    };

    // provider_configs 转成 HashMap 便于查找（owned，跨 await 安全）。
    let config_map: std::collections::HashMap<String, (crate::config::ProviderConfig, crate::config::ProviderCredential)> =
        provider_configs.into_iter().map(|(id, p, c)| (id, (p, c))).collect();

    // 并发拉取各 provider 的有效模型列表（缓存 → 上游 → 静态回退）。
    let mut tasks = Vec::with_capacity(descriptors.len());
    for descriptor in &descriptors {
        let provider_id = descriptor.metadata.id.clone();
        let entry = config_map.get(&provider_id);
        let enabled = entry.map(|(p, _)| p.enabled).unwrap_or(true);
        let credential = entry
            .map(|(_, c)| c.clone())
            .unwrap_or_default();
        let base_url = descriptor.base_url.clone();
        let anthropic_compat = descriptor.anthropic_compat;
        let force_stream = descriptor.force_stream;
        let static_models = descriptor.models.clone();
        let alias = descriptor.metadata.alias.clone();
        let cache = Arc::clone(&state.model_cache);
        tasks.push(async move {
            let models = effective_models(
                &provider_id,
                enabled,
                anthropic_compat,
                force_stream,
                base_url.as_deref(),
                &credential,
                &static_models,
                &cache,
            )
            .await;
            (provider_id, alias, models)
        });
    }
    let resolved = futures::future::join_all(tasks).await;

    for (provider_id, alias, models) in resolved {
        let entry = config_map.get(&provider_id);
        let provider_config = entry.map(|(p, _)| p);
        let enabled = provider_config.map(|p| p.enabled).unwrap_or(true);
        if !enabled {
            continue;
        }

        let provider_prefix = alias.as_deref().unwrap_or(&provider_id);

        for model in &models {
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
                owned_by: provider_id.clone(),
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

/// 计算 provider 的有效模型列表：缓存命中 → 上游 `/v1/models` → 静态目录回退。
/// 特殊协议（force_stream / anthropic_compat / codex / cursor）不走动态拉取。
async fn effective_models(
    provider_id: &str,
    enabled: bool,
    anthropic_compat: bool,
    force_stream: bool,
    base_url: Option<&str>,
    credential: &crate::config::ProviderCredential,
    static_models: &[Model],
    cache: &Arc<crate::networking::ModelCache>,
) -> Vec<Model> {
    if !enabled {
        return Vec::new();
    }
    if let Some(cached) = cache.get(provider_id).await {
        return cached;
    }

    // 特殊协议 provider 不走 OpenAI /models 拉取，直接返回静态目录。
    if force_stream || anthropic_compat || matches!(provider_id, "codex" | "cursor") {
        return static_models.to_vec();
    }

    let Some(base) = base_url else {
        return static_models.to_vec();
    };
    let token = credential
        .api_key
        .as_deref()
        .filter(|v| !v.is_empty())
        .or_else(|| {
            credential
                .access_token
                .as_deref()
                .filter(|v| !v.is_empty())
        });
    let Some(token) = token else {
        return static_models.to_vec();
    };

    let trimmed = base.trim_end_matches('/');
    let models_url = if let Some(prefix) = trimmed.strip_suffix("/chat/completions") {
        format!("{}/models", prefix.trim_end_matches('/'))
    } else {
        format!("{}/models", trimmed)
    };

    let client = crate::networking::HttpClient::shared();
    let result = client
        .data_for(client.inner().get(&models_url).bearer_auth(token))
        .await;
    match result {
        Ok(response) if response.status.is_success() => {
            match serde_json::from_slice::<DynamicModelsResponse>(&response.body) {
                Ok(payload) if !payload.data.is_empty() => {
                    let models: Vec<Model> = payload
                        .data
                        .into_iter()
                        .map(|item| Model {
                            id: item.id,
                            name: None,
                            context_length: None,
                            supports_reasoning: false,
                            supports_vision: false,
                        })
                        .collect();
                    cache.set(provider_id, models.clone()).await;
                    models
                }
                _ => static_models.to_vec(),
            }
        }
        _ => static_models.to_vec(),
    }
}

#[derive(Debug, Deserialize)]
struct DynamicModelsResponse {
    #[serde(default)]
    data: Vec<RemoteModel>,
}

#[derive(Debug, Deserialize)]
struct RemoteModel {
    id: String,
}
