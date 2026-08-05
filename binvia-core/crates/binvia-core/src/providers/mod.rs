use std::fmt;
use std::pin::Pin;
use std::time::Duration;

use async_trait::async_trait;
use futures::{Stream, StreamExt, stream};
use reqwest::{Client, Response, StatusCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::config::ProviderCredential;
use crate::provider::descriptor::Model;

/// OpenAI 兼容聊天请求的公共子集。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<Message>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatResponse {
    pub id: String,
    pub object: String,
    pub created: u64,
    pub model: String,
    pub choices: Vec<Choice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Choice {
    pub index: u32,
    pub message: Message,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatChunk {
    pub id: String,
    pub object: String,
    pub created: u64,
    pub model: String,
    pub choices: Vec<ChunkChoice>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkChoice {
    pub index: u32,
    pub delta: Delta,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finish_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Delta {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Debug)]
pub enum ProviderError {
    MissingCredentials,
    InvalidUrl(String),
    Http(reqwest::Error),
    HttpStatus { status: StatusCode, body: String },
    InvalidResponse(String),
    Json(serde_json::Error),
}

impl fmt::Display for ProviderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingCredentials => write!(f, "provider credentials are missing"),
            Self::InvalidUrl(url) => write!(f, "invalid provider URL: {url}"),
            Self::Http(error) => write!(f, "provider request failed: {error}"),
            Self::HttpStatus { status, body } => {
                write!(f, "provider returned {status}: {body}")
            }
            Self::InvalidResponse(message) => write!(f, "invalid provider response: {message}"),
            Self::Json(error) => write!(f, "provider JSON error: {error}"),
        }
    }
}

impl std::error::Error for ProviderError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Http(error) => Some(error),
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl From<reqwest::Error> for ProviderError {
    fn from(error: reqwest::Error) -> Self {
        Self::Http(error)
    }
}

impl From<serde_json::Error> for ProviderError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub type ChatStream = Pin<Box<dyn Stream<Item = Result<ChatChunk, ProviderError>> + Send>>;

#[async_trait]
pub trait Provider: Send + Sync {
    fn id(&self) -> &str;

    async fn chat(
        &self,
        request: ChatRequest,
        credential: Option<&ProviderCredential>,
    ) -> Result<ChatResponse, ProviderError>;

    async fn chat_stream(
        &self,
        request: ChatRequest,
        credential: Option<&ProviderCredential>,
    ) -> Result<ChatStream, ProviderError>;

    async fn list_models(
        &self,
        credential: Option<&ProviderCredential>,
    ) -> Result<Vec<Model>, ProviderError>;

    async fn test_connection(
        &self,
        credential: Option<&ProviderCredential>,
    ) -> Result<(), ProviderError>;
}

/// CodeBuddy 的连接探测必须走真实聊天接口；该接口不支持 GET /models。
pub async fn test_codebuddy_connection(token: &str) -> Result<(), ProviderError> {
    if token.trim().is_empty() {
        return Err(ProviderError::MissingCredentials);
    }

    let client = Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .build()
        .expect("valid provider HTTP client configuration");
    let response = client
        .post("https://copilot.tencent.com/v2/chat/completions")
        .bearer_auth(token)
        .header("Accept", "text/event-stream")
        .header("User-Agent", "CLI/2.108.1 CodeBuddy/2.108.1")
        .header("X-Product", "SaaS")
        .header("X-IDE-Type", "CLI")
        .header("X-IDE-Name", "CLI")
        .header("X-Requested-With", "XMLHttpRequest")
        .header("x-codebuddy-request", "1")
        .json(&serde_json::json!({
            "model": "glm-5.2",
            "messages": [{"role": "user", "content": "ping"}],
            "stream": true,
            "max_tokens": 1
        }))
        .send()
        .await?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(ProviderError::HttpStatus { status, body });
    }

    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if !chunk.is_empty() {
            return Ok(());
        }
    }

    Err(ProviderError::InvalidResponse(
        "CodeBuddy SSE ended before the first chunk".to_string(),
    ))
}

