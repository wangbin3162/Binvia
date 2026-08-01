import Foundation

/// Google Antigravity 的 OAuth 与上游端点配置。
///
/// 常量抄自 OmniRoute：
/// - `src/lib/oauth/constants/oauth.ts` 的 `ANTIGRAVITY_CONFIG`（authorize/token/userinfo/client/scopes）
/// - `open-sse/config/antigravityUpstream.ts`（`cloudcode-pa.googleapis.com`、`v1internal:*`）
///
/// clientID/clientSecret 不内置默认值，必须通过环境变量
/// `ANTIGRAVITY_OAUTH_CLIENT_ID` / `ANTIGRAVITY_OAUTH_CLIENT_SECRET` 提供
/// （参考 OmniRoute `publicCreds.ts` 的公开 Google OAuth client；GitHub Push Protection
/// 会拦截硬编码凭据的推送，故不写入源码）。
///
/// 端点可通过环境变量注入，便于本地 mock 测试：
/// `ANTIGRAVITY_BASE_URL` / `ANTIGRAVITY_AUTHORIZE_URL` / `ANTIGRAVITY_TOKEN_URL`
/// / `ANTIGRAVITY_USERINFO_URL` / `ANTIGRAVITY_REDIRECT_URI`。
public struct AntigravityConfig: Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String?
    public var authorizeURL: URL
    public var tokenURL: URL
    public var userInfoURL: URL
    public var scopes: [String]
    public var redirectURI: String
    /// 运行时 base（`https://cloudcode-pa.googleapis.com`，可注入 mock）。
    public var runtimeBaseURL: String

    public var streamGenerateContentURL: URL
    public var loadCodeAssistURL: URL
    public var onboardUserURL: URL
    public var fetchAvailableModelsURL: URL

    public init(
        clientID: String,
        clientSecret: String?,
        authorizeURL: URL,
        tokenURL: URL,
        userInfoURL: URL,
        scopes: [String],
        redirectURI: String,
        runtimeBaseURL: String
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.userInfoURL = userInfoURL
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.runtimeBaseURL = runtimeBaseURL
        self.streamGenerateContentURL = URL(string: "\(runtimeBaseURL)/v1internal:streamGenerateContent?alt=sse")!
        self.loadCodeAssistURL = URL(string: "\(runtimeBaseURL)/v1internal:loadCodeAssist")!
        self.onboardUserURL = URL(string: "\(runtimeBaseURL)/v1internal:onboardUser")!
        self.fetchAvailableModelsURL = URL(string: "\(runtimeBaseURL)/v1internal:fetchAvailableModels")!
    }

    /// 生产默认配置（凭据必须由环境变量提供，缺省为空/空串，OAuth 流程会因缺 clientID 失败并给出提示）。
    public static func live() -> AntigravityConfig {
        let clientID = RouteConfig.envValue(["ANTIGRAVITY_OAUTH_CLIENT_ID"]) ?? ""
        let clientSecret = RouteConfig.envValue(["ANTIGRAVITY_OAUTH_CLIENT_SECRET"])
        let authorize = RouteConfig.envValue(["ANTIGRAVITY_AUTHORIZE_URL"]) ?? "https://accounts.google.com/o/oauth2/v2/auth"
        let token = RouteConfig.envValue(["ANTIGRAVITY_TOKEN_URL"]) ?? "https://oauth2.googleapis.com/token"
        let userInfo = RouteConfig.envValue(["ANTIGRAVITY_USERINFO_URL"]) ?? "https://www.googleapis.com/oauth2/v1/userinfo"
        let base = RouteConfig.envValue(["ANTIGRAVITY_BASE_URL"]) ?? "https://cloudcode-pa.googleapis.com"
        let redirect = RouteConfig.envValue(["ANTIGRAVITY_REDIRECT_URI"]) ?? "http://127.0.0.1:8325/callback"
        return AntigravityConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            authorizeURL: URL(string: authorize)!,
            tokenURL: URL(string: token)!,
            userInfoURL: URL(string: userInfo)!,
            scopes: defaultScopes,
            redirectURI: redirect,
            runtimeBaseURL: base
        )
    }

    /// 注意：不加 "openid" scope —— 与 9router 一致，避免 PKCE 把 Google 引导进挂起的
    /// `firstparty/nativeapp` consent（antigravity login fix）。
    public static let defaultScopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]
}
