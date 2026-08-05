use std::sync::Arc;
use std::sync::RwLock;

use crate::provider::registry::ProviderRegistry;

#[derive(Debug, Clone)]
pub struct Resolution {
    pub provider_id: String,
    pub model_id: String,
}

pub struct RouteResolver {
    registry: Arc<RwLock<ProviderRegistry>>,
}

pub fn normalize_model_name(model: &str) -> String {
    let trimmed = model.trim();
    let Some(open) = trimmed.rfind('[') else {
        return trimmed.to_string();
    };
    if !trimmed.ends_with(']') || open == 0 {
        return trimmed.to_string();
    }

    let suffix = &trimmed[open + 1..trimmed.len() - 1];
    let unit = suffix.chars().last();
    let numeric = &suffix[..suffix.len().saturating_sub(unit.map_or(0, char::len_utf8))];
    if matches!(unit, Some('k' | 'K' | 'm' | 'M' | 'g' | 'G'))
        && !numeric.is_empty()
        && numeric
            .chars()
            .all(|character| character.is_ascii_digit() || character == '.')
    {
        return trimmed[..open].to_string();
    }

    trimmed.to_string()
}

impl RouteResolver {
    pub fn new(registry: Arc<RwLock<ProviderRegistry>>) -> Self {
        Self { registry }
    }

    fn prefix_heuristic(model: &str) -> Option<&'static str> {
        if model.starts_with("claude-") || model.starts_with("gemini-") {
            return Some("antigravity");
        }
        if model.starts_with("gpt-")
            || model.starts_with("o3-")
            || model.starts_with("o4-")
            || model.starts_with("o1-")
        {
            return Some("openai");
        }
        if model.starts_with("glm-") {
            return Some("codebuddy-cn");
        }
        if model.starts_with("deepseek-") {
            return Some("deepseek");
        }
        if model.starts_with("kimi-") {
            return Some("kimi");
        }
        if model.starts_with("qwen") {
            return Some("qwen-cloud");
        }
        if model.starts_with("minimax") {
            return Some("minimax");
        }
        if model.starts_with("mimo-") {
            return Some("xiaomi-mimo");
        }
        None
    }

    pub fn resolve(&self, raw_model: &str) -> Option<Resolution> {
        let model = normalize_model_name(raw_model);
        if model.is_empty() {
            return None;
        }

        let registry = self
            .registry
            .read()
            .expect("provider registry lock poisoned");

        if let Some(slash_pos) = model.find('/') {
            let provider_part = &model[..slash_pos];
            let model_part = &model[slash_pos + 1..];
            if let Some(canonical) = registry.canonical_provider_id(provider_part) {
                return Some(Resolution {
                    provider_id: canonical,
                    model_id: model_part.to_string(),
                });
            }
        }

        let candidates = registry.providers_for_model(&model);
        if candidates.is_empty() {
            return None;
        }

        if candidates.len() == 1 {
            return Some(Resolution {
                provider_id: candidates[0].metadata.id.clone(),
                model_id: model.clone(),
            });
        }

        if let Some(provider_id) = Self::prefix_heuristic(&model) {
            if candidates.iter().any(|d| d.metadata.id == provider_id) {
                return Some(Resolution {
                    provider_id: provider_id.to_string(),
                    model_id: model.clone(),
                });
            }
        }

        let mut matching: Vec<&str> = candidates
            .iter()
            .filter(|d| {
                let id_match = model.starts_with(&d.metadata.id);
                let alias_match = d
                    .metadata
                    .alias
                    .as_deref()
                    .map_or(false, |a| model.starts_with(a));
                id_match || alias_match
            })
            .map(|d| d.metadata.id.as_str())
            .collect();

        if matching.len() == 1 {
            return Some(Resolution {
                provider_id: matching[0].to_string(),
                model_id: model.clone(),
            });
        }

        if matching.is_empty() {
            matching = candidates.iter().map(|d| d.metadata.id.as_str()).collect();
        }

        matching.sort();
        Some(Resolution {
            provider_id: matching[0].to_string(),
            model_id: model,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_model_name;

    #[test]
    fn strips_context_capacity_suffix() {
        assert_eq!(
            normalize_model_name("ds/deepseek-v4-flash[1M]"),
            "ds/deepseek-v4-flash"
        );
        assert_eq!(normalize_model_name("model[1M-extra]"), "model[1M-extra]");
        assert_eq!(normalize_model_name("model"), "model");
    }
}