/// 使用 OpenAI 兼容 HTTP 接口的通用 provider。
pub struct OpenAICompatibleProvider {
    pub id: String,
    pub base_url: String,
    client: Client,
    headers: Vec<(String, String)>,
}

impl OpenAICompatibleProvider {
    pub fn new(id: impl Into<String>, base_url: impl Into<String>) -> Self {
        let mut base_url = base_url.into().trim_end_matches('/').to_string();
        if let Some(prefix) = base_url.strip_suffix("/chat/completions") {
            base_url = prefix.trim_end_matches('/').to_string();
        }

        Self {
            id: id.into(),
            base_url,
            client: Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(120))
                .build()
                .expect("valid provider HTTP client configuration"),
            headers: Vec::new(),
        }
    }

    pub fn with_headers(
        id: impl Into<String>,
        base_url: impl Into<String>,
        headers: Vec<(String, String)>,
    ) -> Self {
        let mut provider = Self::new(id, base_url);
        provider.headers = headers;
        provider
    }

    fn endpoint(&self, path: &str) -> Result<reqwest::Url, ProviderError> {
        reqwest::Url::parse(&format!("{}/{}", self.base_url, path))
            .map_err(|error| ProviderError::InvalidUrl(error.to_string()))
    }

    fn bearer_token<'a>(
        &self,
        credential: Option<&'a ProviderCredential>,
    ) -> Result<&'a str, ProviderError> {
        credential
            .and_then(|value| value.api_key.as_deref())
            .filter(|value| !value.is_empty())
            .or_else(|| {
                credential
                    .and_then(|value| value.access_token.as_deref())
                    .filter(|value| !value.is_empty())
            })
            .ok_or(ProviderError::MissingCredentials)
    }

    fn normalize_model(&self, model: &str) -> String {
        let prefix = format!("{}/", self.id);
        let mut normalized = model.to_string();
        while normalized.starts_with(&prefix) {
            normalized = normalized[prefix.len()..].to_string();
        }
        normalized
    }

    async fn require_success(response: Response) -> Result<Response, ProviderError> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }

        let body = response.text().await.unwrap_or_default();
        Err(ProviderError::HttpStatus { status, body })
    }

    async fn send_chat(
        &self,
        request: ChatRequest,
        credential: Option<&ProviderCredential>,
        stream: bool,
    ) -> Result<Response, ProviderError> {
        let token = self.bearer_token(credential)?;
        let mut request = request;
        request.model = self.normalize_model(&request.model);
        request.stream = Some(stream);

        let mut upstream = self.client.post(self.endpoint("chat/completions")?);
        for (name, value) in &self.headers {
            upstream = upstream.header(name, value);
        }
        let response = upstream.bearer_auth(token).json(&request).send().await?;
        Self::require_success(response).await
    }
}

#[async_trait]
impl Provider for OpenAICompatibleProvider {
    fn id(&self) -> &str {
        &self.id
    }

    async fn chat(
        &self,
        request: ChatRequest,
        credential: Option<&ProviderCredential>,
    ) -> Result<ChatResponse, ProviderError> {
        let response = self.send_chat(request, credential, false).await?;
        Ok(response.json().await?)
    }

