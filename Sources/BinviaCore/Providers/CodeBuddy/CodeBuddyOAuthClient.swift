import Foundation

/// CodeBuddy CN（腾讯 copilot.tencent.com）设备码 OAuth 配置。
/// 依据：OmniRoute `src/lib/oauth/constants/oauth.ts` 的 `CODEBUDDY_CN_CONFIG`。
/// 端点为默认值，可通过 `baseURL` 或单个 endpoint 注入以便本地 mock 测试。
public struct CodeBuddyOAuthConfig: Sendable {
    public var baseURL: URL
    public var stateUrl: URL
    public var tokenUrl: URL
    public var refreshUrl: URL
    public var userAgent: String
    public var platform: String
    public var pollInterval: TimeInterval
    public var timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "https://copilot.tencent.com")!,
        stateUrl: URL? = nil,
        tokenUrl: URL? = nil,
        refreshUrl: URL? = nil,
        userAgent: String = "CLI/2.136.0 CodeBuddy/2.136.0",
        platform: String = "CLI",
        pollInterval: TimeInterval = 5,
        timeout: TimeInterval = 600
    ) {
        self.baseURL = baseURL
        self.stateUrl = stateUrl ?? baseURL.appending(path: "v2/plugin/auth/state")
        self.tokenUrl = tokenUrl ?? baseURL.appending(path: "v2/plugin/auth/token")
        self.refreshUrl = refreshUrl ?? baseURL.appending(path: "v2/plugin/auth/token/refresh")
        self.userAgent = userAgent
        self.platform = platform
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    /// 默认配置；支持用 `CODEBUDDY_CN_BASE_URL` 环境变量覆盖 base URL（本地 mock / 私有部署）。
    public static var `default`: CodeBuddyOAuthConfig {
        if let base = RouteConfig.envValue(["CODEBUDDY_CN_BASE_URL"]),
           let url = URL(string: base) {
            return CodeBuddyOAuthConfig(baseURL: url)
        }
        return CodeBuddyOAuthConfig()
    }
}

/// 设备码（state + 浏览器授权地址）。
public struct CodeBuddyDeviceCode: Sendable, Equatable {
    public let state: String
    public let authUrl: URL
    public let expiresIn: Int
    public let interval: Int

    public init(state: String, authUrl: URL, expiresIn: Int = 600, interval: Int = 5) {
        self.state = state
        self.authUrl = authUrl
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// 成功获取到的 token 集。`identity` 为登录账号标识（email / userName / nickName /
/// phoneNumber，从 token 响应或 accessToken 的 JWT payload 提取，best-effort）。
public struct CodeBuddyTokenResponse: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public let tokenType: String
    public let identity: String?

    public init(accessToken: String, refreshToken: String?, expiresIn: Int?, tokenType: String = "Bearer", identity: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.identity = identity
    }
}

public enum CodeBuddyOAuthError: Error, Sendable {
    case httpStatus(Int, String?)
    case invalidResponse(String)
    case tokenError(code: Int, message: String?)
    case timeout
}

extension CodeBuddyOAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            return "CodeBuddy OAuth HTTP \(code): \(body ?? "")"
        case .invalidResponse(let reason):
            return "CodeBuddy OAuth invalid response: \(reason)"
        case .tokenError(let code, let message):
            return "CodeBuddy OAuth error \(code): \(message ?? "")"
        case .timeout:
            return "CodeBuddy OAuth polling timed out"
        }
    }
}

/// CodeBuddy CN 设备码 OAuth 客户端。
///
/// 流程（与 OmniRoute `src/lib/oauth/providers/codebuddy-cn.ts` 一致）：
///   1. POST `stateUrl?platform=<platform>` → `{ code: 0, data: { state, authUrl } }`
///   2. 用户在浏览器打开 `authUrl`
///   3. GET `tokenUrl?state=<state>` 轮询直到 `{ code: 0, data: { accessToken } }`
///      （`code === 11217` 视为 pending，继续轮询）
/// 注意：轮询是 GET + state 查询参数（官方 CLI 的行为），不是 POST/body。
public struct CodeBuddyOAuthClient: Sendable {
    public let config: CodeBuddyOAuthConfig

