use std::sync::Arc;

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json};

use crate::config::RouteConfig;
use crate::config::store::ConfigStore;
use crate::server::state::AppState;

fn mask_value(value: &str) -> String {
    let characters: Vec<char> = value.chars().collect();
    if characters.len() <= 10 {
        return value.to_string();
    }
    let prefix: String = characters.iter().take(6).collect();
    let suffix: String = characters.iter().skip(characters.len() - 4).collect();
    format!("{prefix}••••{suffix}")
}

fn mask_config(config: &RouteConfig) -> serde_json::Value {
    let mut masked = serde_json::to_value(config).unwrap();
    if let Some(obj) = masked.as_object_mut() {
        if let Some(password) = obj.get("admin_password") {
            if password.is_string() {
                obj.insert("admin_password".into(), serde_json::json!("••••••••"));
            }
        }
        if let Some(providers) = obj.get_mut("providers") {
            if let Some(map) = providers.as_object_mut() {
                for (_id, provider) in map.iter_mut() {
                    if let Some(cred) = provider.get_mut("credential") {
                        if let Some(cred_obj) = cred.as_object_mut() {
                            for field in ["api_key", "access_token", "refresh_token"] {
                                if let Some(val) = cred_obj.get(field) {
                                    if let Some(s) = val.as_str() {
                                        cred_obj
                                            .insert(field.into(), serde_json::json!(mask_value(s)));
                                    }
                                }
                            }
                        }
                    }
                    if let Some(tokens) = provider.get_mut("api_keys") {
                        if let Some(tokens) = tokens.as_array_mut() {
                            for token in tokens {
                                let value = token
                                    .get("value")
                                    .and_then(serde_json::Value::as_str)
                                    .map(str::to_string);
                                let label = token
                                    .get("label")
                                    .and_then(serde_json::Value::as_str)
                                    .unwrap_or_default()
                                    .to_string();
                                if let Some(value) = value {
                                    *token = serde_json::json!({
                                        "label": label,
                                        "value": mask_value(&value),
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    camelize_keys(masked)
}

fn camelize_key(key: &str) -> String {
    if key == "base_url" {
        return "baseURL".to_string();
    }

    let mut result = String::with_capacity(key.len());
    let mut uppercase_next = false;
    for character in key.chars() {
        if character == '_' {
            uppercase_next = true;
        } else if uppercase_next {
            result.extend(character.to_uppercase());
            uppercase_next = false;
        } else {
            result.push(character);
        }
    }
    result
}

fn camelize_keys(value: serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Array(values) => {
            serde_json::Value::Array(values.into_iter().map(camelize_keys).collect())
        }
        serde_json::Value::Object(values) => serde_json::Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (camelize_key(&key), camelize_keys(value)))
                .collect(),
        ),
        value => value,
    }
}

fn is_masked(value: &str) -> bool {
    value.contains("••••")
}

fn preserve_masked_values(current: RouteConfig, mut incoming: RouteConfig) -> RouteConfig {
    if incoming.admin_password.as_deref().is_some_and(is_masked) {
        incoming.admin_password = current.admin_password.clone();
    }

    for (provider_id, incoming_provider) in &mut incoming.providers {
        let Some(current_provider) = current.providers.get(provider_id) else {
            continue;
        };
        for (current_value, incoming_value) in [
            (
                &current_provider.credential.api_key,
                &mut incoming_provider.credential.api_key,
            ),
            (
                &current_provider.credential.access_token,
                &mut incoming_provider.credential.access_token,
            ),
            (
                &current_provider.credential.refresh_token,
                &mut incoming_provider.credential.refresh_token,
            ),
        ] {
            if incoming_value.as_deref().is_some_and(is_masked) {
                *incoming_value = current_value.clone();
            }
        }

        for (index, incoming_token) in incoming_provider.api_keys.iter_mut().enumerate() {
            if !is_masked(&incoming_token.value) {
                continue;
            }
            if let Some(current_token) = current_provider
                .api_keys
                .iter()
                .find(|token| token.label == incoming_token.label)
                .or_else(|| current_provider.api_keys.get(index))
            {
                incoming_token.value = current_token.value.clone();
            }
        }
    }

    incoming
}

pub async fn get_config_handler(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let config = state.config.read().await;
    let masked = mask_config(&config);
    Json(masked)
}

pub async fn post_config_handler(
    State(state): State<Arc<AppState>>,
    Json(body): Json<serde_json::Value>,
) -> impl IntoResponse {
    let incoming_config: RouteConfig = match serde_json::from_value(body) {
        Ok(c) => c,
        Err(_) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "invalid config"})),
            )
                .into_response();
        }
    };
    let current_config = state.config.read().await.clone();
    let new_config = preserve_masked_values(current_config, incoming_config);

    let store = ConfigStore::new();
    match store.save(&new_config) {
        Ok(()) => {
            state.replace_config(new_config).await;
            (StatusCode::OK, Json(serde_json::json!({"status": "ok"}))).into_response()
        }
        Err(e) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": format!("{}", e)})),
        )
            .into_response(),
    }
}
