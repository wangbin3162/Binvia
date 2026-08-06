// OAuth 登录模块（Phase E 完整实现 codebuddy/antigravity 登录流程）。
// 当前仅提供 codex usage fetcher 依赖的 token 刷新。

use serde_json::Value;

/// Codex token 刷新（对齐 Swift `CodexOAuthClient.refreshAccessToken`）。
/// `POST auth.openai.com/oauth/token`，`grant_type=refresh_token`，无 scope。
pub async fn refresh_codex_token(refresh_token: &str) -> Result<String, String> {
    let client_id = std::env::var("CODEX_OAUTH_CLIENT_ID")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "app_EMoamEEZ73f0CkXaXp7hrann".to_string());
    let response = crate::networking::HttpClient::shared()
        .inner()
        .post("https://auth.openai.com/oauth/token")
        .header("Accept", "application/json")
        .header(
            "User-Agent",
            "codex-cli/0.144.1 (Windows 10.0.26200; x64)",
        )
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", &client_id),
        ])
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let json: Value = response.json().await.map_err(|e| e.to_string())?;
    json.get("access_token")
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| "refresh 未返回 access_token".to_string())
}