    public init(config: CodeBuddyOAuthConfig = .default) {
        self.config = config
    }

    // MARK: - 设备码

    /// 请求设备码。返回 `state` + 用户需打开的 `authUrl`。
    public func requestDeviceCode() async throws -> CodeBuddyDeviceCode {
        var components = URLComponents(url: config.stateUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "platform", value: config.platform)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("copilot.tencent.com", forHTTPHeaderField: "X-Domain")
        request.setValue("true", forHTTPHeaderField: "X-No-Authorization")
        request.setValue("true", forHTTPHeaderField: "X-No-User-Id")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        // platform 需放在 query string（仅在 body 会返回 400 "platform is empty"），body 保持原样。
        request.httpBody = try JSONEncoder().encode(["platform": config.platform])

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodeBuddyOAuthError.httpStatus(response.statusCode, String(data: data, encoding: .utf8))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.intCode(json["code"]) == 0,
              let payload = json["data"] as? [String: Any],
              let state = Self.stringValue(payload["state"]), !state.isEmpty else {
            let message = jsonMessage(from: data)
            throw CodeBuddyOAuthError.invalidResponse(message)
        }
        let authURLString = Self.stringValue(payload["authUrl"]) ?? Self.stringValue(payload["url"]) ?? ""
        guard let authUrl = URL(string: authURLString), !authURLString.isEmpty else {
            throw CodeBuddyOAuthError.invalidResponse("no authUrl in device-code response")
        }
        return CodeBuddyDeviceCode(
            state: state,
            authUrl: authUrl,
            expiresIn: Self.intValue(payload["expiresIn"]) ?? 600,
            interval: max(1, Int(config.pollInterval))
        )
    }

    // MARK: - 轮询

    /// 轮询 tokenUrl 直到拿到 token（`code === 0`）；`11217` 为 pending 继续轮询；
    /// 超过 `config.timeout` 抛 `.timeout`。
    public func pollToken(state: String) async throws -> CodeBuddyTokenResponse {
        let deadline = Date().addingTimeInterval(config.timeout)
        while true {
            if let tokens = try await pollOnce(state: state) {
                return tokens
            }
            if Date() >= deadline {
                throw CodeBuddyOAuthError.timeout
            }
            try await Task.sleep(for: .seconds(config.pollInterval))
        }
    }

    /// 单次轮询。返回 nil 表示 pending（11217）。
    private func pollOnce(state: String) async throws -> CodeBuddyTokenResponse? {
        var components = URLComponents(url: config.tokenUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("copilot.tencent.com", forHTTPHeaderField: "X-Domain")
        request.setValue("true", forHTTPHeaderField: "X-No-Authorization")
        request.setValue("true", forHTTPHeaderField: "X-No-User-Id")
        request.setValue("true", forHTTPHeaderField: "X-No-Enterprise-Id")
        request.setValue("true", forHTTPHeaderField: "X-No-Department-Info")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodeBuddyOAuthError.httpStatus(response.statusCode, String(data: data, encoding: .utf8))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeBuddyOAuthError.invalidResponse(jsonMessage(from: data))
        }
        let code = Self.intCode(json["code"])
        guard let code else {
            throw CodeBuddyOAuthError.invalidResponse(jsonMessage(from: data))
        }
        if code == 0 {
            guard let payload = json["data"] as? [String: Any],
                  let accessToken = Self.stringValue(payload["accessToken"]), !accessToken.isEmpty else {
                throw CodeBuddyOAuthError.invalidResponse("success but no accessToken")
            }
            return CodeBuddyTokenResponse(
                accessToken: accessToken,
                refreshToken: Self.stringValue(payload["refreshToken"]),
                expiresIn: Self.intValue(payload["expiresIn"]),
                tokenType: Self.stringValue(payload["tokenType"]) ?? "Bearer",
                identity: Self.identity(from: payload)
            )
        }
        if code == 11217 {
            return nil // pending，继续轮询
        }
        throw CodeBuddyOAuthError.tokenError(code: code, message: Self.stringValue(json["msg"]))
    }

