import Foundation

/// Codex（ChatGPT 后端）用量查询器。
///
/// 上游：`GET {base}/backend-api/wham/usage`（参考 OmniRoute `services/codexQuotaFetcher.ts`）。
/// Codex 通常有**两个独立配额窗口**：primary（5h 短期）与 secondary（7d 每周）；
/// 免费版现返回 **30 天月度窗口**（月度总额）。窗口标签按真实时长（`limit_window_seconds`）标注
/// （参考 OmniRoute `windowDurationLabel`）：≤6h → "5h"、≥6d → "Weekly"、≥20d → "Monthly"，
/// 上游未提供时长时回退位置标签（"5h" / "Weekly"）。
///
/// 鉴权：`credential.accessToken`（或环境变量 `CODEX_ACCESS_TOKEN`）；
/// `chatgpt-account-id` 头带 `credential.workspaceId`（OAuth 后绑定）。
/// 401 时用 refreshToken 刷新一次并重试。
public struct CodexUsageFetcher: ProviderUsageFetcher {
    public init() {}

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        let config = CodexConfig.live()
        let oauth = CodexOAuthClient(config: config)

        guard let token = resolveAccessToken(credential) else {
            throw ProviderError.missingCredentials(
                "CODEX_ACCESS_TOKEN or config providers.codex.credential.accessToken"
            )
        }
        let refreshToken = credential.refreshToken
        let workspaceID = credential.workspaceId