    async fn chat_stream(
        &self,
        request: ChatRequest,
        credential: Option<&ProviderCredential>,
    ) -> Result<ChatStream, ProviderError> {
        let response = self.send_chat(request, credential, true).await?;
        let upstream = Box::pin(
            response
                .bytes_stream()
                .map(|result| result.map(|bytes| bytes.to_vec())),
        );
        let stream = stream::unfold(
            SseState {
                upstream,
                buffer: Vec::new(),
                eof: false,
            },
            |mut state| async move {
                loop {
                    if let Some(event) = take_sse_event(&mut state.buffer) {
                        match parse_sse_event(&event) {
                            Ok(SseEvent::Chunk(chunk)) => return Some((Ok(chunk), state)),
                            Ok(SseEvent::Done) => return None,
                            Ok(SseEvent::Ignore) => continue,
                            Err(error) => {
                                state.eof = true;
                                return Some((Err(error), state));
                            }
                        }
                    }

                    if state.eof {
                        return None;
                    }

                    match state.upstream.next().await {
                        Some(Ok(bytes)) => state.buffer.extend_from_slice(&bytes),
                        Some(Err(error)) => {
                            state.eof = true;
                            return Some((Err(ProviderError::Http(error)), state));
                        }
                        None => {
                            state.eof = true;
                            if !state.buffer.is_empty() {
                                state.buffer.extend_from_slice(b"\n\n");
                                continue;
                            }
                            return Some((
                                Err(ProviderError::InvalidResponse(
                                    "upstream SSE ended before [DONE]".to_string(),
                                )),
                                state,
                            ));
                        }
                    }
                }
            },
        );

        Ok(Box::pin(stream))
    }

    async fn list_models(
        &self,
        credential: Option<&ProviderCredential>,
    ) -> Result<Vec<Model>, ProviderError> {
        let token = self.bearer_token(credential)?;
        let response = self
            .client
            .get(self.endpoint("models")?)
            .bearer_auth(token)
            .send()
            .await?;
        let response = Self::require_success(response).await?;
        let payload: ModelsResponse = response.json().await?;

        Ok(payload
            .data
            .into_iter()
            .map(|model| Model {
                name: Some(model.id.clone()),
                id: model.id,
                context_length: None,
                supports_reasoning: false,
                supports_vision: false,
            })
            .collect())
    }

    async fn test_connection(
        &self,
        credential: Option<&ProviderCredential>,
    ) -> Result<(), ProviderError> {
        let token = self.bearer_token(credential)?;
        let response = self
            .client
            .get(self.endpoint("models")?)
            .bearer_auth(token)
            .send()
            .await?;
        Self::require_success(response).await.map(|_| ())
    }
}

#[derive(Debug, Deserialize)]
struct ModelsResponse {
    #[serde(default)]
    data: Vec<RemoteModel>,
}

#[derive(Debug, Deserialize)]
struct RemoteModel {
    id: String,
}

struct SseState {
    upstream: Pin<Box<dyn Stream<Item = Result<Vec<u8>, reqwest::Error>> + Send>>,
    buffer: Vec<u8>,
    eof: bool,
}

enum SseEvent {
    Chunk(ChatChunk),
    Done,
    Ignore,
}

fn take_sse_event(buffer: &mut Vec<u8>) -> Option<Vec<u8>> {
    let lf_boundary = buffer.windows(2).position(|window| window == b"\n\n");
    let crlf_boundary = buffer.windows(4).position(|window| window == b"\r\n\r\n");
    let (position, length) = match (lf_boundary, crlf_boundary) {
        (Some(lf), Some(crlf)) if crlf < lf => (crlf, 4),
        (Some(lf), _) => (lf, 2),
        (None, Some(crlf)) => (crlf, 4),
        (None, None) => return None,
    };

    let event = buffer[..position].to_vec();
    buffer.drain(..position + length);
    Some(event)
}

fn parse_sse_event(event: &[u8]) -> Result<SseEvent, ProviderError> {
    let text = String::from_utf8_lossy(event);
    let data = text
        .lines()
        .filter_map(|line| line.strip_prefix("data:"))
        .map(str::trim_start)
        .collect::<Vec<_>>()
        .join("\n");

    if data.is_empty() || data == "[DONE]" {
        return Ok(if data == "[DONE]" {
            SseEvent::Done
        } else {
            SseEvent::Ignore
        });
    }

    serde_json::from_str(&data)
        .map(SseEvent::Chunk)
        .map_err(|error| ProviderError::InvalidResponse(format!("invalid SSE data: {error}")))
}
