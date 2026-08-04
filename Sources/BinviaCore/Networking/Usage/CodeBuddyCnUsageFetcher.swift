import Foundation

/// CodeBuddy CN 用量查询器（参考 OmniRoute `usage/codebuddy-cn.ts`）。
///
/// 通过 OAuth 设备码登录拿到的 access token 调腾讯计费接口获取用户额度：
/// `POST {base}/v2/billing/meter/get-user-resource`（base 默认
/// `https://copilot.tencent.com`，`CODEBUDDY_CN_BASE_URL` 可覆盖），Bearer 鉴权 +
/// CodeBuddy CLI 请求头。响应 `data.Response.Data.Accounts[]` 混两类额度包：
/// - **基础体验包**（循环额度，月/周/日刷新）：`CycleEndTime` 远早于 `DeductionEndTime`
///   （>2 天），读 Cycle 字段，标签按周期；
/// - **活动赠送包**（一次性）：`CycleEndTime ≈ DeductionEndTime`，读 Capacity 字段，
///   按到期先后编号。
/// 每个包归一化为一个 `QuotaWindow`。鉴权失败 / 无额度包返回带 `error` 的快照。
public struct CodeBuddyCnUsageFetcher: ProviderUsageFetcher {
    public init() {}

    /// 循环额度包与有效期结束时间的最小间隔（>2 天判定为循环包，参考 OmniRoute REFILL_GAP_MS）。
    private static let refillGapSeconds: TimeInterval = 2 * 24 * 60 * 60

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["CODEBUDDY_CN_BASE_URL"]) ?? "https://copilot.tencent.com"
        }
        static var usage: URL { URL(string: "\(base)/v2/billing/meter/get-user-resource")! }
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

        var request = URLRequest(url: Endpoint.usage)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CLI/2.108.1 CodeBuddy/2.108.1", forHTTPHeaderField: "User-Agent")
        request.setValue("SaaS", forHTTPHeaderField: "X-Product")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Type")
        request.setValue("CLI", forHTTPHeaderField: "X-IDE-Name")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        request.setValue("1", forHTTPHeaderField: "x-codebuddy-request")
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
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 额度接口错误 (\(response.statusCode))"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 额度响应非 JSON"
            )
        }

        // 业务状态码：code != 0 → 错误快照
        if let code = Self.parseDecimal(json["code"]), code != 0 {
            let msg = (json["msg"] as? String) ?? (json["message"] as? String) ?? "unknown"
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 额度接口错误: \(msg)"
            )
        }

        // data.Response.Data.Accounts[]（双层包装，参考 OmniRoute）
        let responseDataWrapper = (json["data"] as? [String: Any]) ?? [:]
        let responseWrapper = (responseDataWrapper["Response"] as? [String: Any]) ?? [:]
        let responseData = (responseWrapper["Data"] as? [String: Any]) ?? [:]
        let accounts = (responseData["Accounts"] as? [[String: Any]]) ?? []
        guard !accounts.isEmpty else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 未查询到额度包"
            )
        }

        // 分类：循环包（refill）与一次性赠送包（bonus）
        let refills = accounts.filter { Self.isRefill($0) }
        let bonuses = accounts.filter { !Self.isRefill($0) }

        var windows: [QuotaWindow] = []
        // 循环包：按周期标签（月/周/日），同周期多个包编号区分
        var seenCadence: [String: Int] = [:]
        for account in refills.sorted(by: { Self.cycleEndSeconds($0) < Self.cycleEndSeconds($1) }) {
            let cadence = Self.refillCadence(account)
            let ordinal = (seenCadence[cadence] ?? 0) + 1
            seenCadence[cadence] = ordinal
            let label = ordinal > 1 ? "\(cadence) \(ordinal)" : cadence
            if let window = Self.quotaWindow(
                account: account,
                label: label,
                useCycleFields: true
            ) {
                windows.append(window)
            }
        }
        // 赠送包：按到期先后编号
        for (index, account) in bonuses.sorted(by: { Self.cycleEndSeconds($0) < Self.cycleEndSeconds($1) }).enumerated() {
            if let window = Self.quotaWindow(
                account: account,
                label: "赠送包 \(index + 1)",
                useCycleFields: false
            ) {
                windows.append(window)
            }
        }

        guard !windows.isEmpty else {
            return ProviderUsageSnapshot(
                providerID: "codebuddy-cn",
                fetchedAt: .now,
                error: "CodeBuddy CN 额度解析失败"
            )
        }

        return ProviderUsageSnapshot(
            providerID: "codebuddy-cn",
            quotaWindows: windows,
            rawJSON: rawText,
            fetchedAt: .now
        )
    }

    // MARK: - 解析（参考 OmniRoute codebuddy-cn.ts）

    /// 单条额度包 → QuotaWindow。`useCycleFields` 决定读 Cycle 字段（循环包）还是 Capacity 字段（赠送包）。
    private static func quotaWindow(
        account: [String: Any],
        label: String,
        useCycleFields: Bool
    ) -> QuotaWindow? {
        let used = number(account, useCycleFields ? "CycleCapacityUsedPrecise" : "CapacityUsedPrecise",
                          useCycleFields ? "CycleCapacityUsed" : "CapacityUsed")
        let total = number(account, useCycleFields ? "CycleCapacitySizePrecise" : "CapacitySizePrecise",
                           useCycleFields ? "CycleCapacitySize" : "CapacitySize")
        guard total > 0 else { return nil }
        let resetAt = parseResetTime(account["CycleEndTime"])
        let safeUsed = min(max(Int(used.rounded()), 0), Int(total.rounded()))
        let remaining = max(0, Int(total.rounded()) - safeUsed)
        return QuotaWindow(
            label: label,
            remainingFraction: Double(remaining) / total,
            resetAt: resetAt,
            used: safeUsed,
            total: Int(total.rounded())
        )
    }

    /// 是否循环额度包：CycleEndTime 与 DeductionEndTime 间隔 > 2 天（循环包先刷新、资源后到期）。
    private static func isRefill(_ account: [String: Any]) -> Bool {
        let cycleEnd = cycleEndSeconds(account)
        let deductionEnd = deductionEndSeconds(account)
        guard cycleEnd.isFinite, deductionEnd.isFinite else { return false }
        return deductionEnd - cycleEnd > refillGapSeconds
    }

    /// 周期标签：按 CycleStartTime → CycleEndTime 间隔推断（月/周/日）。
    private static func refillCadence(_ account: [String: Any]) -> String {
        guard let start = parseResetTime(account["CycleStartTime"]),
              let end = parseResetTime(account["CycleEndTime"]) else {
            return "月度包"
        }
        let days = end.timeIntervalSince(start) / 86_400
        if days <= 1.5 { return "日度包" }
        if days <= 10 { return "周度包" }
        return "月度包"
    }

    /// 精确字段（Precise 字符串）优先，回退数字字段（参考 OmniRoute num()）。
    private static func number(_ account: [String: Any], _ precise: String, _ plain: String) -> Double {
        if let value = parseDecimal(account[precise]) {
            return NSDecimalNumber(decimal: value).doubleValue
        }
        if let value = parseDecimal(account[plain]) {
            return NSDecimalNumber(decimal: value).doubleValue
        }
        return 0
    }

    private static func cycleEndSeconds(_ account: [String: Any]) -> Double {
        parseResetTime(account["CycleEndTime"])?.timeIntervalSince1970 ?? .infinity
    }

    private static func deductionEndSeconds(_ account: [String: Any]) -> Double {
        if let number = parseDecimal(account["DeductionEndTime"]) {
            let ts = NSDecimalNumber(decimal: number).doubleValue
            let seconds = ts < 1e12 ? ts : ts / 1000
            return seconds > 0 ? seconds : .infinity
        }
        return parseResetTime(account["DeductionEndTime"])?.timeIntervalSince1970 ?? .infinity
    }

    /// 容错时间解析：Date / 数字（Unix 秒 <1e12，毫秒 >=1e12）/ 纯数字字符串 / ISO8601 字符串。
    private static func parseResetTime(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = parseDecimal(value) {
            let ts = NSDecimalNumber(decimal: number).doubleValue
            let seconds = ts < 1e12 ? ts : ts / 1000
            guard seconds > 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        if let string = value as? String, !string.isEmpty, !isDigitsOnly(string) {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static func isDigitsOnly(_ string: String) -> Bool {
        !string.isEmpty && string.allSatisfy { $0.isNumber }
    }

    /// 容错 Decimal：JSON number（NSNumber）或字符串。
    private static func parseDecimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return number.decimalValue }
        if let string = value as? String, let decimal = Decimal(string: string) { return decimal }
        return nil
    }
}
