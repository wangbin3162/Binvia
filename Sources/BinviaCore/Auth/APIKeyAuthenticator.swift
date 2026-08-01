import Foundation

/// api-key 认证。借鉴 OmniRoute `clientApi` 策略（Bearer / x-api-key / env key 白名单）。
public struct APIKeyAuthenticator: Sendable {
    private let configuredKeys: Set<String>
    private let envKeys: Set<String>

    public init(configuredKeys: [String]) {
        self.configuredKeys = Set(configuredKeys)
        var env: Set<String> = []
        for name in ["BINVIA_API_KEY", "ROUTER_API_KEY", "OMNIROUTE_API_KEY"] {
            if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
                env.insert(v)
            }
        }
        self.envKeys = env
    }

    /// 是否要求认证（配置了 key 或 env key 时要求）。
    public var requiresAuthentication: Bool {
        !configuredKeys.isEmpty || !envKeys.isEmpty
    }

    /// 校验 Authorization Bearer token 或 x-api-key。
    public func isValid(token: String?) -> Bool {
        matchedKey(token) != nil
    }

    /// 校验并返回命中的网关 Key 原文（供 gateway key 级白名单过滤用）。
    /// 未配置任何 key 时返回 nil（匿名开发模式）。
    public func matchedKey(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        if configuredKeys.contains(token) { return token }
        if envKeys.contains(token) { return token }
        return nil
    }
}
