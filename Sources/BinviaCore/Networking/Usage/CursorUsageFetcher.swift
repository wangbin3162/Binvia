import Foundation

/// Cursor Dashboard 当前计费周期用量查询器。
///
/// 对齐 OmniRoute `open-sse/services/usage/cursor.ts`：
/// `POST https://cursor.com/api/dashboard/get-current-period-usage`，使用
/// `WorkosCursorSessionToken=<userId>::<JWT>` Cookie，并带 Dashboard 的 Origin/Referer。
/// 返回 Total、Auto + Composer、API 三个配额窗口。
public struct CursorUsageFetcher: ProviderUsageFetcher {
    public init() {}

    private enum Endpoint {
        static var usage: URL {
            let value = RouteConfig.envValue(["CURSOR_USAGE_URL"])
                ?? "https://cursor.com/api/dashboard/get-current-period-usage"
            return URL(string: value)!
        }
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        var rawCredential = credential.accessToken
        if rawCredential?.isEmpty != false {
            rawCredential = RouteConfig.envValue(["CURSOR_TOKEN"])
        }
        if rawCredential?.isEmpty != false {
            rawCredential = (await CursorCredentialStore.shared.identity())?.accessToken
        }
        guard let rawCredential, !rawCredential.isEmpty else {
            throw ProviderError.missingCredentials(
                "Cursor access token missing. 请先登录 Cursor IDE 或导入 Cursor token。"
            )
        }

        let (userID, token) = Self.resolveIdentity(rawCredential)
        guard let userID, !userID.isEmpty else {
            throw ProviderError.invalidResponse(
                "Cursor token missing user id. 请重新从 Cursor IDE 导入登录 token。"
            )
        }

        var request = URLRequest(url: Endpoint.usage)
        request.httpMethod = "POST"
        request.setValue("WorkosCursorSessionToken=\(userID)::\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/spending", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        if response.statusCode == 401 || response.statusCode == 403 {
            throw ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: "Cursor session unauthorized. 请重新从 Cursor IDE 导入 token。"
            )
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: "Cursor usage endpoint error: \(String(data: data, encoding: .utf8) ?? "")"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("Cursor usage 响应非 JSON")
        }
        let planUsage = json["planUsage"] as? [String: Any] ?? [:]
        guard !planUsage.isEmpty else {
            return ProviderUsageSnapshot(
                providerID: "cursor",
                rawJSON: String(data: data, encoding: .utf8),
                fetchedAt: .now,
                error: "Cursor 当前没有返回有效的计划用量"
            )
        }

        let totalPercentUsed = Self.clamp(Self.double(planUsage["totalPercentUsed"]))
        let autoPercentUsed = Self.clamp(Self.double(planUsage["autoPercentUsed"]))
        let apiPercentUsed = Self.clamp(Self.double(planUsage["apiPercentUsed"]))
        let resetAt = Self.date(from: json["billingCycleEnd"])

        let windows = [
            Self.window(label: "总用量", percentUsed: totalPercentUsed, resetAt: resetAt),
            Self.window(label: "Auto + Composer", percentUsed: autoPercentUsed, resetAt: resetAt),
            Self.window(label: "API", percentUsed: apiPercentUsed, resetAt: resetAt),
        ]

        return ProviderUsageSnapshot(
            providerID: "cursor",
            quotaWindows: windows,
            rawJSON: String(data: data, encoding: .utf8),
            fetchedAt: .now
        )
    }

    /// 兼容 Cursor 的两种 token 形式：`userId::jwt` 与直接 JWT。
    private static func resolveIdentity(_ raw: String) -> (userID: String?, token: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = value.range(of: "::") {
            let userID = String(value[..<separator.lowerBound])
            let token = String(value[separator.upperBound...])
            return (userID.isEmpty ? nil : userID, token)
        }
        return (decodeSubject(from: value), value)
    }

    /// 从 WorkOS JWT 的 `sub` claim 读取 Cursor 用户 ID。
    private static func decodeSubject(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count % 4 != 0 { encoded.append("=") }
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = payload["sub"] as? String,
              !subject.isEmpty else {
            return nil
        }
        return subject
    }

    private static func window(label: String, percentUsed: Double, resetAt: Date?) -> QuotaWindow {
        let remaining = Self.clamp(100 - percentUsed) / 100
        let used = Int(percentUsed.rounded())
        return QuotaWindow(
            label: label,
            remainingFraction: remaining,
            resetAt: resetAt,
            used: used,
            total: 100
        )
    }

    private static func double(_ value: Any?) -> Double {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String, let number = Double(value) { return number }
        return 0
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 100)
    }

    private static func date(from value: Any?) -> Date? {
        let timestamp: Double
        if let number = value as? NSNumber {
            timestamp = number.doubleValue
        } else if let string = value as? String, let number = Double(string) {
            timestamp = number
        } else {
            return nil
        }
        guard timestamp > 0 else { return nil }
        // Cursor 返回毫秒；同时兼容测试 fixture 使用秒级时间戳。
        return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1000 : timestamp)
    }
}
