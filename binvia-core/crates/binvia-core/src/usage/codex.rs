use serde_json::Value;

use crate::config::{ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{ProviderUsageSnapshot, QuotaWindow};
use crate::networking::HttpClient;
use crate::usage::usage_error;

/// Codex 用量：`GET {base}/backend-api/wham/usage`。401 用 refresh_token 刷新一次。
pub async fn fetch(
    credential: &ProviderCredential,
    _provider_config: &ProviderConfig,
) -> ProviderUsageSnapshot {
    let token = match credential
        .access_token
        .as_deref()
        .filter(|v| !v.is_empty())
    {
        Some(t) => t.to_string(),
        None => {
            return usage_error(
                "codex",
                "Codex 未配置 Access Token：请登录或设置 CODEX_ACCESS_TOKEN",
            );
        }
    };
    let refresh_token = credential.refresh_token.clone();
    let workspace_id = credential.workspace_id.clone();

    let base = std::env::var("CODEX_BASE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "https://chatgpt.com".to_string());
    let url = format!("{}/backend-api/wham/usage", base.trim_end_matches('/'));

    let (body, status) = match fetch_usage(&url, &token, workspace_id.as_deref()).await {
        Ok(v) => v,
        Err(e) => return usage_error("codex", e),
    };
    if status.as_u16() == 401 {
        if let Some(rt) = refresh_token.as_deref() {
            match crate::oauth::refresh_codex_token(rt).await {
                Ok(new_token) => {
                    if let Ok((body, status)) = fetch_usage(&url, &new_token, workspace_id.as_deref()).await {
                        return parse_or_error(&body, status);
                    }
                }
                Err(e) => return usage_error("codex", format!("刷新 token 失败：{e}")),
            }
        }
        return usage_error("codex", "Codex 登录已失效，请重新登录");
    }
    parse_or_error(&body, status)
}

async fn fetch_usage(
    url: &str,
    token: &str,
    workspace_id: Option<&str>,
) -> Result<(String, reqwest::StatusCode), String> {
    let client = HttpClient::shared();
    let mut builder = client
        .inner()
        .get(url)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .header("User-Agent", "codex-cli/0.144.1");
    if let Some(ws) = workspace_id {
        builder = builder.header("chatgpt-account-id", ws);
    }
    let response = client.data_for(builder).await.map_err(|e| e.to_string())?;
    Ok((response.text(), response.status))
}

fn parse_or_error(body: &str, status: reqwest::StatusCode) -> ProviderUsageSnapshot {
    if !status.is_success() {
        return usage_error("codex", format!("用量接口错误 ({})", status));
    }
    let json: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return usage_error("codex", "用量响应非 JSON"),
    };
    let mut windows = Vec::new();
    for key in ["primary_window", "secondary_window", "primaryWindow", "secondaryWindow"] {
        if let Some(window) = json.get(key) {
            if let Some(w) = parse_window(window, key) {
                windows.push(w);
            }
        }
    }
    if let Some(rate_limit) = json.get("rate_limit") {
        for key in ["primary_window", "secondary_window", "primaryWindow", "secondaryWindow"] {
            if let Some(window) = rate_limit.get(key) {
                if let Some(w) = parse_window(window, key) {
                    windows.push(w);
                }
            }
        }
    }
    if windows.is_empty() {
        return usage_error("codex", "用量响应缺少 rate_limit 窗口");
    }
    ProviderUsageSnapshot {
        provider_id: "codex".to_string(),
        balance: None,
        currency: None,
        balances: Vec::new(),
        quota_windows: windows,
        model_quotas: Vec::new(),
        raw_json: Some(Value::String(body.to_string())),
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: None,
    }
}

fn parse_window(window: &Value, key: &str) -> Option<QuotaWindow> {
    let used_percent = parse_f64(window.get("used_percent"))?;
    let limit_seconds = parse_f64(window.get("limit_window_seconds")).unwrap_or(0.0);
    let reset_after = parse_f64(window.get("reset_after_seconds")).unwrap_or(0.0);
    // 跳过 latent 窗口（未用且重置时间接近周期长度）。
    if used_percent == 0.0 && reset_after >= limit_seconds && limit_seconds > 0.0 {
        return None;
    }
    let limit_reached = window
        .get("limit_reached")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let used_fraction = if limit_reached { 1.0 } else { used_percent / 100.0 };
    let remaining = (1.0 - used_fraction.clamp(0.0, 1.0)).clamp(0.0, 1.0);
    let label = if limit_seconds >= 20.0 * 86400.0 {
        "Monthly".to_string()
    } else if limit_seconds >= 6.0 * 86400.0 {
        "Weekly".to_string()
    } else if limit_seconds > 0.0 && limit_seconds <= 6.0 * 3600.0 {
        "5h".to_string()
    } else {
        key.to_string()
    };
    let total = 100;
    let used = (used_fraction * 100.0).round() as i64;
    let reset_at = window
        .get("reset_at")
        .and_then(Value::as_f64)
        .map(|ts| {
            let seconds = if ts > 1e12 { ts / 1000.0 } else { ts };
            chrono::DateTime::from_timestamp(seconds as i64, 0).map(|d| d.to_rfc3339())
        })
        .unwrap_or_else(|| {
            if reset_after > 0.0 {
                let now = chrono::Utc::now().timestamp() as f64 + reset_after;
                chrono::DateTime::from_timestamp(now as i64, 0).map(|d| d.to_rfc3339())
            } else {
                None
            }
        });
    Some(QuotaWindow {
        label,
        remaining_ratio: remaining,
        resets_at: reset_at,
        unlimited: false,
        used,
        total,
    })
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    value.and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    })
}
