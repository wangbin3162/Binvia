use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use reqwest::{Client, Method, Response, StatusCode};
use tokio::sync::RwLock;
use tracing::warn;

use crate::provider::descriptor::Model;

/// 网关统一的 HTTP 客户端 + 重试策略（对齐 Swift `ProviderHTTPClient`）。
///
/// - `data_for` 返回完整 `(body, status, headers)`，非 2xx **不抛**，调用方判状态；
/// - 重试仅对幂等 `GET/HEAD/OPTIONS`，状态码 `408/429/500/502/503/504`，指数退避
///   `0.5s → 1s` 封顶 `5s`，`Retry-After` 封顶 `60s`，最多 2 次。
pub struct HttpClient {
    client: Client,
}

impl HttpClient {
    pub fn new() -> Self {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(120))
            .build()
            .expect("valid provider HTTP client configuration");
        Self { client }
    }

    pub fn shared() -> &'static HttpClient {
        static INSTANCE: std::sync::OnceLock<HttpClient> = std::sync::OnceLock::new();
        INSTANCE.get_or_init(HttpClient::new)
    }

    pub fn inner(&self) -> &Client {
        &self.client
    }

    /// 执行请求，返回 `(body, status, headers)`。非 2xx 不抛，调用方判状态。
    /// 默认带 `RetryPolicy::default()`。
    pub async fn data_for(&self, request: reqwest::RequestBuilder) -> Result<HttpResponse, reqwest::Error> {
        self.data_for_with_retry(request, RetryPolicy::default()).await
    }

    /// 同 `data_for`，但用自定义重试策略（传 `RetryPolicy::none()` 关闭重试）。
    pub async fn data_for_with_retry(
        &self,
        request: reqwest::RequestBuilder,
        retry: RetryPolicy,
    ) -> Result<HttpResponse, reqwest::Error> {
        // 取 method 用于幂等性判定（RequestBuilder 不暴露 method，需 build 一次探针）。
        let probe = request.try_clone().and_then(|b| b.build().ok());
        let method = probe.as_ref().map(|r| r.method().clone()).unwrap_or(Method::GET);

        let mut attempt = 0;
        loop {
            let builder = match request.try_clone() {
                Some(builder) => builder,
                None => {
                    // 不可克隆的请求一次性发送，不重试。
                    let response = request.send().await?;
                    let headers = response.headers().clone();
                    let status = response.status();
                    let body = response.bytes().await?;
                    return Ok(HttpResponse { body, status, headers });
                }
            };
            let response = builder.send().await?;
            let status = response.status();
            if retry.is_retryable_status(&status) && retry.is_idempotent(&method) && attempt < retry.max_retries {
                let delay = retry_delay(&response, attempt, &retry).await;
                if let Some(delay) = delay {
                    warn!(attempt = attempt + 1, status = status.as_u16(), delay_ms = delay.as_millis(), "retrying upstream request");
                    tokio::time::sleep(delay).await;
                    attempt += 1;
                    continue;
                }
            }
            let headers = response.headers().clone();
            let status = response.status();
            let body = response.bytes().await?;
            return Ok(HttpResponse { body, status, headers });
        }
    }
}

impl Default for HttpClient {
    fn default() -> Self {
        Self::new()
    }
}

/// 上游响应（body + status + headers）。
pub struct HttpResponse {
    pub body: Bytes,
    pub status: StatusCode,
    pub headers: reqwest::header::HeaderMap,
}

impl HttpResponse {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).to_string()
    }
}

/// 重试策略（对齐 Swift `ProviderHTTPRetryPolicy`）。
#[derive(Clone, Copy)]
pub struct RetryPolicy {
    pub max_retries: u32,
    pub base_delay: Duration,
    pub max_delay: Duration,
}

impl RetryPolicy {
    pub fn default() -> Self {
        Self {
            max_retries: 2,
            base_delay: Duration::from_millis(500),
            max_delay: Duration::from_secs(5),
        }
    }

