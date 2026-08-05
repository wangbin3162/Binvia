use std::sync::{Arc, RwLock as StdRwLock};
use tokio::sync::RwLock;

use crate::config::RouteConfig;
use crate::monitor::{RequestLogger, UsageCache};
use crate::provider::catalog::builtin_providers;
use crate::provider::descriptor::{Model, ProviderAuthType, ProviderDescriptor, ProviderMetadata};
use crate::provider::registry::ProviderRegistry;
use crate::router::RouteResolver;

pub struct AppState {
    pub config: Arc<RwLock<RouteConfig>>,
    pub logger: Arc<RequestLogger>,
    pub usage_cache: Arc<UsageCache>,
    pub admin_token: Arc<RwLock<Option<String>>>,
    pub registry: Arc<StdRwLock<ProviderRegistry>>,
    pub resolver: Arc<StdRwLock<RouteResolver>>,
}

impl AppState {
    pub fn new(config: RouteConfig) -> Self {
        let registry = Arc::new(StdRwLock::new(registry_for_config(&config)));
        let resolver = Arc::new(StdRwLock::new(RouteResolver::new(Arc::clone(&registry))));

        Self {
            config: Arc::new(RwLock::new(config)),
            logger: Arc::new(RequestLogger::new()),
            usage_cache: Arc::new(UsageCache::new()),
            admin_token: Arc::new(RwLock::new(None)),
            registry,
            resolver,
        }
    }

    pub async fn replace_config(&self, config: RouteConfig) {
        let mut current_config = self.config.write().await;
        *current_config = config.clone();
        self.rebuild_provider_state(&config);
    }

    fn rebuild_provider_state(&self, config: &RouteConfig) {
        let rebuilt = registry_for_config(config);
        let mut resolver = self.resolver.write().expect("route resolver lock poisoned");
        *self
            .registry
            .write()
            .expect("provider registry lock poisoned") = rebuilt;
        *resolver = RouteResolver::new(Arc::clone(&self.registry));
    }
}

fn registry_for_config(config: &RouteConfig) -> ProviderRegistry {
    let mut registry = ProviderRegistry::new();
    for descriptor in builtin_providers() {
        registry.register(descriptor);
    }
    for custom in &config.custom_provider_defs {
        registry.register(ProviderDescriptor {
            metadata: ProviderMetadata {
                id: custom.id.clone(),
                alias: None,
                display_name: custom.display_name.clone(),
                auth_type: ProviderAuthType::ApiKey,
            },
            base_url: Some(custom.base_url.clone()),
            models: custom
                .models
                .iter()
                .map(|id| Model {
                    id: id.clone(),
                    name: Some(id.clone()),
                    context_length: None,
                    supports_reasoning: false,
                    supports_vision: false,
                })
                .collect(),
            supports_streaming: true,
            models_url: None,
            force_stream: false,
            regions: Vec::new(),
            usage_dashboard_url: None,
            is_user_defined: true,
        });
    }
    registry
}
