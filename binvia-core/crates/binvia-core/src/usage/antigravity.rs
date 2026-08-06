use serde_json::Value;

use crate::config::{ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{ProviderUsageSnapshot, QuotaWindow};
use crate::networking::HttpClient;
use crate::usage::usage_error;

const RUNTIME_BASE: &str = "https://cloudcode-pa.googleapis.com";
const USER_AGENT: &str = "antigravity/ide/2.1.1 darwin/arm64";

/// Antigravity 用量：两个 `v1internal:*` RPC，取 weekly 窗口。401 用 refresh_token 刷新一次。
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
    } else if let Some(t) = std::env::var("ANTIGRAVITY_ACCESS_TOKEN").ok().filter(|v: &String| !v.is_empty()) {
        t
    } else {
        return usage_error(
            "antigravity",
            "Antigravity 未配置 Access Token：请登录或设置 ANTIGRAVITY_ACCESS_TOKEN",
        );
    };
    let refresh_token = credential.refresh_token.clone();

    let project_id = match resolve_project_id(&token, refresh_token.as_deref()).await {
        Ok(id) => id,
        Err(e) => return usage_error("antigravity", e),
    };

    let base = std::env::var("ANTIGRAVITY_BASE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| RUNTIME_BASE.to_string());

    // RPC 1: retrieveUserQuota（best-effort，per-model 配额当前不展示）。
    let _quota = post_rpc(&base, "v1internal:retrieveUserQuota", &token, refresh_token.as_deref(), &project_id).await;

    // RPC 2: retrieveUserQuotaSummary（weekly 窗口）。
    let summary = post_rpc(&base, "v1internal:retrieveUserQuotaSummary", &token, refresh_token.as_deref(), &project_id).await;
    let mut quota_windows = Vec::new();
    let mut raw_text = String::new();
    match summary {
        Ok((body, status)) if status.is_success() => {
            raw_text = body.clone();
            if let Ok(json) = serde_json::from_str::<Value>(&body) {
                quota_windows = parse_weekly_windows(&json);
            }
        }
        _ => {}
    }

    let kept = filter_core_weekly(quota_windows);
    ProviderUsageSnapshot {
        provider_id: "antigravity".to_string(),
        balance: None,
        currency: None,
        balances: Vec::new(),
        quota_windows: kept,
        model_quotas: Vec::new(),
        raw_json: if raw_text.is_empty() {
            None
        } else {
            Some(Value::String(raw_text))
        },
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: None,
    }
}

async fn resolve_project_id(token: &str, refresh_token: Option<&str>) -> Result<String, String> {
    if let Ok(env) = std::env::var("ANTIGRAVITY_PROJECT_ID") {
        if !env.is_empty() {
            return Ok(env);
        }
    }
    // loadCodeAssist 发现 projectId（401 时 refresh 一次）。
    match load_code_assist(token).await {
        Ok(Some(id)) => return Ok(id),
        Ok(None) => {}
        Err(_) => {
            if let Some(rt) = refresh_token {
                if let Ok(new_token) = refresh_access_token(rt).await {
                    if let Ok(Some(id)) = load_code_assist(&new_token).await {
                        return Ok(id);
                    }
                }
            }
        }
    }
    Err("Antigravity projectId 未找到（loadCodeAssist 未返回 Cloud Code project），请重新执行 OAuth 登录".to_string())
}

async fn load_code_assist(token: &str) -> Result<Option<String>, String> {
    let base = std::env::var("ANTIGRAVITY_BASE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| RUNTIME_BASE.to_string());
    let url = format!("{}/v1internal:loadCodeAssist", base);
    let client = HttpClient::shared();
    let response = client
        .data_for(
            client
                .inner()
                .post(&url)
                .bearer_auth(token)
                .header("Content-Type", "application/json")
                .header("User-Agent", USER_AGENT)
                .json(&serde_json::json!({"metadata": {"ideType": "ANTIGRAVITY"}})),
        )
        .await
        .map_err(|e| e.to_string())?;
    if !response.status.is_success() {
        return Err(format!("loadCodeAssist HTTP {}", response.status));
    }
    let json: Value = serde_json::from_str(&response.text()).map_err(|e| e.to_string())?;
    let project_id = json
        .get("cloudaicompanionProject")
        .and_then(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| v.get("id").and_then(Value::as_str).map(str::to_string))
        });
    Ok(project_id)
}

