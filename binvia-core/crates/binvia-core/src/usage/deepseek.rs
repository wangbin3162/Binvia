use serde_json::Value;

use crate::config::{KeyedToken, ProviderConfig, ProviderCredential};
use crate::monitor::usage_cache::{KeyedBalance, ProviderUsageSnapshot};
use crate::networking::HttpClient;
use crate::usage::usage_error;

/// DeepSeek 余额查询：`GET {base}/user/balance`，多 key 并发。
/// base 默认 `https://api.deepseek.com/v1`，`DEEPSEEK_BASE_URL` 覆盖。
pub async fn fetch(
    credential: &ProviderCredential,
    provider_config: &ProviderConfig,
) -> ProviderUsageSnapshot {
    let keys = resolve_keys(credential, provider_config);
    if keys.is_empty() {
        return usage_error(
            "deepseek",
            "DeepSeek 未配置 API Key：请设置 providers.deepseek.credential.apiKey 或 apiKeys，或 DEEPSEEK_API_KEY 环境变量",
        );
    }

    let base = std::env::var("DEEPSEEK_BASE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "https://api.deepseek.com/v1".to_string());
    let url = format!("{}/user/balance", base.trim_end_matches('/'));

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
    let mut first_currency: Option<String> = None;
    let mut raw_first: Option<String> = None;
    let mut last_error: Option<String> = None;
    for task in tasks {
        match task.await {
            Ok((key, Ok((balance, currency, raw)))) => {
                balances.push(KeyedBalance {
                    label: key.label,
                    balance,
                    currency: currency.clone().unwrap_or_else(|| "CNY".to_string()),
                });
                if first_balance.is_none() {
                    first_balance = Some(balance);
                    first_currency = currency;
                    raw_first = Some(raw);
                }
            }
            Ok((key, Err(message))) => {
                last_error = Some(format!("Key {} 余额查询失败：{}", key.label, message));
            }
            Err(_) => {
                last_error = Some("DeepSeek 余额查询任务异常".to_string());
            }
        }
    }

    if balances.is_empty() {
        return usage_error(
            "deepseek",
            last_error.unwrap_or_else(|| "DeepSeek 余额查询失败".to_string()),
        );
    }

    ProviderUsageSnapshot {
        provider_id: "deepseek".to_string(),
        balance: first_balance,
        currency: first_currency,
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
) -> Result<(f64, Option<String>, String), String> {
    let response = client
        .data_for(client.inner().get(url).bearer_auth(key))
        .await
        .map_err(|e| e.to_string())?;
    if !response.status.is_success() {
        return Err(format!("HTTP {}", response.status));
    }
    let raw = response.text();
    let json: Value = serde_json::from_str(&raw).map_err(|e| format!("响应非 JSON: {e}"))?;
    let infos = json
        .get("balance_infos")
        .and_then(Value::as_array)
        .ok_or_else(|| "响应缺少 balance_infos".to_string())?;
    let first = infos
        .first()
        .ok_or_else(|| "balance_infos 为空".to_string())?;
    let balance = parse_f64(first.get("total_balance"))
        .or_else(|| parse_f64(first.get("granted_balance")))
        .ok_or_else(|| "缺少 total_balance".to_string())?;
    let currency = first
        .get("currency")
        .and_then(Value::as_str)
        .map(str::to_string);
    Ok((balance, currency, raw))
}

fn parse_f64(value: Option<&Value>) -> Option<f64> {
    value.and_then(|v| {
        v.as_f64()
            .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_keys_prefers_configured_labels() {
        let mut provider_config = ProviderConfig::default();
        provider_config.api_keys = vec![
            KeyedToken {
                label: "primary".to_string(),
                value: "sk-primary-1234567890".to_string(),
            },
            KeyedToken {
                label: "  ".to_string(),
                value: "sk-secondary-1234567890".to_string(),
            },
        ];
        let credential = ProviderCredential {
            api_key: Some("sk-primary-1234567890".to_string()),
            ..ProviderCredential::default()
        };
        let keys = resolve_keys(&credential, &provider_config);
        assert_eq!(keys.len(), 2);
        assert_eq!(keys[0].label, "primary");
        // 空 label 回退掩码。
        assert!(keys[1].label.contains("••••"));
    }

    #[test]
    fn masked_key_short_value() {
        assert_eq!(masked_key("abc"), "abc••••");
        assert_eq!(masked_key("sk-1234567890abcdef"), "sk-123••••cdef");
    }
}
