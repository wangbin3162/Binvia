use std::sync::Arc;

use axum::extract::{Path, State};
use axum::response::{IntoResponse, Json};
use serde::Serialize;

use crate::config::RouteConfig;
use crate::provider::descriptor::ProviderAuthType;
use crate::providers::{OpenAICompatibleProvider, Provider, test_codebuddy_connection};
use crate::server::state::AppState;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderEntry {
    pub id: String,
    pub alias: Option<String>,
    pub display_name: String,
    pub auth_type: String,
    pub configured: bool,
    pub enabled: bool,
    pub region: Option<String>,
    pub model_count: usize,
    pub models: Vec<String>,
    #[serde(rename = "baseURL")]
    pub base_url: Option<String>,
    pub is_user_defined: bool,
}

pub async fn providers_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let config = state.config.read().await;
    let registry = state
        .registry
        .read()
        .expect("provider registry lock poisoned");

    let providers: Vec<ProviderEntry> = registry
        .ordered_descriptors(&config.provider_order)
        .into_iter()
        .map(|d| {
            let id = d.metadata.id.clone();
            let alias = d.metadata.alias.clone();
            let display_name = d.metadata.display_name.clone();
            let auth_type = auth_type_name(&d.metadata.auth_type);
            ProviderEntry {
                id: id.clone(),
                alias,
                display_name,
                auth_type: auth_type.to_string(),
                configured: config.credential_for(&id).has_any(),
                enabled: config.provider_enabled(&id),
                region: config.providers.get(&id).and_then(|p| p.region.clone()),
                model_count: d.models.len(),
                models: d.models.iter().map(|model| model.id.clone()).collect(),
                base_url: d.base_url.clone(),
                is_user_defined: d.is_user_defined,
            }
        })
        .collect();

    Json(serde_json::json!({ "providers": providers }))
}

#[derive(Serialize)]
pub struct TestResult {
    pub success: bool,
    pub message: String,
}

pub async fn test_handler(
    State(state): State<Arc<AppState>>,
    Path(provider_id): Path<String>,
) -> impl IntoResponse {
    let result = async {
        let descriptor = {
            state
                .registry
                .read()
                .expect("provider registry lock poisoned")
                .get(&provider_id)
                .cloned()
        }
        .ok_or_else(|| format!("未找到 Provider: {provider_id}"))?;

        if let Some(message) = unsupported_protocol_message(&provider_id) {
            return Err(format!("{provider_id}: {message}"));
        }

        if provider_id == "codebuddy-cn" {
            let token = {
                let config = state.config.read().await;
                codebuddy_test_token(&config)
            }
            .ok_or_else(|| "CodeBuddy credentials are missing".to_string())?;

            return test_codebuddy_connection(&token)
                .await
                .map_err(|error| error.to_string());
        }

        let base_url = descriptor
            .base_url
            .clone()
            .ok_or_else(|| "Provider endpoint is not configured".to_string())?;
        let config = state.config.read().await;
        let credential = config.credential_for(&provider_id);
        if !credential.has_any() {
            return Err("Provider credentials are missing".to_string());
        }
        let provider = OpenAICompatibleProvider::new(provider_id, base_url);
        provider
            .test_connection(Some(&credential))
            .await
            .map_err(|error| error.to_string())
    }
    .await;

    match result {
        Ok(()) => Json(TestResult {
            success: true,
            message: "Connection successful".to_string(),
        }),
        Err(message) => Json(TestResult {
            success: false,
            message,
        }),
    }
}

fn auth_type_name(auth_type: &ProviderAuthType) -> &'static str {
    match auth_type {
        ProviderAuthType::ApiKey => "apiKey",
        ProviderAuthType::OAuth => "oauth",
        ProviderAuthType::DeviceFlow => "deviceFlow",
        ProviderAuthType::LocalProbe => "localProbe",
    }
}

fn codebuddy_test_token(config: &RouteConfig) -> Option<String> {
    config
        .providers
        .get("codebuddy-cn")
        .and_then(|provider| {
            provider
                .api_keys
                .iter()
                .map(|token| token.value.trim())
                .find(|token| !token.is_empty())
        })
        .map(str::to_string)
        .or_else(|| {
            config
                .providers
                .get("codebuddy-cn")
                .and_then(|provider| provider.credential.api_key.clone())
                .filter(|token| !token.trim().is_empty())
        })
        .or_else(|| {
            config
                .providers
                .get("codebuddy-cn")
                .and_then(|provider| provider.credential.access_token.clone())
                .filter(|token| !token.trim().is_empty())
        })
        .or_else(|| {
            std::env::var("CODEBUDDY_CN_ACCESS_TOKEN")
                .ok()
                .map(|token| token.trim().to_string())
                .filter(|token| !token.is_empty())
        })
}

fn unsupported_protocol_message(provider_id: &str) -> Option<&'static str> {
    match provider_id {
        "antigravity" | "zai" | "minimax" | "codex" | "cursor" => {
            Some("不支持专用协议/尚未实现连接测试")
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{auth_type_name, codebuddy_test_token, unsupported_protocol_message};
    use crate::config::{KeyedToken, ProviderConfig, RouteConfig};
    use crate::provider::descriptor::ProviderAuthType;
    use crate::server::state::AppState;

    #[tokio::test]
    async fn provider_state_rebuild_includes_custom_provider() {
        let state = AppState::new(RouteConfig::default());
        let mut config = RouteConfig::default();
        config
            .custom_provider_defs
            .push(crate::config::CustomProviderDef {
                id: "local-openai".to_string(),
                display_name: "Local OpenAI".to_string(),
                base_url: "http://127.0.0.1:9999/v1".to_string(),
                models: vec!["local-model".to_string()],
            });

        state.replace_config(config).await;

        let descriptor = state
            .registry
            .read()
            .expect("provider registry lock poisoned")
            .get("local-openai")
            .cloned()
            .expect("custom provider registered");
        assert!(descriptor.is_user_defined);
        assert_eq!(descriptor.models[0].id, "local-model");

        let resolution = state
            .resolver
            .read()
            .expect("route resolver lock poisoned")
            .resolve("local-openai/local-model")
            .expect("custom model resolved");
        assert_eq!(resolution.provider_id, "local-openai");
        assert_eq!(resolution.model_id, "local-model");
    }

    #[test]
    fn codebuddy_test_prefers_the_first_configured_api_key() {
        let mut config = RouteConfig::default();
        config.providers.insert(
            "codebuddy-cn".to_string(),
            ProviderConfig {
                api_keys: vec![
                    KeyedToken {
                        label: "primary".to_string(),
                        value: "  primary-token  ".to_string(),
                    },
                    KeyedToken {
                        label: "secondary".to_string(),
                        value: "secondary-token".to_string(),
                    },
                ],
                ..ProviderConfig::default()
            },
        );

        assert_eq!(
            codebuddy_test_token(&config).as_deref(),
            Some("primary-token")
        );
    }

    #[test]
    fn unsupported_protocols_are_not_reported_as_openai_tests() {
        for provider_id in ["antigravity", "zai", "minimax", "codex", "cursor"] {
            assert_eq!(
                unsupported_protocol_message(provider_id),
                Some("不支持专用协议/尚未实现连接测试")
            );
        }
    }

    #[test]
    fn api_auth_type_names_match_provider_response_contract() {
        assert_eq!(auth_type_name(&ProviderAuthType::ApiKey), "apiKey");
        assert_eq!(auth_type_name(&ProviderAuthType::DeviceFlow), "deviceFlow");
        assert_eq!(auth_type_name(&ProviderAuthType::OAuth), "oauth");
    }
}
