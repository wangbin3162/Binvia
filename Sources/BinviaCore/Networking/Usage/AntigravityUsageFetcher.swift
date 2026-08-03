import Foundation

/// Antigravity 用量查询器（Phase 16）。
///
/// 两个上游 RPC（runtimeBase 由 `AntigravityConfig.live()` 提供，尊重环境变量
/// `ANTIGRAVITY_BASE_URL`，便于 mock 测试）：
/// 1. `POST {base}/v1internal:retrieveUserQuota`（body `{"project":"<projectId>"}`）
///    → `buckets[]`：per-model 配额 → `ModelQuota`。
/// 2. `POST {base}/v1internal:retrieveUserQuotaSummary`（同 body）
///    → `groups[]`（顶层或嵌套于 `quotaSummary.groups`）：模型族 × 窗口；
///    取 combined `bucketId displayName` 含 "weekly" 的 bucket → `QuotaWindow`。
///    RPC 2 为 best-effort：失败不影响快照（quotaWindows 置空）。
///
/// 鉴权：`credential.accessToken`（或环境变量 `ANTIGRAVITY_ACCESS_TOKEN`）；
/// projectId：环境变量 `ANTIGRAVITY_PROJECT_ID` 优先，否则走 loadCodeAssist 发现。
/// 任一 RPC 返回 401 时用 refreshToken 刷新一次并重试。
///
/// 解析参考 OmniRoute `open-sse/services/usage/antigravity.ts` 与
/// `antigravityWeeklyQuota.ts`（周窗口由 bucketId/displayName 文本推断）。
public struct AntigravityUsageFetcher: ProviderUsageFetcher {
    public init() {}

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        let config = AntigravityConfig.live()
        let oauth = AntigravityOAuthClient(config: config)

        // 1. 解析 access token
        let token: String
        if let access = credential.accessToken, !access.isEmpty {
            token = access
        } else if let env = RouteConfig.envValue(["ANTIGRAVITY_ACCESS_TOKEN"]), !env.isEmpty {
            token = env
        } else {
            throw ProviderError.missingCredentials(
                "ANTIGRAVITY_ACCESS_TOKEN or config providers.antigravity.credential.accessToken"
            )
        }
        let refreshToken = credential.refreshToken

        // 2. 解析 projectId：环境变量优先，否则 loadCodeAssist 发现（401 时 refresh 一次）
        let projectID = try await resolveProjectID(
            accessToken: token,
            refreshToken: refreshToken,
            oauth: oauth
        )

        // 3. RPC 1：retrieveUserQuota（per-model 配额）
        let (quotaData, quotaStatus) = try await postRPC(
            config: config,
            accessToken: token,
            refreshToken: refreshToken,
            oauth: oauth,
            path: "v1internal:retrieveUserQuota",
            body: ["project": projectID]
        )
        guard (200 ..< 300).contains(quotaStatus) else {
            throw ProviderError.upstreamError(
                statusCode: quotaStatus,
                message: String(data: quotaData, encoding: .utf8) ?? ""
            )
        }
        let quotaText = String(data: quotaData, encoding: .utf8) ?? ""
        let quotaJSON = (try? JSONSerialization.jsonObject(with: quotaData) as? [String: Any]) ?? [:]
        let modelQuotas = Self.parseModelQuotas(from: quotaJSON)

