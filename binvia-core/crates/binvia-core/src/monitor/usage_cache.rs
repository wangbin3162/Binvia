use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyedBalance {
    pub label: String,
    pub balance: f64,
    pub currency: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub label: String,
    pub remaining_ratio: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
    pub unlimited: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelQuota {
    pub model_id: String,
    pub remaining: i64,
    pub limit: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resets_at: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsageSnapshot {
    #[serde(rename = "providerID")]
    pub provider_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub currency: Option<String>,
    pub balances: Vec<KeyedBalance>,
    pub quota_windows: Vec<QuotaWindow>,
    pub model_quotas: Vec<ModelQuota>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "rawJSON")]
    pub raw_json: Option<serde_json::Value>,
    #[serde(rename = "fetchedAt")]
    pub fetched_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

struct CacheEntry {
    snapshot: ProviderUsageSnapshot,
    fetched_at: Instant,
}

pub struct UsageCache {
    inner: Arc<Mutex<HashMap<String, CacheEntry>>>,
    ttl: Duration,
}

impl UsageCache {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(HashMap::new())),
            ttl: Duration::from_secs(300),
        }
    }

    pub fn get(&self, provider_id: &str) -> Option<ProviderUsageSnapshot> {
        let map = self.inner.lock().unwrap();
        map.get(provider_id).map(|e| e.snapshot.clone())
    }

    pub fn set(&self, provider_id: String, snapshot: ProviderUsageSnapshot) {
        let mut map = self.inner.lock().unwrap();
        map.insert(
            provider_id,
            CacheEntry {
                snapshot,
                fetched_at: Instant::now(),
            },
        );
    }

    pub fn invalidate(&self, provider_id: &str) {
        let mut map = self.inner.lock().unwrap();
        map.remove(provider_id);
    }

    pub fn all(&self) -> HashMap<String, ProviderUsageSnapshot> {
        let map = self.inner.lock().unwrap();
        map.iter()
            .map(|(k, v)| (k.clone(), v.snapshot.clone()))
            .collect()
    }

    pub fn is_stale(&self, provider_id: &str) -> bool {
        let map = self.inner.lock().unwrap();
        match map.get(provider_id) {
            Some(entry) => entry.fetched_at.elapsed() > self.ttl,
            None => true,
        }
    }
}

impl Default for UsageCache {
    fn default() -> Self {
        Self::new()
    }
}
