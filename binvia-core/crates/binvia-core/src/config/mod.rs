use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub mod store;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GatewayKeyConfig {
    pub key: String,
    #[serde(alias = "enabledModels")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled_models: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KeyedToken {
    pub label: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderCredential {
    #[serde(alias = "apiKey")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    #[serde(alias = "accessToken")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub access_token: Option<String>,
    #[serde(alias = "refreshToken")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refresh_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(alias = "expiresAt")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(alias = "machineId")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine_id: Option<String>,
    #[serde(alias = "workspaceId")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
}

impl ProviderCredential {
    pub fn has_any(&self) -> bool {
        self.api_key
            .as_deref()
            .is_some_and(|value| !value.is_empty())
            || self
                .access_token
                .as_deref()
                .is_some_and(|value| !value.is_empty())
            || self
                .refresh_token
                .as_deref()
                .is_some_and(|value| !value.is_empty())
    }
}

impl Default for ProviderCredential {
    fn default() -> Self {
        Self {
            api_key: None,
            access_token: None,
            refresh_token: None,
            email: None,
            expires_at: None,
            region: None,
            machine_id: None,
            workspace_id: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub credential: ProviderCredential,
    #[serde(alias = "apiKeys")]
    #[serde(default)]
    #[serde(deserialize_with = "deserialize_provider_tokens")]
    pub api_keys: Vec<KeyedToken>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    #[serde(alias = "disabledModels")]
    #[serde(default)]
    pub disabled_models: Vec<String>,
}

fn default_enabled() -> bool {
    true
}

impl Default for ProviderConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            credential: ProviderCredential::default(),
            api_keys: Vec::new(),
            region: None,
            disabled_models: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomProviderDef {
    pub id: String,
    #[serde(alias = "displayName")]
    pub display_name: String,
    #[serde(alias = "baseURL", alias = "baseUrl")]
    pub base_url: String,
    pub models: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteConfig {
    #[serde(default)]
    pub version: u32,
    #[serde(default = "default_host")]
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(alias = "apiKeys")]
    #[serde(default)]
    #[serde(deserialize_with = "deserialize_gateway_keys")]
    pub api_keys: Vec<GatewayKeyConfig>,
    #[serde(default)]
    pub providers: HashMap<String, ProviderConfig>,
    #[serde(alias = "providerOrder")]
    #[serde(default)]
    pub provider_order: Vec<String>,
    #[serde(alias = "customProviderDefs")]
    #[serde(default)]
    pub custom_provider_defs: Vec<CustomProviderDef>,
    #[serde(alias = "webPanelEnabled")]
    #[serde(default = "default_web_panel")]
    pub web_panel_enabled: bool,
    #[serde(alias = "adminPassword")]
    #[serde(skip_serializing_if = "Option::is_none")]
    pub admin_password: Option<String>,
}

fn default_host() -> String {
    "127.0.0.1".to_string()
}

fn default_port() -> u16 {
    20427
}

fn default_web_panel() -> bool {
    true
}

impl Default for RouteConfig {
    fn default() -> Self {
        Self {
            version: 1,
            host: default_host(),
            port: default_port(),
            api_keys: Vec::new(),
            providers: HashMap::new(),
            provider_order: Vec::new(),
            custom_provider_defs: Vec::new(),
            web_panel_enabled: true,
            admin_password: None,
        }
    }
}

impl RouteConfig {
    pub fn credential_for(&self, provider_id: &str) -> ProviderCredential {
        if let Some(provider) = self.providers.get(provider_id) {
            let mut credential = provider.credential.clone();
            if credential.api_key.as_deref().is_none_or(str::is_empty) {
                credential.api_key = provider
                    .api_keys
                    .iter()
                    .map(|token| token.value.trim())
                    .find(|value| !value.is_empty())
                    .map(str::to_string);
            }
            if credential.has_any() {
                return credential;
            }
        }

        let base = provider_id.to_uppercase().replace('-', "_");
        let names = [format!("{base}_API_KEY"), format!("{base}_ACCESS_TOKEN")];
        for name in names {
            if let Ok(value) = std::env::var(&name) {
                if !value.is_empty() {
                    return ProviderCredential {
                        api_key: Some(value),
                        ..ProviderCredential::default()
                    };
                }
            }
        }

        if provider_id == "codebuddy-cn" {
            if let Ok(value) = std::env::var("CODEBUDDY_CN_ACCESS_TOKEN") {
                if !value.is_empty() {
                    return ProviderCredential {
                        access_token: Some(value),
                        ..ProviderCredential::default()
                    };
                }
            }
        }
        if provider_id == "antigravity" {
            if let Ok(value) = std::env::var("ANTIGRAVITY_ACCESS_TOKEN") {
                if !value.is_empty() {
                    return ProviderCredential {
                        access_token: Some(value),
                        ..ProviderCredential::default()
                    };
                }
            }
        }

        ProviderCredential::default()
    }

    pub fn provider_enabled(&self, provider_id: &str) -> bool {
        self.providers
            .get(provider_id)
            .map(|provider| provider.enabled)
            .unwrap_or(true)
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum GatewayKeyInput {
    Legacy(String),
    Current(GatewayKeyConfig),
}

fn deserialize_gateway_keys<'de, D>(deserializer: D) -> Result<Vec<GatewayKeyConfig>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let values = Vec::<GatewayKeyInput>::deserialize(deserializer)?;
    Ok(values
        .into_iter()
        .map(|value| match value {
            GatewayKeyInput::Legacy(key) => GatewayKeyConfig {
                key,
                enabled_models: None,
            },
            GatewayKeyInput::Current(value) => value,
        })
        .collect())
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ProviderTokenInput {
    Legacy(String),
    Current(KeyedToken),
}

fn deserialize_provider_tokens<'de, D>(deserializer: D) -> Result<Vec<KeyedToken>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let values = Vec::<ProviderTokenInput>::deserialize(deserializer)?;
    Ok(values
        .into_iter()
        .map(|value| match value {
            ProviderTokenInput::Legacy(token) => KeyedToken {
                label: token.clone(),
                value: token,
            },
            ProviderTokenInput::Current(value) => value,
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::CustomProviderDef;

    #[test]
    fn custom_provider_base_url_accepts_supported_key_styles() {
        for key in ["base_url", "baseURL", "baseUrl"] {
            let mut value = serde_json::json!({
                "id": "local-openai",
                "displayName": "Local OpenAI",
                "models": ["local-model"]
            });
            value.as_object_mut().unwrap().insert(
                key.to_string(),
                serde_json::json!("http://127.0.0.1:9999/v1"),
            );
            let provider: CustomProviderDef = serde_json::from_value(value).unwrap();
            assert_eq!(provider.base_url, "http://127.0.0.1:9999/v1");
        }
    }
}
