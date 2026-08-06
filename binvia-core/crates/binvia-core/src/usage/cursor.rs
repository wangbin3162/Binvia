use serde_json::Value;

use crate::config::{ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{ProviderUsageSnapshot, QuotaWindow};
use crate::networking::HttpClient;
use crate::usage::usage_error;

/// Cursor 用量：`POST cursor.com/api/dashboard/get-current-period-usage`，Cookie 鉴权。
pub async fn fetch(
    credential: &ProviderCredential,
    _provider_config: &ProviderConfig,
) -> ProviderUsageSnapshot {
    let token: String = if let Some(t) = credential
        .access_token
        .as_deref()
        .filter(|v| !v.is_empty())
    {
        t.to_string()
    } else if let Some(t) = std::env::var("CURSOR_TOKEN").ok().filter(|v: &String| !v.is_empty()) {
        t
    } else {
        return usage_error(
            "cursor",
            "Cursor 未配置 Access Token：请在设置中填写 accessToken 或设置 CURSOR_TOKEN",
        );
    };

    let url = std::env::var("CURSOR_USAGE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "https://cursor.com/api/dashboard/get-current-period-usage".to_string());

    // Cookie: WorkosCursorSessionToken=<userId>::<token>（token 含 :: 时取最后段为 JWT，userId 从 JWT sub 解析）。
    let (user_id, jwt) = split_token(&token);
    let cookie = format!("WorkosCursorSessionToken={user_id}::{jwt}");

    let client = HttpClient::shared();
    let response = match client
        .data_for(
            client
                .inner()
                .post(&url)
                .header("Content-Type", "application/json")
                .header("Cookie", &cookie)
                .header("Origin", "https://cursor.com")
                .header("Referer", "https://cursor.com/dashboard/spending")
                .header("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36")
                .body("{}"),
        )
        .await
    {
        Ok(r) => r,
        Err(e) => return usage_error("cursor", format!("请求失败：{e}")),
    };
    if response.status.as_u16() == 401 || response.status.as_u16() == 403 {
        return usage_error("cursor", "Cursor 会话未授权，请重新获取 Token");
    }
    if !response.status.is_success() {
        return usage_error("cursor", format!("用量接口错误 ({})", response.status));
    }

    let raw = response.text();
    let json: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(_) => return usage_error("cursor", "用量响应非 JSON"),
    };
    let plan_usage = match json.get("planUsage") {
        Some(p) => p,
        None => return usage_error("cursor", "用量响应缺少 planUsage"),
    };

    let billing_cycle_end = parse_f64(plan_usage.get("billingCycleEnd")).unwrap_or(0.0);
    let reset_at = if billing_cycle_end > 0.0 {
        let seconds = if billing_cycle_end > 1e11 {
            billing_cycle_end / 1000.0
        } else {
            billing_cycle_end
        };
        chrono::DateTime::from_timestamp(seconds as i64, 0).map(|d| d.to_rfc3339())
    } else {
        None
    };

    let mut windows = Vec::new();
    for (label, key) in [
        ("总用量", "totalPercentUsed"),
        ("Auto + Composer", "autoPercentUsed"),
        ("API", "apiPercentUsed"),
    ] {
        if let Some(percent) = parse_f64(plan_usage.get(key)) {
            let used = percent.clamp(0.0, 100.0);
            let remaining = (1.0 - used / 100.0).clamp(0.0, 1.0);
            windows.push(QuotaWindow {
                label: label.to_string(),
                remaining_ratio: remaining,
                resets_at: reset_at.clone(),
                unlimited: false,
                used: used.round() as i64,
                total: 100,
            });
        }
    }

    if windows.is_empty() {
        return usage_error("cursor", "用量响应缺少百分比字段");
    }

    ProviderUsageSnapshot {
        provider_id: "cursor".to_string(),
        balance: None,
        currency: None,
        balances: Vec::new(),
        quota_windows: windows,
        model_quotas: Vec::new(),
        raw_json: Some(Value::String(raw)),
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: None,
    }
}

/// 拆分 `userId::jwt`；无分隔符则从 JWT payload `sub` 解析 userId。
fn split_token(token: &str) -> (String, String) {
    if let Some((user, jwt)) = token.rsplit_once("::") {
        return (user.to_string(), jwt.to_string());
    }
    // 解码 JWT payload（中段）取 sub。
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() >= 2 {
        if let Ok(payload) = base64url_decode(parts[1]) {
            if let Ok(json) = serde_json::from_str::<Value>(&payload) {
                if let Some(sub) = json.get("sub").and_then(Value::as_str) {
                    return (sub.to_string(), token.to_string());
                }
            }
        }
    }
    ("unknown".to_string(), token.to_string())
}

fn base64url_decode(input: &str) -> Result<String, String> {
    use base64::Engine;
    let engine = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let bytes = engine
        .decode(input)
        .map_err(|e| e.to_string())?;
    String::from_utf8(bytes).map_err(|e| e.to_string())
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    value.and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    })
}
