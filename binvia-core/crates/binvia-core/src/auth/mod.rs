use crate::config::RouteConfig;
use crate::server::state::AppState;

pub fn is_valid_api_key(key: &str, config: &RouteConfig) -> bool {
    if config.api_keys.iter().any(|k| k.key == key) {
        return true;
    }
    let env_keys = ["BINVIA_API_KEY", "ROUTER_API_KEY", "OMNIROUTE_API_KEY"];
    env_keys
        .iter()
        .any(|env_key| std::env::var(env_key).ok().map_or(false, |val| val == key))
}

pub async fn is_valid_admin_token(token: &str, state: &AppState) -> bool {
    state
        .admin_token
        .read()
        .await
        .as_ref()
        .is_some_and(|value| value == token)
}

pub fn has_env_api_keys() -> bool {
    ["BINVIA_API_KEY", "ROUTER_API_KEY", "OMNIROUTE_API_KEY"]
        .iter()
        .any(|k| std::env::var(k).ok().is_some_and(|value| !value.is_empty()))
}
