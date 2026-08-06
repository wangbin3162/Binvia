use std::time::{SystemTime, UNIX_EPOCH};

use reqwest::StatusCode;

use crate::config::ProviderCredential;
use crate::gateway::anthropic;
use crate::provider::descriptor::ProviderDescriptor;
use crate::providers::{ChatRequest, ChatStream, OpenAICompatibleProvider, Provider, ProviderError};

/// 构建一个聊天流（OpenAI chunk 流）。供 chat_handler / test-model / playground 复用。
///
/// - `anthropic_compat`：恒流式，Anthropic SSE → OpenAI chunk 翻译；
/// - `codebuddy-cn`：专用 headers + force-stream；
/// - `codex` / `cursor`：专用协议（Phase F/G 接入，当前回退到 OpenAI 兼容）；
/// - 其余：OpenAI 兼容 `chat_stream`。
pub async fn build_chat_stream(
    descriptor: &ProviderDescriptor,
    base_url: &str,
    credential: &ProviderCredential,
    request: ChatRequest,
) -> Result<ChatStream, ProviderError> {
    let provider_id = &descriptor.metadata.id;

    if descriptor.anthropic_compat {
        let upstream_request =
            anthropic::build_upstream_request(base_url, &request, credential)?;
        let response = upstream_request.send().await.map_err(ProviderError::from)?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(ProviderError::HttpStatus { status, body });
        }
        return Ok(anthropic::translate_stream(
            response.bytes_stream(),
            request.model.clone(),
        ));
    }

    let provider = if provider_id == "codebuddy-cn" {
        OpenAICompatibleProvider::with_headers(
            provider_id.clone(),
            base_url.to_string(),
            vec![
                ("Accept".to_string(), "text/event-stream".to_string()),
                (
                    "User-Agent".to_string(),
                    "CLI/2.108.1 CodeBuddy/2.108.1".to_string(),
                ),
                ("X-Product".to_string(), "SaaS".to_string()),
                ("X-IDE-Type".to_string(), "CLI".to_string()),
                ("X-IDE-Name".to_string(), "CLI".to_string()),
                ("X-Requested-With".to_string(), "XMLHttpRequest".to_string()),
                ("x-codebuddy-request".to_string(), "1".to_string()),
            ],
        )
    } else {
        OpenAICompatibleProvider::new(provider_id.clone(), base_url.to_string())
    };

    provider.chat_stream(request, Some(credential)).await
}

/// 解析 provider/model，返回 (provider_id, model_id, descriptor, credential, base_url)。
/// 失败返回错误消息字符串。
pub struct ResolvedProvider {
    pub provider_id: String,
    pub model_id: String,
    pub descriptor: ProviderDescriptor,
    pub credential: ProviderCredential,
    pub base_url: String,
}

pub async fn resolve_for_model(
    state: &crate::server::state::AppState,
    model: &str,
) -> Result<ResolvedProvider, String> {
    let normalized = crate::router::normalize_model_name(model);
    let resolution = {
        let resolver = state
            .resolver
            .read()
            .expect("route resolver lock poisoned");
        resolver.resolve(&normalized)
    }
    .ok_or_else(|| format!("未知模型: {model}"))?;
    let provider_id = resolution.provider_id.clone();
    let model_id = resolution.model_id.clone();
    let descriptor = state
        .registry
        .read()
        .expect("provider registry lock poisoned")
        .get(&provider_id)
        .cloned()
        .ok_or_else(|| format!("未知 Provider: {provider_id}"))?;
    if !descriptor.models.iter().any(|m| m.id == model_id) {
        return Err(format!("Provider {provider_id} 无模型 {model_id}"));
    }
    let (provider_config, credential, base_url) = {
        let config = state.config.read().await;
        let provider_config = config
            .providers
            .get(&provider_id)
            .cloned()
            .unwrap_or_default();
        let credential = config.credential_for(&provider_id);
        let base_url = descriptor
            .base_url
            .clone()
            .ok_or_else(|| "Provider endpoint is not configured".to_string())?;
        (provider_config, credential, base_url)
    };
    if !provider_config.enabled {
        return Err(format!("Provider {provider_id} 已禁用"));
    }
    if provider_config
        .disabled_models
        .iter()
        .any(|d| d == &model_id)
    {
        return Err(format!("模型 {model_id} 已禁用"));
    }
    if !credential.has_any() {
        return Err(format!("Provider {provider_id} 未配置凭据"));
    }
    Ok(ResolvedProvider {
        provider_id,
        model_id,
        descriptor,
        credential,
        base_url,
    })
}

/// 将 ProviderError 映射为 HTTP 状态码（对齐 chat_handler 的 provider_error_status）。
pub fn provider_error_status(error: &ProviderError) -> StatusCode {
    match error {
        ProviderError::MissingCredentials => StatusCode::SERVICE_UNAVAILABLE,
        ProviderError::HttpStatus { status, .. } if status.as_u16() == 429 => {
            StatusCode::TOO_MANY_REQUESTS
        }
        _ => StatusCode::BAD_GATEWAY,
    }
}

/// 当前时间戳（秒），供 chunk created 字段使用。
pub fn now_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}
