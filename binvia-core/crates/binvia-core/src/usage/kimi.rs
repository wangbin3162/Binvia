use serde_json::Value;

use crate::config::{KeyedToken, ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{KeyedBalance, ProviderUsageSnapshot};
use crate::networking::HttpClient;
use crate::usage::usage_error;

/// Kimi 余额查询：`GET {base}/users/me/balance`，多 key 并发。
/// base 默认 `https://api.moonshot.cn/v1`，`KIMI_BASE_URL` / `MOONSHOT_BASE_URL` 覆盖。
pub async fn fetch(
    credential: &ProviderCredential,
    provider_config: &ProviderConfig,
) -> ProviderUsageSnapshot {
    let keys = resolve_keys(credential, provider_config);
    if keys.is_empty() {
        return usage_error(
            "kimi",
            "Kimi 未配置 API Key：请设置 providers.kimi.credential.apiKey 或 apiKeys，或 KIMI_API_KEY 环境变量",
        );
    }

    let base = std::env::var("KIMI_BASE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| {
            std::env::var("MOONSHOT_BASE_URL")
                .ok()
                .filter(|v| !v.is_empty())
        })
        .unwrap_or_else(|| "https://api.moonshot.cn/v1".to_string());
    let url = format!("{}/users/me/balance", base.trim_end_matches('/'));

    let client = HttpClient::shared();
    let mut tasks = Vec::with_capacity(keys.len());
    for key in keys.clone() {
        let url = url.clone();
        tasks.push(tokio::spawn(async move {
            let result = fetch_balance(&client, &url, &key.value).await;
            (key, result)
        }));
    }

    let mut balances = Vec::new();
    let mut first_balance: Option<f64> = None;
    let mut raw_first: Option<String> = None;
    let mut last_error: Option<String> = None;
    for task in tasks {
        match task.await {
            Ok((key, Ok((balance, raw)))) => {
                balances.push(KeyedBalance {
                    label: key.label,
                    balance,
                    currency: "CNY".to_string(),
                });
                if first_balance.is_none() {
                    first_balance = Some(balance);
                    raw_first = Some(raw);
                }
            }
            Ok((key, Err(message))) => {
                last_error = Some(format!("Key {} 余额查询失败：{message}", key.label));
            }
            Err(_) => last_error = Some("Kimi 余额查询任务异常".to_string()),
        }
    }

    if balances.is_empty() {
        return usage_error(
            "kimi",
            last_error.unwrap_or_else(|| "Kimi 余额查询失败".to_string()),
        );
    }

    ProviderUsageSnapshot {
        provider_id: "kimi".to_string(),
        balance: first_balance,
        currency: Some("CNY".to_string()),
        balances,
        quota_windows: Vec::new(),
        model_quotas: Vec::new(),
        raw_json: raw_first.map(Value::String),
        fetched_at: chrono::Utc::now().to_rfc3339(),
        error: None,
    }
}

fn resolve_keys(
    credential: &ProviderCredential,
    provider_config: &ProviderConfig,
) -> Vec<KeyedToken> {
    let mut tokens = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for token in &provider_config.api_keys {
        let value = token.value.trim().to_string();
        if value.is_empty() {
            continue;
        }
        if seen.insert(value.clone()) {
            tokens.push(KeyedToken {
                label: if token.label.trim().is_empty() {
                    masked_key(&value)
                } else {
                    token.label.trim().to_string()
                },
                value,
            });
        }
    }
    if let Some(api_key) = credential.api_key.as_deref() {
        let value = api_key.trim().to_string();
        if !value.is_empty() && seen.insert(value.clone()) {
            tokens.push(KeyedToken {
                label: masked_key(&value),
                value,
            });
        }
    }
    tokens
}

fn masked_key(key: &str) -> String {
    if key.len() <= 10 {
        format!("{}••••", &key[..key.len().min(3)])
    } else {
        format!("{}••••{}", &key[..6], &key[key.len() - 4..])
    }
}

async fn fetch_balance(
    client: &HttpClient,
    url: &str,
    key: &str,
) -> Result<(f64, String), String> {
    let response = client
        .data_for(client.inner().get(url).bearer_auth(key))
        .await
        .map_err(|e| e.to_string())?;
    if !response.status.is_success() {
        return Err(format!("HTTP {}", response.status));
    }
    let raw = response.text();
    let json: Value = serde_json::from_str(&raw).map_err(|e| format!("响应非 JSON: {e}"))?;
    if let Some(code) = json.get("code").and_then(Value::as_f64) {
        if code != 0.0 {
            let msg = json
                .get("msg")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            return Err(format!("业务错误: {msg}"));
        }
    }
    let data = json.get("data").unwrap_or(&json);
    let balance = data
        .get("available_balance")
        .or_else(|| data.get("cash_balance"))
        .and_then(|v| {
            v.as_f64()
                .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
        })
        .ok_or_else(|| "缺少 available_balance".to_string())?;
    Ok((balance, raw))
}
