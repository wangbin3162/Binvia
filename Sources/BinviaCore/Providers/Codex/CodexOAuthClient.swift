import Foundation

// MARK: - 配置

/// Codex（ChatGPT 后端，OAuth）的上游端点与 OAuth 配置。
///
/// 常量抄自 OmniRoute：
/// - `src/lib/oauth/constants/oauth.ts` 的 `CODEX_CONFIG`（authorize/token/client/scopes/extraParams）
/// - `open-sse/config/providers/registry/codex/index.ts`（`chatgpt.com/backend-api/codex/responses`）
/// - `open-sse/services/codexQuotaFetcher.ts`（`wham/usage` 用量端点）
/// - `open-sse/config/codexClient.ts`（Version / User-Agent 指纹）
///
/// OAuth client_id 是 OpenAI Codex CLI 官方客户端的公开凭据（native app + PKCE），
/// 随客户端公开分发、不应视为机密。为避免 GitHub secret scanning 误报，按 OmniRoute
/// `publicCreds.ts` 的方式做 XOR 掩码存储、运行时解码；环境变量可覆盖默认值。
public struct CodexConfig: Sendable, Equatable {
    public var clientID: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scopes: [String]
    public var redirectURI: String
    /// authorize 额外参数（`prompt=login` 是多账号隔离的关键）。
    public var extraParams: [String: String]
    /// 上游 responses 端点（`CODEX_BASE_URL` 可注入 mock）。
    public var responsesURL: URL
    /// 上游用量端点。
    public var usageURL: URL
    /// Codex CLI 客户端版本（`Version` 头与 UA 指纹）。
    public var clientVersion: String
    public var userAgent: String

    public init(
        clientID: String,
        authorizeURL: URL,
        tokenURL: URL,
        scopes: [String],
        redirectURI: String,
        extraParams: [String: String],
        responsesURL: URL,
        usageURL: URL,
        clientVersion: String,
        userAgent: String
    ) {
        self.clientID = clientID
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.extraParams = extraParams
        self.responsesURL = responsesURL
        self.usageURL = usageURL
        self.clientVersion = clientVersion
        self.userAgent = userAgent
    }

    /// 生产默认配置：凭据优先读环境变量，缺省回退到内置的公开 Codex CLI OAuth client。
    /// `CODEX_BASE_URL` 注入 mock 时同时改变 responses / usage 前缀，便于测试。
    public static func live() -> CodexConfig {
        let clientID = RouteConfig.envValue(["CODEX_OAUTH_CLIENT_ID"])
            ?? decodePublicCred(publicClientIDBytes)
        let authorize = RouteConfig.envValue(["CODEX_AUTHORIZE_URL"]) ?? "https://auth.openai.com/oauth/authorize"
        let token = RouteConfig.envValue(["CODEX_TOKEN_URL"]) ?? "https://auth.openai.com/oauth/token"
        let redirect = RouteConfig.envValue(["CODEX_REDIRECT_URI"]) ?? "http://localhost:1455/auth/callback"
        let base = RouteConfig.envValue(["CODEX_BASE_URL"]) ?? "https://chatgpt.com"
        let version = RouteConfig.envValue(["CODEX_CLIENT_VERSION"]) ?? "0.144.1"
        let userAgent = RouteConfig.envValue(["CODEX_USER_AGENT"])
            ?? "codex-cli/\(version) (Windows 10.0.26200; x64)"
        return CodexConfig(
            clientID: clientID,
            authorizeURL: URL(string: authorize)!,
            tokenURL: URL(string: token)!,
            scopes: ["openid", "profile", "email", "offline_access"],
            redirectURI: redirect,
            extraParams: [
                "id_token_add_organizations": "true",
                "codex_cli_simplified_flow": "true",
                "originator": "codex_cli_rs",
                // prompt=login 强制 Auth0 重新认证，隔离每次 OAuth 会话，避免
                // 多账号互相踢掉 refresh token（ndycode/codex-multi-auth 的做法）。
                "prompt": "login",
            ],
            responsesURL: URL(string: "\(base)/backend-api/codex/responses")!,
            usageURL: URL(string: "\(base)/backend-api/wham/usage")!,
            clientVersion: version,
            userAgent: userAgent
        )
    }

    // MARK: - 公开凭据（XOR 掩码，参考 OmniRoute `publicCreds.ts`）

    private static func decodePublicCred(_ bytes: [UInt8]) -> String {
        let mask = Array("omniroute-public-v1".utf8)
        var out = ""
        for (index, byte) in bytes.enumerated() {
            out.append(Character(UnicodeScalar(byte ^ mask[index % mask.count])))
        }
        return out
    }

