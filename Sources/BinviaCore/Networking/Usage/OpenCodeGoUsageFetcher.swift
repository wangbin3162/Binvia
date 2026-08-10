import Foundation

/// OpenCode Go 用量查询器。
///
/// 默认优先读取本机 opencode CLI 的 SQLite 用量（`OpenCodeGoLocalUsageReader`），
/// 不再依赖会 404 的公开配额端点。显式设置 `OPENCODE_GO_QUOTA_URL` 时才走 web 配额接口
/// （测试 mock 或上游开放后覆盖），web 路径参考 OmniRoute `opencodeQuotaFetcher.ts`。
///
/// 配置了浏览器 Cookie（`OPENCODE_GO_COOKIE` / 设置面板）时，在本地金额基础上叠加
/// 服务端权威配额窗口（5h/周/月剩余比例 + 重置时间）与 Zen 余额（`OpenCodeGoWebUsageFetcher`）；
/// Cookie 失效回退本地结果并提示，web 接口异常静默回退本地。
public struct OpenCodeGoUsageFetcher: ProviderUsageFetcher {
    public init() {}

    /// 用量端点：`OPENCODE_GO_QUOTA_URL` 整体覆盖优先；否则 `{base}/quota`（base 尊重
    /// `OPENCODE_GO_BASE_URL`，与 `OpenCodeGoProvider.Endpoint.base` 一致）。
    private static var usageURL: URL? {
        if let override = RouteConfig.envValue(["OPENCODE_GO_QUOTA_URL"]), !override.isEmpty {
            return URL(string: override)
        }
        let base = RouteConfig.envValue(["OPENCODE_GO_BASE_URL"]) ?? "https://opencode.ai/zen/go/v1"
        return URL(string: "\(base)/quota")
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        // 显式配额 URL 覆盖时保持 web 查询（默认端点当前 404，不主动打）。
        if let override = RouteConfig.envValue(["OPENCODE_GO_QUOTA_URL"]), !override.isEmpty {
            return try await fetchWebUsage(credential: credential)
        }

        // local-first：本机 SQLite 用量
        let local: ProviderUsageSnapshot
        do {
            local = try OpenCodeGoLocalUsageReader().fetch()
        } catch let error as OpenCodeGoLocalUsageError {
            return ProviderUsageSnapshot(
                providerID: "opencode-go",
                fetchedAt: .now,
                error: error.localizedDescription
            )
        }

        // 有 Cookie → web overlay：服务端权威配额窗口 + Zen 余额叠加到本地金额
        guard let cookie = OpenCodeCookieConfig.resolveCookieHeader(providerID: "opencode-go", credential: credential)
        else {
            return local
        }
        do {
            let override = OpenCodeCookieConfig.resolveWorkspaceID(providerID: "opencode-go", credential: credential)
            let web = try await OpenCodeGoWebUsageFetcher().fetchUsage(
                cookieHeader: cookie,
                workspaceIDOverride: override,
                now: .now)
            return Self.merge(local: local, web: web)
        } catch let error as OpenCodeGoWebUsageError {
            switch error {
            case .invalidCredentials:
                // Cookie 过期：回退本地并提示
                return ProviderUsageSnapshot(
                    providerID: "opencode-go",
                    quotaWindows: local.quotaWindows,
                    rawJSON: local.rawJSON,
                    fetchedAt: .now,
                    error: "OpenCode Go 会话 Cookie 无效或已过期，已回退本机用量"
                )
            default:
                // 其他 web 失败（接口/解析变化）：静默回退本地
                return local
            }
        } catch {
            return local
        }
    }

    /// 把 web 权威剩余比例/重置时间叠加到本地金额窗口（按 5h/周/月 索引对齐），
    /// 附带 Zen 余额；web 窗口缺省时保留对应本地窗口。
    private static func merge(local: ProviderUsageSnapshot, web: OpenCodeGoWebUsage) -> ProviderUsageSnapshot {
        var windows = local.quotaWindows
        for index in windows.indices where index < web.windows.count {
            let localWindow = windows[index]
            let webWindow = web.windows[index]
            windows[index] = QuotaWindow(
                label: localWindow.label,
                remainingFraction: webWindow.remainingFraction,
                resetAt: webWindow.resetAt,
                used: localWindow.used,
                total: localWindow.total
            )
        }
        var balance: Decimal?
        var currency: String?
        if let usd = web.balanceUSD, usd.isFinite {
            balance = Decimal(usd)
            currency = "USD"
        }
        return ProviderUsageSnapshot(
            providerID: "opencode-go",
            balance: balance,
            currency: currency,
            quotaWindows: windows,
            rawJSON: local.rawJSON,
            fetchedAt: .now
        )
    }