        let (data, status) = try await getUsage(
            token: token,
            workspaceID: workspaceID,
            refreshToken: refreshToken,
            oauth: oauth
        )
        guard (200 ..< 300).contains(status) else {
            throw ProviderError.upstreamError(
                statusCode: status,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let windows = Self.parseQuotaWindows(from: json)
        return ProviderUsageSnapshot(
            providerID: "codex",
            quotaWindows: windows,
            rawJSON: text.isEmpty ? nil : text,
            fetchedAt: .now
        )
    }

    // MARK: - 内部

    private func resolveAccessToken(_ credential: ProviderCredential) -> String? {
        if let token = credential.accessToken, !token.isEmpty {
            return token
        }
        if let token = RouteConfig.envValue(["CODEX_ACCESS_TOKEN"]), !token.isEmpty {
            return token
        }
        return nil
    }

    /// GET wham/usage；401 时用 refreshToken 刷新一次并重试。返回 (body, statusCode)。
    private func getUsage(
        token: String,
        workspaceID: String?,
        refreshToken: String?,
        oauth: CodexOAuthClient
    ) async throws -> (Data, Int) {
        var request = URLRequest(url: CodexConfig.live().usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let workspaceID, !workspaceID.isEmpty {
            request.setValue(workspaceID, forHTTPHeaderField: "chatgpt-account-id")
        }
        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard response.statusCode == 401, let rt = refreshToken, !rt.isEmpty else {
            return (data, response.statusCode)
        }
        let refreshed = try await oauth.refreshAccessToken(refreshToken: rt)
        var retry = request
        retry.setValue("Bearer \(refreshed.accessToken)", forHTTPHeaderField: "Authorization")
        let (retryData, retryResponse) = try await ProviderHTTPClient.shared.data(for: retry)
        return (retryData, retryResponse.statusCode)
    }

    // MARK: - 解析

    /// 解析 wham/usage 响应 → `QuotaWindow` 列表。
    /// 参考 OmniRoute `services/codexUsageQuotas.ts`：
    /// - 标准 session/weekly 窗口：`rate_limit.primary_window` / `secondary_window`
    ///   （`used_percent` 为 **0-100 量纲**，如 `90` = 90% 已用）。
    /// - code_review 窗口：`code_review_rate_limit` 专用块，或 `additional_rate_limits`
    ///   中 `limit_name`/`metered_feature` 含 review 描述符的条目。
    /// 跳过 latent（从未使用、reset 恒满）窗口，避免渲染成永久的 100% 行。
    private static func parseQuotaWindows(from json: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []

        // 1) 标准 session/weekly 窗口
        if let rateLimit = (json["rate_limit"] as? [String: Any]) ?? (json["rateLimit"] as? [String: Any]) {
            let limitReached = (rateLimit["limit_reached"] as? Bool) ?? (rateLimit["limitReached"] as? Bool) ?? false
            if let window = parseWindow(rateLimit["primary_window"] ?? rateLimit["primaryWindow"],
                                        fallbackLabel: "5h", limitReached: limitReached) {
                windows.append(window)
            }
            if let window = parseWindow(rateLimit["secondary_window"] ?? rateLimit["secondaryWindow"],
                                        fallbackLabel: "Weekly", limitReached: limitReached) {
                windows.append(window)
            }
        }

        // 2) code_review 窗口（部分计划的第三个窗口）
        let review = reviewRateLimit(from: json)
        if !review.isEmpty {
            if let window = parseWindow(review["primary_window"] ?? review["primaryWindow"],
                                        fallbackLabel: "Code Review", limitReached: false) {
                windows.append(window)
            }
            if let window = parseWindow(review["secondary_window"] ?? review["secondaryWindow"],
                                        fallbackLabel: "Code Review Weekly", limitReached: false) {
                windows.append(window)
            }
        }
        return windows
    }

    /// 解析 `used_percent`（0-100 量纲）为 `QuotaWindow`；跳过 latent 窗口。
    /// 窗口标签按真实时长（`limit_window_seconds`）标注（参考 OmniRoute `windowDurationLabel`）：
    /// - 月度窗口（≥20 天）→ "Monthly"（免费版现状：wham/usage 返回 30 天月度总额）；
    /// - 周窗口（≥6 天）→ "Weekly"；会话窗口（≤6h）→ "5h"；
    /// - 上游未提供时长时回退到位置标签（"5h"/"Weekly"）。
    private static func parseWindow(_ raw: Any?, fallbackLabel: String, limitReached: Bool) -> QuotaWindow? {
        guard let window = raw as? [String: Any], !window.isEmpty else { return nil }
        guard let usedPercent = parseDouble(window["used_percent"] ?? window["usedPercent"]) else { return nil }
        if isLatentWindow(window) { return nil }

        var used = min(max(usedPercent / 100.0, 0), 1)
        if limitReached {
            used = 1
        }
        // 1 - used 的浮点尾差（如 1 - 0.8 = 0.1999…）归一化到 6 位小数，避免 UI/断言抖动。
        let remaining = ((max(0, 1 - used)) * 1_000_000).rounded() / 1_000_000
        let resetAt = parseResetAt(window)
        let unlimited = resetAt == nil && remaining >= 1
        let total = 100
        let usedCount = unlimited ? 0 : Int((Double(total) * used).rounded())
        return QuotaWindow(
            label: Self.resolveLabel(window, fallbackLabel: fallbackLabel),
            remainingFraction: remaining,
            resetAt: resetAt,
            unlimited: unlimited,
            used: usedCount,
            total: unlimited ? 0 : total
        )
    }

    /// 按真实时长推导窗口标签（参考 OmniRoute `windowDurationLabel`）：
    /// `limit_window_seconds` ≥20 天 → "Monthly"（月度窗口，免费版现状）；≥6 天 → "Weekly"；≤6h → "5h"。
    /// 上游未给时长（或无明确归属）时保留位置 fallback 标签；code_review 窗口沿用 "Code Review" 系列标签。
    private static func resolveLabel(_ window: [String: Any], fallbackLabel: String) -> String {
        // code_review 窗口（fallback "Code Review"/"Code Review Weekly"）不做时长重标注，
        // 保持现有展示（与 OmniRoute 一致：仅 session/weekly 主窗口按时长标注）。
        if fallbackLabel.contains("Review") {
            return fallbackLabel
        }
        let limitWindow = parseDouble(window["limit_window_seconds"] ?? window["limitWindowSeconds"]) ?? 0
        guard limitWindow > 0 else { return fallbackLabel }
        let day: Double = 24 * 3600
        if limitWindow >= 20 * day { return "Monthly" }
        if limitWindow >= 6 * day { return "Weekly" }
        if limitWindow <= 6 * 3600 { return "5h" }
        return fallbackLabel
    }

    /// 未使用的隐性上限（`used_percent === 0` 且 `reset_after_seconds >= limit_window_seconds`）：
    /// ChatGPT 会给未用过的功能（如 spark 桶）预告一个永远满额的隐性窗口，跳过不展示。
    private static func isLatentWindow(_ window: [String: Any]) -> Bool {
        guard let used = parseDouble(window["used_percent"] ?? window["usedPercent"]), used == 0 else {
            return false
        }
        let limitWindow = parseDouble(window["limit_window_seconds"] ?? window["limitWindowSeconds"]) ?? 0
        let resetAfter = parseDouble(window["reset_after_seconds"] ?? window["resetAfterSeconds"]) ?? 0
        return limitWindow > 0 && resetAfter >= limitWindow
    }

    /// 定位 code_review 的 rate_limit 块：`code_review_rate_limit` 专用块优先，
    /// 否则在 `additional_rate_limits` 里找 `limit_name`/`metered_feature` 含 review 的条目。
    private static func reviewRateLimit(from json: [String: Any]) -> [String: Any] {
        if let dedicated = (json["code_review_rate_limit"] as? [String: Any]) ?? (json["codeReviewRateLimit"] as? [String: Any]),
           !dedicated.isEmpty {
            return dedicated
        }
        let additional = (json["additional_rate_limits"] as? [[String: Any]]) ?? (json["additionalRateLimits"] as? [[String: Any]]) ?? []
        for entry in additional {
            let name = (entry["limit_name"] as? String) ?? (entry["limitName"] as? String) ?? ""
            let feature = (entry["metered_feature"] as? String) ?? (entry["meteredFeature"] as? String) ?? ""
            let combined = "\(name) \(feature)".lowercased()
            guard combined.contains("code_review") || combined.contains("codex_review")
                || combined.contains("code review") || combined.contains("codex review") else {
                continue
            }
            if let rateLimit = (entry["rate_limit"] as? [String: Any]) ?? (entry["rateLimit"] as? [String: Any]) {
                return rateLimit
            }
        }
        return [:]
    }

    /// 重置时间：`reset_at`（epoch 秒）或 `reset_after_seconds`（相对秒）。
    private static func parseResetAt(_ window: [String: Any]) -> Date? {
        if let resetAt = parseDouble(window["reset_at"] ?? window["resetAt"]), resetAt > 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let after = parseDouble(window["reset_after_seconds"] ?? window["resetAfterSeconds"]), after > 0 {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    /// 容错 Double：上游可能为 JSON number 或 string。
    private static func parseDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }
}
