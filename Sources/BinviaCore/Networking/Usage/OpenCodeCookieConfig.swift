import Foundation

/// OpenCode / OpenCode Go 网页会话 Cookie 与 workspace 配置解析。
///
/// 上游没有公开的用量 API（`GET /zen/go/v1/quota` 404），CodexBar 验证了用 `opencode.ai`
/// 浏览器 Cookie 调 `_server` RPC / 抓 dashboard 页面的可行链路。本工具负责：
/// - 从环境变量 / `ProviderCredential` 解析 Cookie 头，仅保留 `auth` / `__Host-auth`（隐私过滤）；
/// - workspace ID 归一化（`wrk_...` / 完整 URL），env 优先回退 `credential.workspaceId`。
public enum OpenCodeCookieConfig {
    /// 请求实际携带的 Cookie 名白名单：只转发认证会话，不转发其他跟踪/偏好 Cookie。
    private static let requestCookieNames: Set<String> = ["auth", "__Host-auth"]

    /// 从完整 Cookie 头中过滤出请求需要的字段（`name=value` 列表，`; ` 连接）。
    /// 无有效认证字段时返回 nil（调用方按「未配置 Cookie」处理）。
    ///
    /// 兼容两种粘贴形态：
    /// 1. 完整 Cookie 头（`auth=...; __Host-auth=...; theme=...`）→ 仅保留认证字段；
    /// 2. 裸值（从浏览器 Application → Cookies 复制的 `auth` cookie 值本身）→ 自动包装为 `auth=<值>`。
    public static func filteredHeader(from rawHeader: String?) -> String? {
        guard let rawHeader, !rawHeader.isEmpty else { return nil }
        let trimmed = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        // 不含 `=`：视为 auth cookie 值本身（iron-session 加密串），包装成 auth=value
        if !trimmed.contains("=") {
            return "auth=\(trimmed)"
        }
        let pairs = trimmed
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { pair -> String? in
                guard let eq = pair.firstIndex(of: "=") else { return nil }
                let name = String(pair[..<eq])
                guard requestCookieNames.contains(name) else { return nil }
                return pair
            }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    /// 解析请求 Cookie 头：env（`OPENCODE_COOKIE` / `OPENCODE_GO_COOKIE`）优先，
    /// 回退 `credential.cookieHeader`；过滤后仍为空返回 nil。
    public static func resolveCookieHeader(providerID: String, credential: ProviderCredential?) -> String? {
        let envName: String
        if providerID == "opencode-go" || providerID == "opencodego" {
            envName = "OPENCODE_GO_COOKIE"
        } else {
            envName = "OPENCODE_COOKIE"
        }
        let raw = RouteConfig.envValue([envName]) ?? credential?.cookieHeader
        return filteredHeader(from: raw)
    }

    /// 归一化 workspace：接受 `wrk_...` ID、完整 `https://opencode.ai/workspace/...` URL、
    /// 或字符串中内嵌的 `wrk_...`。无法识别返回 nil。
    public static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 {
            return trimmed
        }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"),
               parts.count > index + 1
            {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 {
                    return candidate
                }
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    /// 解析 workspace override：env（`OPENCODE_WORKSPACE_ID` / `OPENCODE_GO_WORKSPACE_ID`）优先，
    /// 回退 `credential.workspaceId`；均无效返回 nil（调用方走 workspace 发现）。
    public static func resolveWorkspaceID(providerID: String, credential: ProviderCredential?) -> String? {
        let envName: String
        if providerID == "opencode-go" || providerID == "opencodego" {
            envName = "OPENCODE_GO_WORKSPACE_ID"
        } else {
            envName = "OPENCODE_WORKSPACE_ID"
        }
        let raw = RouteConfig.envValue([envName]) ?? credential?.workspaceId
        return normalizeWorkspaceID(raw)
    }
}