    /// Web 配额查询：`GET {base}/quota` → 三窗口配额（$12/5h、$30/周、$60/月）。
    private func fetchWebUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        let key: String
        if let apiKey = credential.apiKey, !apiKey.isEmpty {
            key = apiKey
        } else if let env = RouteConfig.envValue(["OPENCODE_GO_API_KEY"]), !env.isEmpty {
            key = env
        } else {
            throw ProviderError.missingCredentials(
                "OPENCODE_GO_API_KEY or config providers.opencode-go.credential.apiKey"
            )
        }

        guard let url = Self.usageURL else {
            return ProviderUsageSnapshot(
                providerID: "opencode-go",
                fetchedAt: .now,
                error: "OpenCode Go 用量端点配置无效"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)

        // 非 2xx（含配额 API 未公开的 404）：返回错误快照而非崩溃
        guard (200 ..< 300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            return ProviderUsageSnapshot(
                providerID: "opencode-go",
                fetchedAt: .now,
                error: body.isEmpty
                    ? "OpenCode Go 用量接口返回 \(response.statusCode)"
                    : "OpenCode Go 用量接口返回 \(response.statusCode): \(Self.compact(body))"
            )
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = Self.parseQuotaWindows(from: json), !windows.isEmpty else {
            return ProviderUsageSnapshot(
                providerID: "opencode-go",
                fetchedAt: .now,
                error: "OpenCode Go 用量响应解析失败"
            )
        }

        return ProviderUsageSnapshot(
            providerID: "opencode-go",
            quotaWindows: windows,
            rawJSON: raw,
            fetchedAt: .now
        )
    }

    // MARK: - 解析（参考 OmniRoute parseOpencodeQuotaResponse）

    private static func parseQuotaWindows(from json: [String: Any]) -> [QuotaWindow]? {
        let quota = (json["quota"] as? [String: Any])
            ?? (json["data"] as? [String: Any])
            ?? (json["usage"] as? [String: Any])
            ?? json

        var windows: [QuotaWindow] = []
        if let window = parseWindow(quota, keys: ["window_5h", "5h", "hourly", "short"], label: "$12 / 5小时") {
            windows.append(window)
        }
        if let window = parseWindow(quota, keys: ["window_weekly", "weekly", "week", "wk"], label: "$30 / 周") {
            windows.append(window)
        }
        if let window = parseWindow(quota, keys: ["window_monthly", "monthly", "month", "mo"], label: "$60 / 月") {
            windows.append(window)
        }
        return windows.isEmpty ? nil : windows
    }

    /// 单个窗口：used/limit（或 used_amount/limit_amount）→ 剩余比例；
    /// 重置时间：`reset_at`（Unix 秒 <1e12 / 毫秒 >=1e12）或 `reset_after_seconds`（当前时间 + 秒）。
    private static func parseWindow(_ quota: [String: Any], keys: [String], label: String) -> QuotaWindow? {
        var window: [String: Any]?
        for key in keys {
            if let candidate = quota[key] as? [String: Any] {
                window = candidate
                break
            }
        }
        guard let window else { return nil }

        let used = parseDouble(window["used"] ?? window["used_amount"]) ?? 0
        let limit = parseDouble(window["limit"] ?? window["limit_amount"]) ?? 0
        guard limit > 0 else { return nil }

        let percent = min(max(used / limit, 0), 1)
        let resetAt = parseReset(window)
        let total = Int(limit.rounded())
        let usedInt = Int((percent * limit).rounded())
        return QuotaWindow(
            label: label,
            remainingFraction: 1 - percent,
            resetAt: resetAt,
            used: usedInt,
            total: total
        )
    }

    private static func parseReset(_ window: [String: Any]) -> Date? {
        if let resetAt = parseDouble(window["reset_at"] ?? window["resetAt"]), resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt < 1e12 ? resetAt : resetAt / 1000)
        }
        if let after = parseDouble(window["reset_after_seconds"] ?? window["resetAfterSeconds"]),
           after > 0 {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    /// 容错 Double：上游可能为 JSON number（NSNumber）或 string。
    private static func parseDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    /// 压缩错误文本（>160 字符截断）。
    private static func compact(_ text: String) -> String {
        let joined = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > 160 else { return joined }
        return String(joined.prefix(157)) + "..."
    }
}
