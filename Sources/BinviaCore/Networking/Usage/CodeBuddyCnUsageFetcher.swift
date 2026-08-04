import Foundation

/// CodeBuddy CN 用量查询器（积分消耗）。
///
/// 调腾讯 CodeBuddy **网页控制台计费接口**（参考用户提供的真实请求头）：
/// `POST https://www.codebuddy.cn/billing/meter/get-enterprise-user-usage`
/// 关键头：`x-enterprise-id`（企业 ID，从 `CODEBUDDY_CN_ENTERPRISE_ID` 环境变量或
/// `credential.workspaceId` 读取）、`x-client-platform: web`。响应：
/// ```
/// { "code": 0, "msg": "OK",
///   "data": { "credit": 8988.44, "cycleStartTime": "2026-07-21 00:00:00",
///             "cycleEndTime": "2026-08-20 23:59:59", "limitNum": 13000,
///             "cycleResetTime": "2026-08-21 00:00:00" } }
/// ```
/// - `credit`：周期**已用**积分；`limitNum`：周期**总**积分；`cycleResetTime`：下周期重置时间。
/// 归一化为单个 `QuotaWindow`（已用 = credit，总 = limitNum，剩余比例 = (limitNum − credit) / limitNum）。
/// `CODEBUDDY_CN_USAGE_URL` 环境变量可整体覆盖用量端点（测试 mock 用）。
public struct CodeBuddyCnUsageFetcher: ProviderUsageFetcher {
    public init() {}

    /// 用量端点：`CODEBUDDY_CN_USAGE_URL` 覆盖优先，默认国内官网计费接口。
    private static var usageURL: URL? {
        if let override = RouteConfig.envValue(["CODEBUDDY_CN_USAGE_URL"]), !override.isEmpty {
            return URL(string: override)
        }
        return URL(string: "https://www.codebuddy.cn/billing/meter/get-enterprise-user-usage")
    }

    /// 企业 ID：`CODEBUDDY_CN_ENTERPRISE_ID` 环境变量优先，回退 `credential.workspaceId`。
    private static func enterpriseID(credential: ProviderCredential) -> String? {
        if let env = RouteConfig.envValue(["CODEBUDDY_CN_ENTERPRISE_ID"]), !env.isEmpty {
            return env
        }
        if let stored = credential.workspaceId, !stored.isEmpty {
            return stored
        }
        return nil
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        let token: String
        if let access = credential.accessToken, !access.isEmpty {
            token = access
        } else if let env = RouteConfig.envValue(["CODEBUDDY_CN_ACCESS_TOKEN"]), !env.isEmpty {
            token = env
        } else {
            throw ProviderError.missingCredentials(
                "CODEBUDDY_CN_ACCESS_TOKEN or config providers.codebuddy-cn.credential.accessToken"
            )
        }

        guard let url = Self.usageURL else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 用量端点配置无效"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        // 企业 ID：网页控制台接口必需（缺省 400），来源见 `enterpriseID(credential:)`
        guard let enterpriseID = Self.enterpriseID(credential: credential) else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 积分查询缺少企业 ID：请在设置中填写企业 ID，或设置 CODEBUDDY_CN_ENTERPRISE_ID 环境变量（可从 www.codebuddy.cn 控制台的请求头 x-enterprise-id 获取）。"
            )
        }
        request.setValue(enterpriseID, forHTTPHeaderField: "x-enterprise-id")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        let rawText = String(data: data, encoding: .utf8) ?? ""

        // 鉴权失败：返回错误快照（提示重新登录）
        if response.statusCode == 401 || response.statusCode == 403 {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 登录已失效，请重新登录获取新的 Access Token。"
            )
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            // 带上响应 body 便于定位 400 的具体原因
            let body = rawText.isEmpty ? "" : ": \(Self.compact(rawText))"
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 积分接口错误 (\(response.statusCode))\(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 积分响应非 JSON"
            )
        }

        // 业务状态码：code != 0 → 错误快照
        if let code = Self.parseDecimal(json["code"]), code != 0 {
            let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? "unknown"
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 积分接口错误: \(msg)"
            )
        }

        // data: credit（已用积分）/ limitNum（周期总积分）/ cycleResetTime（重置时间）
        guard let data = json["data"] as? [String: Any],
              let credit = Self.parseDecimal(data["credit"]),
              let limitNum = Self.parseDecimal(data["limitNum"]),
              limitNum > 0 else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 积分响应缺少 credit / limitNum"
            )
        }

        let total = NSDecimalNumber(decimal: limitNum).doubleValue
        let used = NSDecimalNumber(decimal: credit).doubleValue
        let remaining = max(0, total - used)
        let fraction = total > 0 ? min(max(remaining / total, 0), 1) : 1
        let resetAt = Self.parseDate(data["cycleResetTime"])

        return ProviderUsageSnapshot(
            providerID: "codebuddy-cn",
            quotaWindows: [
                QuotaWindow(
                    label: "积分",
                    remainingFraction: fraction,
                    resetAt: resetAt,
                    used: Int(used.rounded()),
                    total: Int(total.rounded())
                )
            ],
            rawJSON: rawText,
            fetchedAt: .now
        )
    }

    // MARK: - 解析

    /// 压缩错误文本（>160 字符截断）。
    private static func compact(_ text: String) -> String {
        let joined = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count > 160 else { return joined }
        return String(joined.prefix(157)) + "..."
    }

    /// 周期重置时间解析：`"2026-08-21 00:00:00"`（本地时间）或 ISO8601 / 纯数字时间戳。
    /// 注意：`Decimal(string:)` 会解析数字前缀（"2026-08-21…" → 2026），
    /// 因此仅对 NSNumber / 纯数字字符串按时间戳处理。
    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let ts = number.doubleValue
            let seconds = ts < 1e12 ? ts : ts / 1000
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String, !string.isEmpty {
            if string.allSatisfy({ $0.isNumber }) {
                guard let ts = Double(string) else { return nil }
                let seconds = ts < 1e12 ? ts : ts / 1000
                guard seconds > 0 else { return nil }
                return Date(timeIntervalSince1970: seconds)
            }
            // 国内计费接口格式：yyyy-MM-dd HH:mm:ss（本地时区）
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            if let date = formatter.date(from: string) {
                return date
            }
            // ISO8601 兜底
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    /// 容错 Decimal：JSON number（NSNumber）或字符串。
    private static func parseDecimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return number.decimalValue }
        if let string = value as? String, let decimal = Decimal(string: string) { return decimal }
        return nil
    }
}
