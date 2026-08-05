use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::extract::State;
use axum::http::{Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Json};
use axum::routing::{get, post};
use tower_http::cors::CorsLayer;

use crate::auth;
use crate::server::state::AppState;

async fn health_handler() -> impl IntoResponse {
    Json(serde_json::json!({"status": "ok", "version": 1}))
}

use crate::api::login::login_handler;

async fn admin_auth_layer(
    State(state): State<Arc<AppState>>,
    req: Request<Body>,
    next: Next,
) -> Result<impl IntoResponse, StatusCode> {
    let config = state.config.read().await;
    if !config.web_panel_enabled {
        return Err(StatusCode::NOT_FOUND);
    }
    if config.admin_password.as_deref().is_none_or(str::is_empty) {
        drop(config);
        let response = next.run(req).await;
        return Ok(response);
    }
    drop(config);

    let token = req
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|s| s.to_string())
        .or_else(|| {
            req.headers()
                .get("X-API-Key")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_string())
        });

    if let Some(ref token) = token {
        if auth::is_valid_admin_token(token, &state).await {
            return Ok(next.run(req).await);
        }
    }

    let config = state.config.read().await;
    let has_any_key =
        config.admin_password.is_some() || !config.api_keys.is_empty() || auth::has_env_api_keys();
    if !has_any_key {
        return Ok(next.run(req).await);
    }
    Err(StatusCode::UNAUTHORIZED)
}

pub fn build_router(state: Arc<AppState>) -> Router {
    let admin_routes = crate::api::admin_routes();
    let admin_protected = Router::<Arc<AppState>>::new()
        .nest("/admin/api", admin_routes)
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            admin_auth_layer,
        ));

    Router::<Arc<AppState>>::new()
        .route("/", get(crate::web::handle_index))
        .route("/assets/{path}", get(crate::web::handle_assets))
        .route("/v1/health", get(health_handler))
        .route("/v1/models", get(crate::gateway::models_handler))
        .route("/v1/chat/completions", post(crate::gateway::chat_handler))
        .route(
            "/v1/usage",
            get(crate::gateway::usage_handler).post(crate::gateway::usage_handler),
        )
        .route("/admin/api/login", post(login_handler))
        .merge(admin_protected)
        .layer(CorsLayer::permissive())
        .with_state(state)
}
