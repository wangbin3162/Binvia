use std::collections::HashMap;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

use chrono::Utc;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub total_tokens: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestLogEntry {
    pub id: String,
    pub timestamp: String,
    pub method: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "providerID")]
    pub provider_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(rename = "statusCode")]
    pub status_code: u16,
    #[serde(rename = "durationMS")]
    pub duration_ms: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tokens: Option<TokenUsage>,
}

impl RequestLogEntry {
    pub fn new(
        method: String,
        path: String,
        provider_id: Option<String>,
        model: Option<String>,
        status_code: u16,
        duration_ms: f64,
        error: Option<String>,
        tokens: Option<TokenUsage>,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            timestamp: Utc::now().to_rfc3339(),
            method,
            path,
            provider_id,
            model,
            status_code,
            duration_ms,
            error,
            tokens,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsageSummary {
    pub total_requests: u64,
    pub total_errors: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    pub total_requests: u64,
    pub total_errors: u64,
    pub prompt_tokens: u64,
    pub completion_tokens: u64,
    pub total_tokens: u64,
    pub by_provider: HashMap<String, ProviderUsageSummary>,
}

#[derive(Debug)]
pub struct RequestLogger {
    buffer: Arc<Mutex<VecDeque<RequestLogEntry>>>,
    max_entries: usize,
}

impl RequestLogger {
    pub fn new() -> Self {
        Self {
            buffer: Arc::new(Mutex::new(VecDeque::new())),
            max_entries: 10_000,
        }
    }

    pub fn append(&self, entry: RequestLogEntry) {
        let mut buf = self.buffer.lock().unwrap();
        if buf.len() >= self.max_entries {
            buf.pop_front();
        }
        buf.push_back(entry);
    }

    pub fn entries(&self, limit: usize) -> Vec<RequestLogEntry> {
        let buf = self.buffer.lock().unwrap();
        let limit = limit.min(buf.len());
        buf.iter().rev().take(limit).cloned().collect()
    }

    pub fn summary(&self) -> UsageSummary {
        let buf = self.buffer.lock().unwrap();
        let mut total_requests: u64 = 0;
        let mut total_errors: u64 = 0;
        let mut prompt_tokens: u64 = 0;
        let mut completion_tokens: u64 = 0;
        let mut total_tokens: u64 = 0;
        let mut by_provider: HashMap<String, ProviderUsageSummary> = HashMap::new();

        for entry in buf.iter() {
            total_requests += 1;
            if entry.status_code >= 400 || entry.error.is_some() {
                total_errors += 1;
            }
            if let Some(ref tokens) = entry.tokens {
                prompt_tokens += tokens.prompt_tokens as u64;
                completion_tokens += tokens.completion_tokens as u64;
                total_tokens += tokens.total_tokens as u64;
            }
            if let Some(ref provider_id) = entry.provider_id {
                let p = by_provider
                    .entry(provider_id.clone())
                    .or_insert(ProviderUsageSummary {
                        total_requests: 0,
                        total_errors: 0,
                        prompt_tokens: 0,
                        completion_tokens: 0,
                        total_tokens: 0,
                    });
                p.total_requests += 1;
                if entry.status_code >= 400 || entry.error.is_some() {
                    p.total_errors += 1;
                }
                if let Some(ref tokens) = entry.tokens {
                    p.prompt_tokens += tokens.prompt_tokens as u64;
                    p.completion_tokens += tokens.completion_tokens as u64;
                    p.total_tokens += tokens.total_tokens as u64;
                }
            }
        }

        UsageSummary {
            total_requests,
            total_errors,
            prompt_tokens,
            completion_tokens,
            total_tokens,
            by_provider,
        }
    }
}

impl Default for RequestLogger {
    fn default() -> Self {
        Self::new()
    }
}
