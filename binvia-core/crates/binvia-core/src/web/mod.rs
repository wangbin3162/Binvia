use axum::body::Body;
use axum::http::{Response, StatusCode, header};
use axum::response::IntoResponse;
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "../../web/dist/"]
struct WebAssets;

fn content_type(path: &str) -> &'static str {
    if path.ends_with(".html") {
        "text/html; charset=utf-8"
    } else if path.ends_with(".css") {
        "text/css; charset=utf-8"
    } else if path.ends_with(".js") {
        "application/javascript; charset=utf-8"
    } else if path.ends_with(".json") {
        "application/json"
    } else if path.ends_with(".png") {
        "image/png"
    } else if path.ends_with(".jpg") || path.ends_with(".jpeg") {
        "image/jpeg"
    } else if path.ends_with(".gif") {
        "image/gif"
    } else if path.ends_with(".svg") {
        "image/svg+xml"
    } else if path.ends_with(".ico") {
        "image/x-icon"
    } else if path.ends_with(".woff2") {
        "font/woff2"
    } else if path.ends_with(".woff") {
        "font/woff"
    } else if path.ends_with(".ttf") {
        "font/ttf"
    } else {
        "application/octet-stream"
    }
}

pub async fn handle_index(
    axum::extract::State(state): axum::extract::State<
        std::sync::Arc<crate::server::state::AppState>,
    >,
) -> impl IntoResponse {
    if !state.config.read().await.web_panel_enabled {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::from("Not Found"))
            .unwrap();
    }
    match WebAssets::get("index.html") {
        Some(asset) => {
            let data = asset.data.to_vec();
            Response::builder()
                .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
                .body(Body::from(data))
                .unwrap()
        }
        None => {
            let fallback = r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Binvia Rust Gateway</title>
<style>
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; background: #f5f5f7; color: #1d1d1f; }
.container { text-align: center; padding: 2rem; }
h1 { font-size: 2rem; font-weight: 600; }
p { color: #6e6e73; }
</style>
</head>
<body>
<div class="container">
<h1>Binvia Rust Gateway</h1>
<p>Web panel not built yet</p>
<p>Run <code>cd web && npm install && npm run build</code> to build the panel.</p>
</div>
</body>
</html>"#;
            Response::builder()
                .header(header::CONTENT_TYPE, "text/html; charset=utf-8")
                .body(Body::from(fallback.to_string()))
                .unwrap()
        }
    }
}

pub async fn handle_assets(
    axum::extract::State(state): axum::extract::State<
        std::sync::Arc<crate::server::state::AppState>,
    >,
    path: axum::extract::Path<String>,
) -> impl IntoResponse {
    if !state.config.read().await.web_panel_enabled {
        return Response::builder()
            .status(StatusCode::NOT_FOUND)
            .body(Body::from("Not Found"))
            .unwrap();
    }
    let requested_path = path.0;
    let asset_path = if WebAssets::get(&requested_path).is_some() {
        requested_path.clone()
    } else {
        format!("assets/{requested_path}")
    };
    match WebAssets::get(&asset_path) {
        Some(asset) => {
            let data = asset.data.to_vec();
            let ct = content_type(&requested_path);
            Response::builder()
                .header(header::CONTENT_TYPE, ct)
                .body(Body::from(data))
                .unwrap()
        }
        None => {
            let body = format!("404: asset not found: {}", asset_path);
            Response::builder()
                .status(StatusCode::NOT_FOUND)
                .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
                .body(Body::from(body))
                .unwrap()
        }
    }
}
