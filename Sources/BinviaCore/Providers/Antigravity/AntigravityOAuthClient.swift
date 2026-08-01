import CryptoKit
import Foundation

/// Antigravity OAuth 登录后的凭据（accessToken / refreshToken / projectId）。
public struct AntigravityCredentials: Sendable, Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var projectId: String?
    public var email: String?
    public var expiresIn: Int?
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        projectId: String? = nil,
        email: String? = nil,
        expiresIn: Int? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.projectId = projectId
        self.email = email
        self.expiresIn = expiresIn
        self.scope = scope
    }
}

/// PKCE 对（code_verifier / code_challenge）。
public struct PKCEPair: Sendable, Equatable {
    public let codeVerifier: String
    public let codeChallenge: String

    public init(codeVerifier: String, codeChallenge: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
    }
}

/// `loadCodeAssist` + `onboardUser` 的 projectId 引导结果。
public struct AntigravityProjectInfo: Sendable, Equatable {
    public var projectId: String?
    public var tierId: String?
    public var email: String?

    public init(projectId: String? = nil, tierId: String? = nil, email: String? = nil) {
        self.projectId = projectId
        self.tierId = tierId
        self.email = email
    }
}

/// Google OAuth（authorization_code + PKCE）客户端 + projectId 引导。
///
/// 参考 OmniRoute `src/lib/oauth/providers/antigravity.ts`：
/// - `exchangeCode` 走 `oauth2.googleapis.com/token`（含 `code_verifier`）
/// - `onboardProject` 先 `loadCodeAssist` 拿 `cloudaicompanionProject`，再 `onboardUser`
/// - `login()` 通过 `openURL` 回调把授权 URL 交给调用方（CLI 集成用），
///   授权码由 `codeProvider` 提供（CLI 的 loopback 回调或用户粘贴）。
public struct AntigravityOAuthClient: Sendable {
    public let config: AntigravityConfig
    private let client: ProviderHTTPClient

    public init(config: AntigravityConfig, client: ProviderHTTPClient = .shared) {
        self.config = config
        self.client = client
    }

    // MARK: - PKCE