    pub fn none() -> Self {
        Self {
            max_retries: 0,
            base_delay: Duration::ZERO,
            max_delay: Duration::ZERO,
        }
    }

    pub fn is_retryable_status(&self, status: &StatusCode) -> bool {
        matches!(
            status.as_u16(),
            408 | 429 | 500 | 502 | 503 | 504
        )
    }

    pub fn is_idempotent(&self, method: &Method) -> bool {
        matches!(method, &Method::GET | &Method::HEAD | &Method::OPTIONS)
    }
}

/// 计算重试延迟：`Retry-After` 封顶 60s，否则指数退避 `base * 2^attempt` 封顶 `max_delay`。
async fn retry_delay(response: &Response, attempt: u32, policy: &RetryPolicy) -> Option<Duration> {
    if let Some(value) = response.headers().get(reqwest::header::RETRY_AFTER) {
        if let Ok(text) = value.to_str() {
            if let Ok(seconds) = text.trim().parse::<u64>() {
                return Some(Duration::from_secs(seconds.min(60)));
            }
        }
    }
    let exp = 1u64 << attempt.min(10);
    let delay = policy.base_delay.as_millis() as u64 * exp;
    Some(Duration::from_millis(delay.min(policy.max_delay.as_millis() as u64)).max(policy.base_delay))
}

/// 上游模型缓存（对齐 Swift `ModelCache`）。300s TTL，per-provider。
pub struct ModelCache {
    inner: Arc<RwLock<std::collections::HashMap<String, CacheEntry>>>,
    ttl: Duration,
}

#[derive(Clone)]
struct CacheEntry {
    models: Vec<Model>,
    fetched_at: std::time::Instant,
}

impl ModelCache {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(std::collections::HashMap::new())),
            ttl: Duration::from_secs(300),
        }
    }

    pub async fn get(&self, provider_id: &str) -> Option<Vec<Model>> {
        let map = self.inner.read().await;
        let entry = map.get(provider_id)?;
        if entry.fetched_at.elapsed() > self.ttl {
            return None;
        }
        Some(entry.models.clone())
    }

    pub async fn set(&self, provider_id: impl Into<String>, models: Vec<Model>) {
        let mut map = self.inner.write().await;
        map.insert(
            provider_id.into(),
            CacheEntry {
                models,
                fetched_at: std::time::Instant::now(),
            },
        );
    }

    pub async fn invalidate(&self, provider_id: &str) {
        let mut map = self.inner.write().await;
        map.remove(provider_id);
    }
}

impl Default for ModelCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_policy_marks_idempotent_methods() {
        let policy = RetryPolicy::default();
        assert!(policy.is_idempotent(&Method::GET));
        assert!(policy.is_idempotent(&Method::HEAD));
        assert!(policy.is_idempotent(&Method::OPTIONS));
        assert!(!policy.is_idempotent(&Method::POST));
    }

    #[test]
    fn retry_policy_marks_retryable_statuses() {
        let policy = RetryPolicy::default();
        for code in [408, 429, 500, 502, 503, 504] {
            assert!(policy.is_retryable_status(&StatusCode::from_u16(code).unwrap()));
        }
        for code in [200, 400, 401, 403, 404] {
            assert!(!policy.is_retryable_status(&StatusCode::from_u16(code).unwrap()));
        }
    }

    #[tokio::test]
    async fn model_cache_ttl_expires() {
        let cache = ModelCache::new();
        cache
            .set("test", vec![Model {
                id: "m1".to_string(),
                name: Some("m1".to_string()),
                context_length: None,
                supports_reasoning: false,
                supports_vision: false,
            }])
            .await;
        assert!(cache.get("test").await.is_some());
        // 手动改 fetched_at 为过去时间模拟过期
        {
            let mut map = cache.inner.write().await;
            if let Some(entry) = map.get_mut("test") {
                entry.fetched_at = std::time::Instant::now() - Duration::from_secs(400);
            }
        }
        assert!(cache.get("test").await.is_none());
    }
}
