use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;
use uuid::Uuid;

use crate::providers::{ChatChunk, ChatResponse, Choice, Message};

pub struct SseAggregator {
    id: String,
    created: u64,
    model: String,
    role: String,
    content: String,
    finish_reason: Option<String>,
    usage: Option<Value>,
    received_chunks: usize,
}

impl SseAggregator {
    pub fn new(model: impl Into<String>) -> Self {
        let created = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs())
            .unwrap_or_default();

        Self {
            id: format!("chatcmpl-{}", Uuid::new_v4()),
            created,
            model: model.into(),
            role: "assistant".to_string(),
            content: String::new(),
            finish_reason: None,
            usage: None,
            received_chunks: 0,
        }
    }

    pub fn push(&mut self, chunk: &ChatChunk) {
        if self.received_chunks == 0 {
            if !chunk.id.is_empty() {
                self.id = chunk.id.clone();
            }
            self.created = chunk.created;
            if !chunk.model.is_empty() {
                self.model = chunk.model.clone();
            }
        }

        if let Some(choice) = chunk
            .choices
            .iter()
            .find(|choice| choice.index == 0)
            .or_else(|| chunk.choices.first())
        {
            if let Some(role) = &choice.delta.role {
                self.role = role.clone();
            }
            if let Some(content) = &choice.delta.content {
                self.content.push_str(content);
            }
            if choice.finish_reason.is_some() {
                self.finish_reason = choice.finish_reason.clone();
            }
        }

        if chunk.usage.is_some() {
            self.usage = chunk.usage.clone();
        }
        self.received_chunks += 1;
    }

    pub fn finish(self) -> ChatResponse {
        ChatResponse {
            id: self.id,
            object: "chat.completion".to_string(),
            created: self.created,
            model: self.model,
            choices: vec![Choice {
                index: 0,
                message: Message {
                    role: self.role,
                    content: Some(Value::String(self.content)),
                    name: None,
                },
                finish_reason: self.finish_reason,
            }],
            usage: self.usage,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{ChunkChoice, Delta};

    #[test]
    fn aggregates_content_finish_reason_and_usage() {
        let mut aggregator = SseAggregator::new("model");
        aggregator.push(&ChatChunk {
            id: "chatcmpl-test".to_string(),
            object: "chat.completion.chunk".to_string(),
            created: 1,
            model: "model".to_string(),
            choices: vec![ChunkChoice {
                index: 0,
                delta: Delta {
                    role: Some("assistant".to_string()),
                    content: Some("hi".to_string()),
                },
                finish_reason: None,
            }],
            usage: None,
        });
        aggregator.push(&ChatChunk {
            id: "chatcmpl-test".to_string(),
            object: "chat.completion.chunk".to_string(),
            created: 1,
            model: "model".to_string(),
            choices: vec![ChunkChoice {
                index: 0,
                delta: Delta {
                    role: None,
                    content: Some("!".to_string()),
                },
                finish_reason: Some("stop".to_string()),
            }],
            usage: Some(serde_json::json!({
                "prompt_tokens": 1,
                "completion_tokens": 1,
                "total_tokens": 2
            })),
        });

        let response = aggregator.finish();
        assert_eq!(
            response.choices[0].message.content,
            Some(Value::String("hi!".to_string()))
        );
        assert_eq!(response.choices[0].finish_reason.as_deref(), Some("stop"));
        assert!(response.usage.is_some());
    }
}