    // MARK: - 刷新

    /// 用 refreshToken 换取新 accessToken。
    /// 与 OmniRoute 一致：refreshToken 放在 `X-Refresh-Token` header 中，body 为空 JSON `{}`。
    public func refreshAccessToken(refreshToken: String) async throws -> CodeBuddyTokenResponse {
        var request = URLRequest(url: config.refreshUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("copilot.tencent.com", forHTTPHeaderField: "X-Domain")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Refresh-Token")
        request.setValue("plugin", forHTTPHeaderField: "X-Auth-Refresh-Source")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw CodeBuddyOAuthError.httpStatus(response.statusCode, String(data: data, encoding: .utf8))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeBuddyOAuthError.invalidResponse(jsonMessage(from: data))
        }
        let code = Self.intCode(json["code"])
        guard let code else {
            throw CodeBuddyOAuthError.invalidResponse(jsonMessage(from: data))
        }
        guard code == 0,
              let payload = json["data"] as? [String: Any],
              let accessToken = Self.stringValue(payload["accessToken"]), !accessToken.isEmpty else {
            throw CodeBuddyOAuthError.tokenError(code: code, message: Self.stringValue(json["msg"]))
        }
        return CodeBuddyTokenResponse(
            accessToken: accessToken,
            refreshToken: Self.stringValue(payload["refreshToken"]) ?? refreshToken,
            expiresIn: Self.intValue(payload["expiresIn"]),
            tokenType: Self.stringValue(payload["tokenType"]) ?? "Bearer"
        )
    }

    // MARK: - 完整登录

    /// 完整设备码登录：请求设备码 → 打印并回调 `openURL` 让用户打开授权页 → 轮询直到拿到 token。
    /// 返回 `ProviderCredential`（accessToken / refreshToken），可直接写入 config 或环境变量。
    public func login(openURL: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> ProviderCredential {
        let device = try await requestDeviceCode()
        print("CodeBuddy CN: 请在浏览器中打开以下地址完成授权：")
        print(device.authUrl.absoluteString)
        openURL(device.authUrl)
        let tokens = try await pollToken(state: device.state)
        // 登录账号标识（对齐 OAuth 型供应商显示登录用户）：token 响应字段优先，
        // accessToken 为 JWT 时再从 payload 提取（best-effort，失败不阻塞登录）。
        let identity = tokens.identity ?? Self.jwtIdentity(tokens.accessToken)
        return ProviderCredential(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            email: identity
        )
    }

    // MARK: - 工具

    /// 从 token 响应 payload / JWT claims 提取登录账号标识（best-effort）。
    /// 优先 email，其次 userName / nickName / name，最后手机号（腾讯账号常为手机号）。
    public static func identity(from payload: [String: Any]) -> String? {
        let candidates = [
            "email", "userName", "user_name", "nickName", "nick_name",
            "name", "phoneNumber", "phone_number", "phone", "enterpriseName",
        ]
        for key in candidates {
            if let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// 从 JWT accessToken 的 payload 提取登录账号标识（best-effort）。非 JWT 返回 nil。
    public static func jwtIdentity(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return identity(from: json)
    }

    private func jsonMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = Self.stringValue(json["msg"]) {
            return msg
        }
        return String(data: data, encoding: .utf8) ?? "unparseable body"
    }

    // MARK: - JSON 类型安全解析

    /// 从 Any 值中提取 String，兼容 String / Int / Double / NSNumber / Bool。
    /// 与 OmniRoute 的 `String(value)` 行为一致。
    static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            // 避免布尔值被当作数字处理
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        return nil
    }

    /// 从 Any 值中提取 Int，兼容 Int / Double / NSNumber / String。
    static func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.intValue
        }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    /// 从 Any 值中提取 Int code，兼容 Int / Double / NSNumber / String。
    static func intCode(_ value: Any?) -> Int? {
        intValue(value)
    }
}
