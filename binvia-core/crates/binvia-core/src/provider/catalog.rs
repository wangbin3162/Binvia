use crate::provider::descriptor::{Model, ProviderAuthType, ProviderDescriptor, ProviderMetadata};

fn model(id: &str, name: Option<&str>, context_length: Option<u32>) -> Model {
    Model {
        id: id.to_string(),
        name: name.map(|s| s.to_string()),
        context_length,
        supports_reasoning: false,
        supports_vision: false,
    }
}

fn models(ids: &[&str]) -> Vec<Model> {
    ids.iter().map(|id| model(id, Some(id), None)).collect()
}

fn descriptor(
    id: &str,
    alias: Option<&str>,
    display_name: &str,
    auth_type: ProviderAuthType,
    base_url: &str,
    models: Vec<Model>,
    force_stream: bool,
) -> ProviderDescriptor {
    ProviderDescriptor {
        metadata: ProviderMetadata {
            id: id.to_string(),
            alias: alias.map(|s| s.to_string()),
            display_name: display_name.to_string(),
            auth_type,
        },
        base_url: Some(base_url.to_string()),
        models,
        supports_streaming: true,
        models_url: None,
        force_stream,
        regions: Vec::new(),
        usage_dashboard_url: None,
        is_user_defined: false,
    }
}