        // 4. RPC 2：retrieveUserQuotaSummary（best-effort，失败不影响快照）
        var quotaWindows: [QuotaWindow] = []
        var summaryText = ""
        if let (summaryData, summaryStatus) = try? await postRPC(
            config: config,
            accessToken: token,
            refreshToken: refreshToken,
            oauth: oauth,
            path: "v1internal:retrieveUserQuotaSummary",
            body: ["project": projectID]
        ), (200 ..< 300).contains(summaryStatus) {
            summaryText = String(data: summaryData, encoding: .utf8) ?? ""
            let summaryJSON = (try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any]) ?? [:]
            quotaWindows = Self.parseQuotaWindows(from: summaryJSON)
        }

        // 5. 组装快照：rawJSON 合并两个 RPC 的原始文本。
        //    用量展示只保留两个核心周用量（Gemini / Claude+GPT），其余窗口与 per-model 配额不展示。
        let keptWindows = Self.filterCoreWeeklyWindows(quotaWindows)
        var raw = quotaText
        if !summaryText.isEmpty {
            raw = raw.isEmpty ? summaryText : "\(raw)\n\n\(summaryText)"
        }
        return ProviderUsageSnapshot(
            providerID: "antigravity",
            quotaWindows: keptWindows,
            modelQuotas: [],
            rawJSON: raw.isEmpty ? nil : raw,
            fetchedAt: .now
        )
    }

    // MARK: - projectId 解析

    /// 环境变量 → loadCodeAssist 发现（401 时 refresh 一次）。
    private func resolveProjectID(
        accessToken: String,
        refreshToken: String?,
        oauth: AntigravityOAuthClient
    ) async throws -> String {
        if let project = RouteConfig.envValue(["ANTIGRAVITY_PROJECT_ID"]), !project.isEmpty {
            return project
        }
        var token = accessToken
        var info: AntigravityProjectInfo?
        do {
            info = try await oauth.onboardProject(accessToken: token)
        } catch {
            if let rt = refreshToken, !rt.isEmpty,
               let refreshed = try? await oauth.refreshAccessToken(refreshToken: rt) {
                token = refreshed.accessToken
                info = try? await oauth.onboardProject(accessToken: token)
            }
        }
        if let projectID = info?.projectId, !projectID.isEmpty {
            return projectID
        }
        throw ProviderError.missingCredentials(
            "Antigravity projectId 未找到（loadCodeAssist 未返回 Cloud Code project）。请重新执行 OAuth 登录。"
        )
    }

    // MARK: - RPC 调用

    /// POST 一个 `v1internal:*` RPC；401 时用 refreshToken 刷新一次并重试。
    /// 返回 (body, statusCode)。
    private func postRPC(
        config: AntigravityConfig,
        accessToken: String,
        refreshToken: String?,
        oauth: AntigravityOAuthClient,
        path: String,
        body: [String: Any]
    ) async throws -> (Data, Int) {
        let url = URL(string: "\(config.runtimeBaseURL)/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AntigravityProvider.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    /// RPC 1：`buckets[]` → `ModelQuota`。字段：modelId / remainingFraction / resetTime。
    /// 无 remainingFraction（< 0）的 bucket 跳过。
    private static func parseModelQuotas(from json: [String: Any]) -> [ModelQuota] {
        let buckets = json["buckets"] as? [[String: Any]] ?? []
        var result: [ModelQuota] = []
        for bucket in buckets {
            guard let modelID = (bucket["modelId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !modelID.isEmpty else { continue }
            guard let rawFraction = parseDouble(bucket["remainingFraction"]), rawFraction >= 0 else { continue }
            let fraction = min(max(rawFraction, 0), 1)
            let resetAt = parseRFC3339Date(bucket["resetTime"] as? String)
            let unlimited = resetAt == nil && fraction >= 1
            result.append(ModelQuota(
                modelID: modelID,
                remainingFraction: fraction,
                resetAt: resetAt,
                unlimited: unlimited
            ))
        }
        return result
    }

    /// RPC 2：`groups[]` → weekly `QuotaWindow`。
    /// 取 combined `bucketId displayName`（小写）含 "weekly" 的 bucket；disabled 跳过；
    /// used/total 归一化到 base 1000。
    private static func parseQuotaWindows(from json: [String: Any]) -> [QuotaWindow] {
        let groups = extractGroups(from: json)
        var windows: [QuotaWindow] = []
        for group in groups {
            guard let displayName = group["displayName"] as? String, !displayName.isEmpty else { continue }
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            guard let weekly = buckets.first(where: { bucket in
                let bucketID = bucket["bucketId"] as? String ?? ""
                let bucketName = bucket["displayName"] as? String ?? ""
                return "\(bucketID) \(bucketName)".lowercased().contains("weekly")
            }) else { continue }
            if weekly["disabled"] as? Bool == true { continue }
            guard let rawFraction = parseDouble(weekly["remainingFraction"]), rawFraction >= 0 else { continue }
            let fraction = min(max(rawFraction, 0), 1)
            let resetAt = parseRFC3339Date(weekly["resetTime"] as? String)
            let unlimited = resetAt == nil && fraction >= 1
            let base = 1000
            let total = base
            let remaining = Int((Double(base) * fraction).rounded())
            let used = unlimited ? 0 : max(0, total - remaining)
            windows.append(QuotaWindow(
                label: "\(displayName) Weekly",
                remainingFraction: fraction,
                resetAt: resetAt,
                unlimited: unlimited,
                used: used,
                total: unlimited ? 0 : total
            ))
        }
        return windows
    }

    /// 只保留两个核心周用量窗口（展示用）：Gemini Models Weekly 与 Claude and GPT models Weekly。
    /// 其余窗口（如 5h 等）与 per-model 配额一律不展示，避免用量卡信息过载。
    private static func filterCoreWeeklyWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        let coreLabels = ["gemini models weekly", "claude and gpt models weekly"]
        return windows.filter { window in
            coreLabels.contains(window.label.lowercased())
        }
    }

    /// 提取 `groups[]`：容忍顶层或嵌套于 `quotaSummary.groups` 两种响应包。
    private static func extractGroups(from json: [String: Any]) -> [[String: Any]] {
        if let groups = json["groups"] as? [[String: Any]] {
            return groups
        }
        if let nested = json["quotaSummary"] as? [String: Any],
           let groups = nested["groups"] as? [[String: Any]] {
            return groups
        }
        return []
    }

    /// 容错 Double：上游可能为 JSON number 或 string。
    private static func parseDouble(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let double = Double(string) { return double }
        return nil
    }

    /// RFC3339 时间解析（含小数秒兜底）。返回 nil 表示无重置时间。
    private static func parseRFC3339Date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
