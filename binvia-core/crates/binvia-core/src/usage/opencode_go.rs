use serde_json::Value;

use crate::config::{ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{ProviderUsageSnapshot, QuotaWindow};
use crate::networking::HttpClient;
use crate::usage::usage_error;

/// OpenCode Go 配额查询：`GET {base}/quota`，5h/周/月三窗口。非 2xx → 错误快照（不抛）。
pub async fn fetch(
    credential: &ProviderCredential,
    _provider_config: &ProviderConfig,
) -> ProviderUsageSnapshot {
    let token: String = if let Some(t) = credential.api_key.as_deref().filter(|v| !v.is_empty()) {
        t.to_string()
    } else if let Some(t) = std::env::var("OPENCODE_GO_API_KEY").ok().filter(|v: &String| !v.is_empty()) {
        t
    } else {
        return usage_error(
            "opencode-go",
            "OpenCode Go 未配置 API Key：请设置 providers.opencode-go.credential.apiKey 或 OPENCODE_GO_API_KEY",
        );
    };

    let url = std::env::var("OPENCODE_GO_QUOTA_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            let base = std::env::var("OPENCODE_GO_BASE_URL")
                .ok()
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| "https://opencode.ai/zen/go/v1".to_string());
            format!("{}/quota", base.trim_end_matches('/'))
        });

    let client = HttpClient::shared();
    let response = match client
        .data_for(client.inner().get(&url).bearer_auth(&token))
        .await
    {
        Ok(r) => r,
        Err(e) => return usage_error("opencode-go", format!("请求失败：{e}")),
    };
    if !response.status.is_success() {
        return usage_error(
            "opencode-go",
            format!("配额接口错误 ({})", response.status),
        );
    }

    let raw = response.text();
    let json: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(_) => return usage_error("opencode-go", "配额响应非 JSON"),
    };
    let container = json
        .get("quota")
        .or_else(|| json.get("data"))
        .or_else(|| json.get("usage"))
        .unwrap_or(&json);

    let windows = [
        ("$12 / 5小时", &["window_5h", "5h", "hourly", "short"][..]),
        ("$30 / 周", &["window_weekly", "weekly", "week", "wk"][..]),
        ("$60 / 月", &["window_monthly", "monthly", "month", "mo"][..]),
    ];
    let mut quota_windows = Vec::new();
    for (label, keys) in windows {
        let Some(value) = keys.iter().find_map(|k| container.get(*k)) else {
            continue;
        };
        let used = parse_f64(value.get("used"))
            .or_else(|| parse_f64(value.get("used_amount")))
            .unwrap_or(0.0);
        let limit = parse_f64(value.get("limit"))
            .or_else(|| parse_f64(value.get("limit_amount")))
            .unwrap_or(0.0);
        if limit <= 0.0 {
            continue;
        }
        let fraction = (1.0 - (used / limit).clamp(0.0, 1.0)).clamp(0.0, 1.0);
        let reset_at = value
            .get("reset_at")
            .and_then(Value::as_f64)
            .map(|ts| timestamp_to_rfc3339(ts))
            .or_else(|| {
                value
                    .get("reset_after_seconds")
                    .and_then(Value::as_f64)
                    .map(|s| {
                        let now = chrono::Utc::now().timestamp() as f64 + s;
                        chrono::DateTime::from_timestamp(now as i64, 0)
                            .map(|d| d.to_rfc3339())
                            .unwrap_or_default()
                    })
            });
        quota_windows.push(QuotaWindow {
            label: label.to_string(),
            remaining_ratio: fraction,
            resets_at: reset_at,
            unlimited: false,
            used: used.round() as i64,
            total: limit.round() as i64,
        });
    }

    if quota_windows.is_empty() {
        return usage_error("opencode-go", "配额响应无可识别窗口");
    }

    ProviderUsageSnapshot {
        provider_id: "opencode-go".to_string(),
        balance: None,
        currency: None,
        balances: Vec::new(),
        quota_windows,
        model_quotas: Vec::new(),
        raw_json: Some(Value::String(raw)),
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: None,
    }
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    value.and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    })
}

fn timestamp_to_rfc3339(ts: f64) -> String {
    let seconds = if ts > 1e12 { ts / 1000.0 } else { ts };
    chrono::DateTime::from_timestamp(seconds as i64, 0)
        .map(|d| d.to_rfc3339())
        .unwrap_or_default()
}