pub fn builtin_providers() -> Vec<ProviderDescriptor> {
    vec![
        descriptor(
            "deepseek",
            Some("ds"),
            "DeepSeek",
            ProviderAuthType::ApiKey,
            "https://api.deepseek.com/v1",
            models(&["deepseek-v4-pro", "deepseek-v4-flash"]),
            false,
        ),
        descriptor(
            "codebuddy-cn",
            Some("cbcn"),
            "CodeBuddy CN",
            ProviderAuthType::DeviceFlow,
            "https://copilot.tencent.com/v2",
            models(&[
                "glm-5.2",
                "glm-5.1",
                "glm-5.0",
                "glm-5.0-turbo",
                "glm-5v-turbo",
                "glm-4.7",
                "minimax-m3",
                "minimax-m2.7",
                "kimi-k2.7",
                "kimi-k2.6",
                "kimi-k2.5",
                "hy3-preview",
                "deepseek-v4-pro",
                "deepseek-v4-flash",
                "deepseek-v3-2-volc",
            ]),
            true,
        ),
        descriptor(
            "antigravity",
            Some("agy"),
            "Antigravity",
            ProviderAuthType::OAuth,
            "https://cloudcode-pa.googleapis.com",
            models(&[
                "gemini-3.6-flash-high",
                "gemini-3.6-flash-medium",
                "gemini-3.6-flash-low",
                "gemini-pro-agent",
                "claude-sonnet-4-6",
                "claude-opus-4-6-thinking",
                "gemini-2.5-flash",
                "gpt-oss-120b-medium",
            ]),
            true,
        ),
        descriptor(
            "openai",
            Some("openai"),
            "OpenAI",
            ProviderAuthType::ApiKey,
            "https://api.openai.com/v1",
            models(&[
                "gpt-5.6", "gpt-5.5", "gpt-5.4", "gpt-4.1", "gpt-4o", "o3", "o4-mini",
            ]),
            false,
        ),
        descriptor(
            "opencode",
            Some("oc"),
            "OpenCode",
            ProviderAuthType::ApiKey,
            "https://opencode.ai/zen/v1",
            models(&[
                "claude-fable-5",
                "claude-opus-4-6",
                "claude-opus-4-7",
                "claude-opus-4-8",
                "deepseek-v4-flash",
                "deepseek-v4-flash-free",
                "deepseek-v4-pro",
                "glm-5.2",
                "gpt-5.3-codex",
                "gpt-5.6-luna",
                "gpt-5.6-sol",
                "gpt-5.6-terra",
                "grok-4.5",
                "grok-build-0.1",
                "kimi-k2.7-code",
                "kimi-k3",
                "laguna-s-2.1-free",
                "ling-3.0-flash-free",
                "mimo-v2.5-free",
                "minimax-m3",
            ]),
            false,
        ),
        descriptor(
            "kimi",
            Some("kimi"),
            "Kimi",
            ProviderAuthType::ApiKey,
            "https://api.moonshot.cn/v1",
            models(&["kimi-k3", "kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5"]),
            true,
        ),
        descriptor(
            "opencode-go",
            Some("ocgo"),
            "OpenCode Go",
            ProviderAuthType::ApiKey,
            "https://opencode.ai/zen/go/v1",
            models(&["glm-5.2", "kimi-k2.7-code", "qwen3.7-max", "mimo-v2.5-pro"]),
            false,
        ),
        descriptor(
            "xiaomi-mimo",
            Some("mimo"),
            "Xiaomi MiMo",
            ProviderAuthType::ApiKey,
            "https://api.xiaomimimo.com/v1",
            models(&["MiMo-V2.5", "MiMo-V2.5-Pro", "MiMo-V2.5-Max"]),
            false,
        ),
        descriptor(
            "qwen-cloud",
            Some("qwc"),
            "Qwen Cloud",
            ProviderAuthType::ApiKey,
            "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            models(&[
                "qwen3.7-max",
                "qwen3.7-plus",
                "qwen3.6-plus",
                "qwen3.5-397b-a17b",
            ]),
            false,
        ),
        descriptor(
            "zai",
            Some("zai"),
            "z.ai",
            ProviderAuthType::ApiKey,
            "https://open.bigmodel.cn/api/anthropic/v1/messages",
            models(&[
                "glm-5.2",
                "glm-5.1",
                "glm-5",
                "glm-4.7-flash",
                "glm-4.5-air",
            ]),
            false,
        ),
        descriptor(
            "minimax",
            Some("mm"),
            "MiniMax",
            ProviderAuthType::ApiKey,
            "https://api.minimaxi.com/anthropic/v1/messages",
            models(&["MiniMax-M3", "MiniMax-M2.7", "MiniMax-M2.5"]),
            false,
        ),
        descriptor(
            "codex",
            Some("cx"),
            "Codex (ChatGPT)",
            ProviderAuthType::OAuth,
            "https://chatgpt.com",
            models(&[
                "gpt-5.6-sol",
                "gpt-5.6-sol-ultra",
                "gpt-5.6-sol-max",
                "gpt-5.6-sol-xhigh",
                "gpt-5.6-sol-high",
                "gpt-5.6-sol-medium",
                "gpt-5.6-sol-low",
                "gpt-5.6-terra",
                "gpt-5.6-terra-ultra",
                "gpt-5.6-terra-max",
                "gpt-5.6-terra-xhigh",
                "gpt-5.6-terra-high",
                "gpt-5.6-terra-medium",
                "gpt-5.6-terra-low",
                "gpt-5.6-luna",
                "gpt-5.6-luna-max",
                "gpt-5.6-luna-xhigh",
                "gpt-5.6-luna-high",
                "gpt-5.6-luna-medium",
                "gpt-5.6-luna-low",
                "gpt-5.5",
                "gpt-5.5-xhigh",
                "gpt-5.5-high",
                "gpt-5.5-medium",
                "gpt-5.5-low",
                "gpt-5.3-codex-spark",
            ]),
            false,
        ),
        descriptor(
            "cursor",
            Some("cu"),
            "Cursor",
            ProviderAuthType::ApiKey,
            "https://api.cursor.com/v1",
            models(&[
                "auto",
                "composer-2.5-fast",
                "composer-2.5",
                "composer-2-fast",
                "composer-2",
                "gpt-5.5-none",
                "gpt-5.5-none-fast",
                "gpt-5.5-low",
                "gpt-5.5-low-fast",
                "gpt-5.5-medium",
                "gpt-5.5-medium-fast",
                "gpt-5.5-high",
                "gpt-5.5-high-fast",
                "gpt-5.5-extra-high",
                "gpt-5.5-extra-high-fast",
                "gpt-5.4-low",
                "gpt-5.4-medium",
                "gpt-5.4-high",
                "gpt-5.4-xhigh",
                "gpt-5.3-codex",
                "claude-opus-4-8-low",
                "claude-opus-4-8-high",
                "claude-sonnet-5-low",
                "claude-sonnet-5-high",
                "gemini-3.1-pro",
                "gemini-3-flash",
                "grok-4.5-medium",
                "kimi-k2.5",
            ]),
            false,
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::builtin_providers;
    use crate::provider::registry::ProviderRegistry;

    #[test]
    fn builtin_catalog_matches_current_provider_ids() {
        let providers = builtin_providers();
        let ids: Vec<&str> = providers
            .iter()
            .map(|provider| provider.metadata.id.as_str())
            .collect();

        assert_eq!(
            ids,
            vec![
                "deepseek",
                "codebuddy-cn",
                "antigravity",
                "openai",
                "opencode",
                "kimi",
                "opencode-go",
                "xiaomi-mimo",
                "qwen-cloud",
                "zai",
                "minimax",
                "codex",
                "cursor",
            ]
        );
        assert!(!ids.contains(&"codebuddy-deepseek"));
        assert!(!ids.contains(&"lingyi"));
    }

    #[test]
    fn codebuddy_cn_uses_current_alias_and_authentication() {
        let providers = builtin_providers();
        let mut registry = ProviderRegistry::new();
        for provider in providers {
            registry.register(provider);
        }
        let provider = registry
            .get("codebuddy-cn")
            .expect("codebuddy-cn is registered");

        assert_eq!(
            registry.canonical_provider_id("cbcn").as_deref(),
            Some("codebuddy-cn")
        );
        assert_eq!(provider.metadata.alias.as_deref(), Some("cbcn"));
        assert_eq!(
            serde_json::to_string(&provider.metadata.auth_type).unwrap(),
            "\"deviceflow\""
        );
        assert_eq!(
            provider.base_url.as_deref(),
            Some("https://copilot.tencent.com/v2")
        );
        assert!(provider.force_stream);
    }
}