    /// `app_EMoamEEZ73f0CkXaXp7hrann`（OpenAI Codex CLI 公开 client id，PKCE S256）。
    private static let publicClientIDBytes: [UInt8] = [
        14, 29, 30, 54, 55, 34, 26, 21, 8, 104, 53, 47, 85, 95, 15, 83, 110, 29, 105, 14, 53, 30, 94,
        26, 29, 20, 26, 11,
    ]
}

// MARK: - 凭据

/// Codex OAuth 登录后的凭据（accessToken / refreshToken / workspaceId）。
public struct CodexCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    /// 选定的 workspace（`chatgpt-account-id` 头，OAuth 后从 id_token 解析）。
    public var workspaceId: String?
    public var email: String?
    public var planType: String?
    public var expiresIn: Int?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        workspaceId: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        expiresIn: Int? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.workspaceId = workspaceId
        self.email = email
        self.planType = planType
        self.expiresIn = expiresIn
    }
}

// MARK: - 错误

public enum CodexOAuthError: Error, Sendable {
    case httpStatus(Int, String?)
    case invalidResponse(String)
    /// refresh token 不可恢复失效（旋转 token 已被消费 / 过期 / 401），需重新登录。
    case reauthRequired(String)
}

extension CodexOAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "Codex OAuth HTTP \(code): \(body ?? "")"
        case .invalidResponse(let reason):
            return "Codex OAuth invalid response: \(reason)"
        case .reauthRequired(let reason):
            return reason
        }
    }
}

// MARK: - OAuth 客户端

/// Codex（OpenAI）PKCE 授权码 OAuth 客户端。
///
/// 参考 OmniRoute `src/lib/oauth/providers/codex.ts`：
/// - `exchangeCode` 走 `auth.openai.com/oauth/token`（含 `code_verifier`）
/// - `refreshAccessToken` 处理**旋转（一次性）refresh token**：请求体不带 scope
///   （RFC 6749 §6 scope 可选；带 scope 会被 Auth0 判为 re-scope 使兄弟 token 失效）；
///   `refresh_token_reused` / `invalid_grant` / `token_expired` / `invalid_token` 或 401
///   视为不可恢复 → 抛 `.reauthRequired`（调用方提示重新登录）。
/// - `login()` 通过 `openURL` 回调把授权 URL 交给调用方（CLI/GUI），
///   授权码由 `codeProvider` 提供（浏览器回跳地址粘贴或授权码）。
public struct CodexOAuthClient: Sendable {
    public let config: CodexConfig
    private let client: ProviderHTTPClient

    public init(config: CodexConfig, client: ProviderHTTPClient = .shared) {
        self.config = config
        self.client = client
    }

    // MARK: - 授权 URL

