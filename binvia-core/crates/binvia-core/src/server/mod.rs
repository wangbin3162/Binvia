use std::sync::Arc;

use tokio::net::TcpListener;
use tracing::info;

use crate::server::router::build_router;
use crate::server::state::AppState;

pub mod router;
pub mod state;

pub async fn start(state: Arc<AppState>) -> Result<(), std::io::Error> {
    let config = state.config.read().await;
    let host = config.host.clone();
    let port = config.port;
    let addr = format!("{}:{}", host, port);
    drop(config);

    let listener = TcpListener::bind(&addr).await?;
    info!("Server listening on {}", addr);

    let app = build_router(state);
    axum::serve(listener, app)
        .await
        .map_err(std::io::Error::other)
}
