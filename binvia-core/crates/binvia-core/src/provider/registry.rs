use std::collections::HashMap;

use crate::provider::descriptor::ProviderDescriptor;

pub struct ProviderRegistry {
    descriptors_by_id: HashMap<String, ProviderDescriptor>,
    alias_map: HashMap<String, String>,
    model_to_providers: HashMap<String, Vec<String>>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self {
            descriptors_by_id: HashMap::new(),
            alias_map: HashMap::new(),
            model_to_providers: HashMap::new(),
        }
    }

    pub fn register(&mut self, descriptor: ProviderDescriptor) {
        let id = descriptor.metadata.id.clone();
        if let Some(ref alias) = descriptor.metadata.alias {
            self.alias_map.insert(alias.clone(), id.clone());
        }
        for model in &descriptor.models {
            self.model_to_providers
                .entry(model.id.clone())
                .or_default()
                .push(id.clone());
        }
        self.descriptors_by_id.insert(id, descriptor);
    }

    pub fn get(&self, id: &str) -> Option<&ProviderDescriptor> {
        self.descriptors_by_id.get(id)
    }

    pub fn canonical_provider_id(&self, input: &str) -> Option<String> {
        if self.descriptors_by_id.contains_key(input) {
            return Some(input.to_string());
        }
        self.alias_map.get(input).cloned()
    }

    pub fn providers_for_model(&self, model_name: &str) -> Vec<&ProviderDescriptor> {
        self.model_to_providers
            .get(model_name)
            .map(|ids| {
                ids.iter()
                    .filter_map(|id| self.descriptors_by_id.get(id))
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn all(&self) -> Vec<&ProviderDescriptor> {
        self.descriptors_by_id.values().collect()
    }

    pub fn ordered_descriptors(&self, order: &[String]) -> Vec<&ProviderDescriptor> {
        let mut result = Vec::with_capacity(order.len());
        let mut seen = std::collections::HashSet::new();
        for id in order {
            if let Some(d) = self.descriptors_by_id.get(id) {
                result.push(d);
                seen.insert(id.as_str());
            }
        }
        let mut remaining: Vec<&ProviderDescriptor> = self
            .descriptors_by_id
            .values()
            .filter(|descriptor| !seen.contains(descriptor.metadata.id.as_str()))
            .collect();
        remaining.sort_by(|left, right| left.metadata.id.cmp(&right.metadata.id));
        for descriptor in remaining {
            result.push(descriptor);
        }
        result
    }
}

impl Default for ProviderRegistry {
    fn default() -> Self {
        Self::new()
    }
}