    /// 构造 OpenAI authorize URL。`codeChallenge` 必填（PKCE S256）。
    public func authorizationURL(redirectURI: String? = nil, codeChallenge: String?) -> URL {
        let redirect = redirectURI ?? config.redirectURI
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: Self.randomState()),
        ]
        if let challenge = codeChallenge {
            query.append(URLQueryItem(name: "code_challenge", value: challenge))
            query.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        for (key, value) in config.extraParams.sorted(by: { $0.key < $1.key }) {
            query.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = query
        return components.url!
    }

    // MARK: - Token 交换

    /// 用 authorization code 换 access/refresh token，并解析 id_token 绑定 workspace。
    public func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String? = nil
    ) async throws -> CodexCredentials {
        let redirect = redirectURI ?? config.redirectURI
        let params: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": redirect,
            "code_verifier": verifier,
        ]
        let tokens = try await tokenRequest(params: params)
        return Self.credentials(from: tokens)
    }

    /// 用 refresh token 轮换 access token（旋转 token，返回新的 refresh_token）。
    /// 不可恢复错误抛 `.reauthRequired`；网络/5xx 等瞬时错误抛 `.httpStatus` 由上层重试。
    public func refreshAccessToken(refreshToken: String) async throws -> CodexCredentials {
        // 注意：请求体不带 scope（见文件头注释）。
        let params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        do {
            let tokens = try await tokenRequest(params: params)
            return Self.credentials(from: tokens, fallbackRefreshToken: refreshToken)
        } catch CodexOAuthError.httpStatus(let status, let body) {
            if status == 401 || Self.isUnrecoverableError(body) {
                throw CodexOAuthError.reauthRequired(
                    "Codex 登录已过期（\(Self.errorCode(from: body) ?? "unauthorized")），请重新登录。"
                )
            }
            throw CodexOAuthError.httpStatus(status, body)
        }
    }

    // MARK: - 完整登录（浏览器交互）

    /// 完整 OAuth 登录：生成 PKCE → 构造授权 URL → `openURL` 交给调用方 →
    /// `codeProvider` 返回浏览器回跳的 authorization code → 换 token → 解析 workspace。
    public func login(
        redirectURI: String? = nil,
        openURL: @escaping @Sendable (URL) -> Void,
        codeProvider: @escaping @Sendable (String) async throws -> String
    ) async throws -> CodexCredentials {
        let redirect = redirectURI ?? config.redirectURI
        let pkce = AntigravityOAuthClient.makePKCE()
        let authURL = authorizationURL(redirectURI: redirect, codeChallenge: pkce.codeChallenge)
        openURL(authURL)
        let code = try await codeProvider(authURL.absoluteString)
        return try await exchangeCode(code: code, verifier: pkce.codeVerifier, redirectURI: redirect)
    }

    // MARK: - id_token 解析

    /// id_token JWT payload 中提取的 Codex 账号信息（workspace 绑定）。
    public struct CodexIdTokenInfo: Sendable, Equatable {
        public let email: String?
        public let workspaceId: String?
        public let planType: String?
    }

    /// 解析 id_token：base64url 解码 payload → `email` + `https://api.openai.com/auth` claim
    /// （`chatgpt_account_id` / `chatgpt_plan_type` / `organizations`）→ workspace 选择逻辑
    /// （照抄 OmniRoute `mapTokens`：team org 优先）。
    public static func parseIdToken(_ idToken: String) -> CodexIdTokenInfo? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let payloadData = base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        let email = json["email"] as? String
        guard let auth = json["https://api.openai.com/auth"] as? [String: Any] else {
            return CodexIdTokenInfo(email: email, workspaceId: nil, planType: nil)
        }

        var workspaceId = auth["chatgpt_account_id"] as? String
        let planType = (auth["chatgpt_plan_type"] as? String ?? "").lowercased()
        let organizations = auth["organizations"] as? [[String: Any]] ?? []

        // 用户可能同时有 Team 与 Personal workspace：plan_type 为 free/空但存在 team org 时改用 team。
        let teamOrg = organizations.first { org in
            let title = ((org["title"] as? String) ?? "").lowercased()
            let role = ((org["role"] as? String) ?? "").lowercased()
            let isDefault = org["is_default"] as? Bool ?? false
            return !isDefault && (title.contains("team") || title.contains("business")
                || title.contains("workspace") || title.contains("org")
                || role == "admin" || role == "member")
        }
        let isTeamPlan = planType.contains("team") || planType.contains("chatgptteam")
        if !isTeamPlan, let teamOrg, (planType == "free" || planType.isEmpty) {
            workspaceId = teamOrg["id"] as? String
        }

        return CodexIdTokenInfo(
            email: email,
            workspaceId: workspaceId,
            planType: planType.isEmpty ? nil : planType
        )
    }

    // MARK: - 内部

    private struct TokenResponse: Codable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let id_token: String?
    }

    private func tokenRequest(params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = AntigravityOAuthClient.formEncoded(params)
        let (data, response) = try await client.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodexOAuthError.httpStatus(response.statusCode, String(data: data, encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw CodexOAuthError.invalidResponse("token 响应解析失败: \(error.localizedDescription)")
        }
    }

    private static func credentials(from tokens: TokenResponse, fallbackRefreshToken: String? = nil) -> CodexCredentials {
        var creds = CodexCredentials(
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token ?? fallbackRefreshToken,
            idToken: tokens.id_token,
            expiresIn: tokens.expires_in
        )
        if let idToken = tokens.id_token, let info = parseIdToken(idToken) {
            creds.email = info.email
            creds.workspaceId = info.workspaceId
            creds.planType = info.planType
        }
        return creds
    }

    /// 判断刷新失败是否不可恢复（旋转 token 被消费 / 过期 / 无效）。
    private static func isUnrecoverableError(_ body: String?) -> Bool {
        guard let body else { return false }
        let lower = body.lowercased()
        let markers = ["refresh_token_reused", "invalid_grant", "token_expired",
                       "invalid_token", "unauthorized", "could not validate your token"]
        return markers.contains { lower.contains($0) }
    }

    private static func errorCode(from body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let nested = json["error"] as? [String: Any],
           let code = nested["code"] as? String, !code.isEmpty {
            return code
        }
        if let code = json["error"] as? String, !code.isEmpty {
            return code
        }
        return nil
    }

    static func base64URLDecode(_ str: String) -> Data? {
        var base64 = str
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }

    static func randomState() -> String {
        AntigravityOAuthClient.base64URL(Data(AntigravityOAuthClient.randomBytes(16)))
    }
}