    public static func makePKCE() -> PKCEPair {
        // 32 随机字节 base64url（无 padding）→ 43 字符 verifier，满足 RFC 7636 (43–128)。
        let verifier = base64URL(Data(randomBytes(32)))
        let challenge = base64URL(sha256(Data(verifier.utf8)))
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 授权 URL

    /// 构造 Google authorize URL。`codeChallenge` 必填（PKCE S256）。
    public func authorizationURL(
        clientID: String? = nil,
        redirectURI: String,
        scope: String? = nil,
        state: String? = nil,
        codeChallenge: String?
    ) -> URL {
        var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID ?? config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope ?? config.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state ?? Self.randomState()),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let challenge = codeChallenge {
            query.append(URLQueryItem(name: "code_challenge", value: challenge))
            query.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components.queryItems = query
        return components.url!
    }

    // MARK: - Token

    /// 用 authorization code 换 access/refresh token。
    public func exchangeCode(
        code: String,
        verifier: String,
        redirectURI: String,
        clientID: String? = nil
    ) async throws -> AntigravityCredentials {
        var params: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": clientID ?? config.clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ]
        if let secret = config.clientSecret, !secret.isEmpty {
            params["client_secret"] = secret
        }
        let tokens = try await tokenRequest(params: params)
        return AntigravityCredentials(
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token,
            expiresIn: tokens.expires_in,
            scope: tokens.scope
        )
    }

    /// 用 refresh token 轮换 access token。
    public func refreshAccessToken(refreshToken: String) async throws -> AntigravityCredentials {
        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        // Google OAuth 拒绝空 client_id/client_secret，仅在非空时带上。
        if !config.clientID.isEmpty {
            params["client_id"] = config.clientID
        }
        if let secret = config.clientSecret, !secret.isEmpty {
            params["client_secret"] = secret
        }
        let tokens = try await tokenRequest(params: params)
        return AntigravityCredentials(
            accessToken: tokens.access_token,
            refreshToken: tokens.refresh_token ?? refreshToken,
            expiresIn: tokens.expires_in,
            scope: tokens.scope
        )
    }

    // MARK: - projectId 引导

    /// `loadCodeAssist` + `onboardUser` 获取 Google Cloud projectId。
    ///
    /// 顺序（参考 OmniRoute `postExchangeAntigravity`）：
    /// 1. `loadCodeAssist` → `cloudaicompanionProject`（string 或 `{id}`）→ projectId + tierId；
    /// 2. 有 projectId：`onboardUser` best-effort 一次；
    /// 3. 无 projectId：先 `onboardUser` 一次，再重试 `loadCodeAssist` 尝试兜底发现。
    public func onboardProject(accessToken: String) async throws -> AntigravityProjectInfo {
        var info = AntigravityProjectInfo()
        info.email = try? await fetchUserInfo(accessToken: accessToken)

        let metadata = ["ideType": "ANTIGRAVITY"]
        guard let loadData = try? await postJSON(
            url: config.loadCodeAssistURL,
            accessToken: accessToken,
            body: ["metadata": metadata]
        ) else {
            return info // 发现失败不致命，调用方回退到请求时 bootstrap
        }

        let projectId = Self.extractProjectID(from: loadData)
        let tierId = Self.extractTierID(from: loadData)
        info.projectId = projectId
        info.tierId = tierId

        if projectId != nil {
            // 已有 project：onboardUser best-effort（失败不影响返回）。
            _ = try? await postJSON(
                url: config.onboardUserURL,
                accessToken: accessToken,
                body: ["tier_id": tierId ?? "legacy-tier", "metadata": metadata]
            )
        } else {
            // 无既有 Cloud Code project：一次内联 onboarding 后重试 loadCodeAssist。
            _ = try? await postJSON(
                url: config.onboardUserURL,
                accessToken: accessToken,
                body: ["tier_id": tierId ?? "legacy-tier", "metadata": metadata]
            )
            if let retryData = try? await postJSON(
                url: config.loadCodeAssistURL,
                accessToken: accessToken,
                body: ["metadata": metadata]
            ) {
                info.projectId = Self.extractProjectID(from: retryData)
            }
        }
        return info
    }

    // MARK: - 完整登录（浏览器交互）

    /// 完整 OAuth 登录：生成 PKCE → 构造授权 URL → `openURL` 交给调用方 →
    /// `codeProvider` 返回浏览器回跳的 authorization code → 换 token → 引导 projectId。
    public func login(
        redirectURI: String? = nil,
        openURL: @escaping @Sendable (URL) -> Void,
        codeProvider: @escaping @Sendable (String) async throws -> String
    ) async throws -> AntigravityCredentials {
        let redirect = redirectURI ?? config.redirectURI
        let pkce = Self.makePKCE()
        let authURL = authorizationURL(redirectURI: redirect, codeChallenge: pkce.codeChallenge)
        openURL(authURL)
        let code = try await codeProvider(authURL.absoluteString)
        var creds = try await exchangeCode(code: code, verifier: pkce.codeVerifier, redirectURI: redirect)
        if let info = try? await onboardProject(accessToken: creds.accessToken) {
            creds.projectId = info.projectId
            creds.email = info.email
        }
        return creds
    }

    // MARK: - 内部

    private struct TokenResponse: Codable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let scope: String?
    }

    private func tokenRequest(params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.oauthUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncoded(params)
        let (data, response) = try await client.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ProviderError.invalidResponse("token 响应解析失败: \(error.localizedDescription)")
        }
    }

    private func postJSON(url: URL, accessToken: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.oauthUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await client.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("\(url.path) 响应非 JSON")
        }
        return json
    }

    private func fetchUserInfo(accessToken: String) async throws -> String? {
        var request = URLRequest(url: config.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await client.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    /// `cloudaicompanionProject` 可能是 string 或 `{id: string}`。
    static func extractProjectID(from json: [String: Any]) -> String? {
        guard let raw = json["cloudaicompanionProject"] else { return nil }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let object = raw as? [String: Any], let id = object["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// 参考 OmniRoute `extractCodeAssistOnboardTierId`（paid → current → legacy-tier）。
    static func extractTierID(from json: [String: Any]) -> String? {
        if let paid = json["paidTier"] as? [String: Any], let id = paid["id"] as? String, !id.isEmpty {
            return id
        }
        if let current = json["currentTier"] as? [String: Any], let id = current["id"] as? String, !id.isEmpty {
            return id
        }
        return "legacy-tier"
    }

    static func formEncoded(_ params: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return params.sorted { $0.key < $1.key }
            .map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)!
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        arc4random_buf(&bytes, bytes.count)
        return bytes
    }

    static func randomState() -> String {
        base64URL(Data(randomBytes(16)))
    }

    /// OAuth 与 loadCodeAssist/onboardUser 的 User-Agent（IDE 客户端指纹）。
    static let oauthUserAgent = "antigravity/ide/2.1.1 darwin/arm64"
}
