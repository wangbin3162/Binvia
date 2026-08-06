use serde_json::Value;

use crate::config::{ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{ProviderUsageSnapshot, QuotaWindow};
use crate::networking::HttpClient;
use crate::usage::usage_error;

/// CodeBuddy CN 积分查询：`POST www.codebuddy.cn/billing/meter/get-enterprise-user-usage`。
/// 需 `x-enterprise-id`（`credential.workspace_id` 或 `CODEBUDDY_CN_ENTERPRISE_ID`）。
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
    } else if let Some(t) = std::env::var("CODEBUDDY_CN_ACCESS_TOKEN").ok().filter(|v: &String| !v.is_empty()) {
        t
    } else {
        return usage_error(
            "codebuddy-cn",
            "CodeBuddy CN 未配置 Access Token：请登录或设置 CODEBUDDY_CN_ACCESS_TOKEN",
        );
    };

    let enterprise_id = std::env::var("CODEBUDDY_CN_ENTERPRISE_ID")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| {
            credential
                .workspace_id
                .as_deref()
                .filter(|v| !v.is_empty())
                .map(str::to_string)
        });
    let Some(enterprise_id) = enterprise_id else {
        return usage_error(
            "codebuddy-cn",
            "CodeBuddy CN 积分查询缺少企业 ID：请在设置中填写企业 ID（workspaceId），或设置 CODEBUDDY_CN_ENTERPRISE_ID 环境变量（可从 www.codebuddy.cn 控制台请求头 x-enterprise-id 获取）",
        );
    };

    let url = std::env::var("CODEBUDDY_CN_USAGE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            "https://www.codebuddy.cn/billing/meter/get-enterprise-user-usage".to_string()
        });

    let client = HttpClient::shared();
    let response = match client
        .data_for(
            client
                .inner()
                .post(&url)
                .bearer_auth(&token)
                .header("Content-Type", "application/json")
                .header("Accept", "application/json")
                .header("x-client-platform", "web")
                .header("x-enterprise-id", &enterprise_id)
                .body("{}"),
        )
        .await
    {
        Ok(r) => r,
        Err(e) => return usage_error("codebuddy-cn", format!("请求失败：{e}")),
    };

    if response.status.as_u16() == 401 || response.status.as_u16() == 403 {
        return usage_error(
            "codebuddy-cn",
            "CodeBuddy CN 登录已失效，请重新登录获取新的 Access Token",
        );
    }
    if !response.status.is_success() {
        return usage_error(
            "codebuddy-cn",
            format!("积分接口错误 ({})：{}", response.status, compact(&response.text())),
        );
    }

    let raw = response.text();
    let json: Value = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(_) => return usage_error("codebuddy-cn", "积分响应非 JSON"),
    };

    if let Some(code) = parse_f64(json.get("code")) {
        if code != 0.0 {
            let msg = json
                .get("msg")
                .and_then(Value::as_str)
                .or_else(|| json.get("message").and_then(Value::as_str))
                .unwrap_or("unknown");
            return usage_error("codebuddy-cn", format!("积分接口错误: {msg}"));
        }
    }

    let data = match json.get("data") {
        Some(d) => d,
        None => return usage_error("codebuddy-cn", "积分响应缺少 data"),
    };
    let credit = match parse_f64(data.get("credit")) {
        Some(v) => v,
        None => return usage_error("codebuddy-cn", "积分响应缺少 credit"),
    };
    let limit_num = match parse_f64(data.get("limitNum")) {
        Some(v) if v > 0.0 => v,
        _ => return usage_error("codebuddy-cn", "积分响应缺少 limitNum"),
    };
    let remaining = (limit_num - credit).max(0.0);
    let fraction = (remaining / limit_num).clamp(0.0, 1.0);
    let reset_at = data
        .get("cycleResetTime")
        .and_then(Value::as_str)
        .map(str::to_string);

    ProviderUsageSnapshot {
        provider_id: "codebuddy-cn".to_string(),
        balance: None,
        currency: None,
        balances: Vec::new(),
        quota_windows: vec![QuotaWindow {
            label: "积分".to_string(),
            remaining_ratio: fraction,
            resets_at: reset_at,
            unlimited: false,
            used: credit.round() as i64,
            total: limit_num.round() as i64,
        }],
        model_quotas: Vec::new(),
        raw_json: Some(Value::String(raw)),
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: None,
    }
}

fn compact(text: &str) -> String {
    let joined: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if joined.chars().count() <= 160 {
        joined
    } else {
        let prefix: String = joined.chars().take(157).collect();
        format!("{prefix}...")
    }
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    value.and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    })
}
