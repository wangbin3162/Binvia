use axum::http::HeaderMap;
use serde_json::{Map, Value};

use crate::monitor::TokenUsage;

fn number(object: &Map<String, Value>, names: &[&str]) -> Option<u32> {
    names.iter().find_map(|name| {
        object
            .get(*name)
            .and_then(Value::as_u64)
            .and_then(|value| u32::try_from(value).ok())
    })
}

fn parse_usage_object(value: &Value) -> Option<TokenUsage> {
    let object = value.as_object()?;
    let prompt_tokens = number(object, &["prompt_tokens", "input_tokens"])?;
    let completion_tokens = number(object, &["completion_tokens", "output_tokens"])?;
    let total_tokens = number(object, &["total_tokens"])
        .or_else(|| prompt_tokens.checked_add(completion_tokens))?;

    Some(TokenUsage {
        prompt_tokens,
        completion_tokens,
        total_tokens,
    })
}

pub fn extract_from_json(value: &Value) -> Option<TokenUsage> {
    value
        .get("usage")
        .and_then(parse_usage_object)
        .or_else(|| parse_usage_object(value))
}

pub fn extract_from_sse(body: &[u8]) -> Option<TokenUsage> {
    let text = String::from_utf8_lossy(body).replace("\r\n", "\n");
    let mut usage = None;

    for event in text.split("\n\n") {
        let data = event
            .lines()
            .filter_map(|line| line.strip_prefix("data:"))
            .map(str::trim_start)
            .collect::<Vec<_>>()
            .join("\n");
        if data.is_empty() || data == "[DONE]" {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&data) {
            usage = extract_from_json(&value).or(usage);
        }
    }

    usage
}

fn header_number(headers: &HeaderMap, names: &[&str]) -> Option<u32> {
    names.iter().find_map(|name| {
        headers
            .get(*name)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<u64>().ok())
            .and_then(|value| u32::try_from(value).ok())
    })
}

pub fn extract_from_headers(headers: &HeaderMap) -> Option<TokenUsage> {
    for name in ["x-usage", "x-token-usage", "x-openai-usage"] {
        if let Some(value) = headers.get(name).and_then(|value| value.to_str().ok()) {
            if let Ok(json) = serde_json::from_str::<Value>(value) {
                if let Some(usage) = extract_from_json(&json) {
                    return Some(usage);
                }
            }
        }
    }

    let prompt_tokens = header_number(
        headers,
        &["x-prompt-tokens", "x-usage-prompt-tokens", "x-input-tokens"],
    )?;
    let completion_tokens = header_number(
        headers,
        &[
            "x-completion-tokens",
            "x-usage-completion-tokens",
            "x-output-tokens",
        ],
    )?;
    let total_tokens = header_number(headers, &["x-total-tokens", "x-usage-total-tokens"])
        .or_else(|| prompt_tokens.checked_add(completion_tokens))?;

    Some(TokenUsage {
        prompt_tokens,
        completion_tokens,
        total_tokens,
    })
}

pub fn estimate_tokens(text: &str) -> u32 {
    let characters = u32::try_from(text.chars().count()).unwrap_or(u32::MAX);
    characters.div_ceil(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_json_usage_without_estimation() {
        let value = serde_json::json!({
            "usage": {
                "prompt_tokens": 12,
                "completion_tokens": 8,
                "total_tokens": 20
            }
        });

        assert_eq!(extract_from_json(&value).unwrap().total_tokens, 20);
        assert_eq!(estimate_tokens("12345"), 2);
    }

    #[test]
    fn extracts_last_sse_usage() {
        let body = br#"data: {"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}

data: [DONE]

"#;

        assert_eq!(extract_from_sse(body).unwrap().total_tokens, 3);
    }
}
