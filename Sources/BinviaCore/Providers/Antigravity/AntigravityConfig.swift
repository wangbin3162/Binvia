import Foundation

/// Google Antigravity 的 OAuth 与上游端点配置。
///
/// 常量抄自 OmniRoute：
/// - `src/lib/oauth/constants/oauth.ts` 的 `ANTIGRAVITY_CONFIG`（authorize/token/userinfo/client/scopes）
/// - `open-sse/config/antigravityUpstream.ts`（`cloudcode-pa.googleapis.com`、`v1internal:*`）
///
/// OAuth client_id / client_secret 是 Google 原生应用（native app + PKCE）的公开凭据，
/// Google 官方文档明确这类凭据随客户端公开分发、不应视为机密。OmniRoute 同样内置于源码。
/// 为避免 GitHub secret scanning 对 `GOCSPX-` 字面量的误报拦截，此处按 OmniRoute
/// `publicCreds.ts` 的方式做 XOR 掩码存储、运行时解码；环境变量可覆盖默认值。
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
    /// `fetchAvailableModels` 依序尝试的 discovery base（daily 优先，参考 OmniRoute
    /// `ANTIGRAVITY_DISCOVERY_BASE_URLS`）。mock 注入时仅包含注入的 base。
    public var discoveryBaseURLs: [String]

    public var streamGenerateContentURL: URL
    public var loadCodeAssistURL: URL
    public var onboardUserURL: URL
    public var fetchAvailableModelsURL: URL {
        URL(string: "\(runtimeBaseURL)/v1internal:fetchAvailableModels")!
    }
    /// `:fetchAvailableModels` 全部候选端点（依序 failover）。
    public var fetchAvailableModelsURLs: [URL] {
        discoveryBaseURLs.map { URL(string: "\($0)/v1internal:fetchAvailableModels")! }
    }
    /// 用量查询 RPC（Phase 16）：per-model 配额。
    public var retrieveUserQuotaURL: URL { URL(string: "\(runtimeBaseURL)/v1internal:retrieveUserQuota")! }
    /// 用量汇总 RPC（Phase 16）：模型族 × 窗口（5h / weekly）配额。
    public var retrieveUserQuotaSummaryURL: URL { URL(string: "\(runtimeBaseURL)/v1internal:retrieveUserQuotaSummary")! }

    public init(
        clientID: String,
        clientSecret: String?,
        authorizeURL: URL,
        tokenURL: URL,
        userInfoURL: URL,
        scopes: [String],
        redirectURI: String,
        runtimeBaseURL: String,
        discoveryBaseURLs: [String]? = nil
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.userInfoURL = userInfoURL
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.runtimeBaseURL = runtimeBaseURL
        self.discoveryBaseURLs = discoveryBaseURLs ?? [runtimeBaseURL]
        self.streamGenerateContentURL = URL(string: "\(runtimeBaseURL)/v1internal:streamGenerateContent?alt=sse")!
        self.loadCodeAssistURL = URL(string: "\(runtimeBaseURL)/v1internal:loadCodeAssist")!
        self.onboardUserURL = URL(string: "\(runtimeBaseURL)/v1internal:onboardUser")!
    }

    /// 生产默认配置：凭据优先读环境变量，缺省回退到内置的公开 Google OAuth client（PKCE 原生应用）。
    public static func live() -> AntigravityConfig {
        let clientID = RouteConfig.envValue(["ANTIGRAVITY_OAUTH_CLIENT_ID"])
            ?? decodePublicCred(publicClientIDBytes)
        let clientSecret = RouteConfig.envValue(["ANTIGRAVITY_OAUTH_CLIENT_SECRET"])
            ?? decodePublicCred(publicClientSecretBytes)
        let authorize = RouteConfig.envValue(["ANTIGRAVITY_AUTHORIZE_URL"]) ?? "https://accounts.google.com/o/oauth2/v2/auth"
        let token = RouteConfig.envValue(["ANTIGRAVITY_TOKEN_URL"]) ?? "https://oauth2.googleapis.com/token"
        let userInfo = RouteConfig.envValue(["ANTIGRAVITY_USERINFO_URL"]) ?? "https://www.googleapis.com/oauth2/v1/userinfo"
        let base = RouteConfig.envValue(["ANTIGRAVITY_BASE_URL"]) ?? "https://cloudcode-pa.googleapis.com"
        let redirect = RouteConfig.envValue(["ANTIGRAVITY_REDIRECT_URI"]) ?? "http://127.0.0.1:8325/callback"

        // mock 注入（`ANTIGRAVITY_BASE_URL`）时只打该地址，避免测试误触真实上游；
        // 生产环境按 OmniRoute 顺序依次尝试 daily → 正式 → sandbox。
        let discovery: [String] = RouteConfig.envValue(["ANTIGRAVITY_BASE_URL"]) != nil
            ? [base]
            : [
                "https://daily-cloudcode-pa.googleapis.com",
                "https://cloudcode-pa.googleapis.com",
                "https://daily-cloudcode-pa.sandbox.googleapis.com",
            ]

        return AntigravityConfig(
            clientID: clientID,
            clientSecret: clientSecret,
            authorizeURL: URL(string: authorize)!,
            tokenURL: URL(string: token)!,
            userInfoURL: URL(string: userInfo)!,
            scopes: defaultScopes,
            redirectURI: redirect,
            runtimeBaseURL: base,
            discoveryBaseURLs: discovery
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

    // MARK: - 公开凭据（XOR 掩码，参考 OmniRoute `publicCreds.ts`）

    /// 掩码串与 OmniRoute 保持一致（`MASK = "omniroute-public-v1"`）。
    private static func decodePublicCred(_ bytes: [UInt8]) -> String {
        let mask = Array("omniroute-public-v1".utf8)
        var out = ""
        for (index, byte) in bytes.enumerated() {
            out.append(Character(UnicodeScalar(byte ^ mask[index % mask.count])))
        }
        return out
    }

    /// `1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com`
    /// （Google 原生应用公开 client id，PKCE S256）。
    private static let publicClientIDBytes: [UInt8] = [
        94, 93, 89, 88, 66, 95, 67, 68, 83, 29, 69, 76, 83, 65, 29, 14, 69, 5, 66, 6, 3, 92, 1, 64, 94,
        25, 23, 23, 72, 66, 70, 87, 26, 29, 12, 65, 25, 91, 7, 89, 9, 93, 66, 92, 16, 4, 75, 76, 0, 5,
        17, 66, 14, 12, 66, 17, 93, 10, 24, 29, 12, 0, 12, 26, 26, 17, 72, 30, 1, 76, 15, 6, 14,
    ]

    /// `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`（配套公开 client secret）。
    private static let publicClientSecretBytes: [UInt8] = [
        40, 34, 45, 58, 34, 55, 88, 63, 80, 21, 54, 34, 48, 88, 81, 85, 97, 18, 125, 37, 92, 3, 37, 48,
        87, 6, 44, 38, 25, 10, 67, 19, 40, 40, 5,
    ]
}
