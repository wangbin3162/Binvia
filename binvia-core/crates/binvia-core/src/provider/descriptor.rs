use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderAuthType {
    ApiKey,
    OAuth,
    DeviceFlow,
    LocalProbe,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderMetadata {
    pub id: String,
    pub alias: Option<String>,
    pub display_name: String,
    pub auth_type: ProviderAuthType,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderApiRegion {
    pub id: String,
    pub display_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Model {
    pub id: String,
    pub name: Option<String>,
    pub context_length: Option<u32>,
    #[serde(default)]
    pub supports_reasoning: bool,
    #[serde(default)]
    pub supports_vision: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderDescriptor {
    pub metadata: ProviderMetadata,
    pub base_url: Option<String>,
    pub models: Vec<Model>,
    #[serde(default)]
    pub supports_streaming: bool,
    pub models_url: Option<String>,
    #[serde(default)]
    pub force_stream: bool,
    #[serde(default)]
    pub regions: Vec<ProviderApiRegion>,
    pub usage_dashboard_url: Option<String>,
    #[serde(default)]
    pub is_user_defined: bool,
}