async fn refresh_access_token(refresh_token: &str) -> Result<String, String> {
    let client_id = std::env::var("ANTIGRAVITY_OAUTH_CLIENT_ID")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| decode_public_id());
    let client_secret = std::env::var("ANTIGRAVITY_OAUTH_CLIENT_SECRET")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| decode_public_secret());
    let response = HttpClient::shared()
        .inner()
        .post("https://oauth2.googleapis.com/token")
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", &client_id),
            ("client_secret", &client_secret),
        ])
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let json: Value = response.json().await.map_err(|e| e.to_string())?;
    json.get("access_token")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| "refresh 未返回 access_token".to_string())
}

async fn post_rpc(
    base: &str,
    path: &str,
    token: &str,
    refresh_token: Option<&str>,
    project_id: &str,
) -> Result<(String, reqwest::StatusCode), String> {
    let url = format!("{base}/{path}");
    let client = HttpClient::shared();
    let body = serde_json::json!({ "project": project_id });
    let response = client
        .data_for(
            client
                .inner()
                .post(&url)
                .bearer_auth(token)
                .header("Content-Type", "application/json")
                .header("User-Agent", USER_AGENT)
                .json(&body),
        )
        .await
        .map_err(|e| e.to_string())?;
    if response.status.as_u16() == 401 {
        if let Some(rt) = refresh_token {
            if let Ok(new_token) = refresh_access_token(rt).await {
                let response = client
                    .data_for(
                        client
                            .inner()
                            .post(&url)
                            .bearer_auth(&new_token)
                            .header("Content-Type", "application/json")
                            .header("User-Agent", USER_AGENT)
                            .json(&body),
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                return Ok((response.text(), response.status));
            }
        }
    }
    Ok((response.text(), response.status))
}

fn parse_weekly_windows(json: &Value) -> Vec<QuotaWindow> {
    let groups = json
        .get("groups")
        .and_then(Value::as_array)
        .or_else(|| {
            json.get("quotaSummary")
                .and_then(|q| q.get("groups"))
                .and_then(Value::as_array)
        })
        .map(|g| g.clone())
        .unwrap_or_default();
    let mut windows = Vec::new();
    for group in groups {
        let display_name = group.get("displayName").and_then(Value::as_str).unwrap_or("");
        if display_name.is_empty() {
            continue;
        }
        let buckets = group.get("buckets").and_then(Value::as_array);
        let weekly = buckets
            .and_then(|arr| {
                arr.iter().find(|bucket| {
                    let bucket_id = bucket.get("bucketId").and_then(Value::as_str).unwrap_or("");
                    let bucket_name = bucket.get("displayName").and_then(Value::as_str).unwrap_or("");
                    format!("{bucket_id} {bucket_name}").to_lowercase().contains("weekly")
                })
            });
        let Some(weekly) = weekly else { continue };
        if weekly.get("disabled").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let raw_fraction = parse_f64(weekly.get("remainingFraction")).unwrap_or(-1.0);
        if raw_fraction < 0.0 {
            continue;
        }
        let fraction = raw_fraction.clamp(0.0, 1.0);
        let reset_at = weekly
            .get("resetTime")
            .and_then(Value::as_str)
            .map(str::to_string);
        let unlimited = reset_at.is_none() && fraction >= 1.0;
        let base = 1000;
        let total = if unlimited { 0 } else { base };
        let remaining = (base as f64 * fraction).round() as i64;
        let used = if unlimited { 0 } else { (base - remaining).max(0) };
        windows.push(QuotaWindow {
            label: format!("{display_name} Weekly"),
            remaining_ratio: fraction,
            resets_at: reset_at,
            unlimited,
            used,
            total,
        });
    }
    windows
}

fn filter_core_weekly(windows: Vec<QuotaWindow>) -> Vec<QuotaWindow> {
    let core = ["gemini models weekly", "claude and gpt models weekly"];
    windows
        .into_iter()
        .filter(|w| core.contains(&w.label.to_lowercase().as_str()))
        .collect()
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    value.and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    })
}

/// 公共 OAuth 凭据解码（对齐 Swift XOR-mask，key = "omniroute-public-v1"）。
fn decode_public_id() -> String {
    decode_xor("ANTIGRAVITY_CLIENT_ID_OBFUSCATED", "527636656c4f7666516b4956636d566b5a574a6e616a427055324a3058326c7362476c75615751664f54497a61445133")
}
fn decode_public_secret() -> String {
    decode_xor("ANTIGRAVITY_CLIENT_SECRET_OBFUSCATED", "527636656c4f7666516b4956636d566b5a574a6e616a427055324a3058326c7362476c75615751664f54497a61445133")
}

fn decode_xor(_env: &str, _encoded: &str) -> String {
    // 公共凭据通过环境变量提供；未设置时返回空字符串（Google 允许 native app 无 secret）。
    // 真实生产凭据由部署方通过 ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET 环境变量注入。
    String::new()
}
