use crate::config::{ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::ProviderUsageSnapshot;

pub mod antigravity;
pub mod codebuddy_cn;
pub mod codex;
pub mod cursor;
pub mod deepseek;
pub mod kimi;
pub mod opencode_go;

/// 按 provider id 分发用量抓取。无 fetcher 或抓取失败均返回带 `error` 的快照，不抛错。
pub async fn fetch_usage(
    provider_id: &str,
    provider_config: &ProviderConfig,
    credential: &ProviderCredential,
) -> ProviderUsageSnapshot {
    let result = match provider_id {
        "deepseek" => deepseek::fetch(credential, provider_config).await,
        "codebuddy-cn" => codebuddy_cn::fetch(credential, provider_config).await,
        "antigravity" => antigravity::fetch(credential, provider_config).await,
        "kimi" => kimi::fetch(credential, provider_config).await,
        "opencode-go" => opencode_go::fetch(credential, provider_config).await,
        "codex" => codex::fetch(credential, provider_config).await,
        "cursor" => cursor::fetch(credential, provider_config).await,
        other => error_snapshot(other, &format!("{other} 暂不支持用量查询")),
    };
    result
}

fn error_snapshot(provider_id: &str, message: impl Into<String>) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot {
        provider_id: provider_id.to_string(),
        balance: None,
        currency: None,
        balances: Vec::new(),
        quota_windows: Vec::new(),
        model_quotas: Vec::new(),
        raw_json: None,
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: Some(message.into()),
    }
}

/// 用于 fetcher 内部失败时构造错误快照。
pub(crate) fn usage_error(provider_id: &str, message: impl Into<String>) -> ProviderUsageSnapshot {
    error_snapshot(provider_id, message)
}
