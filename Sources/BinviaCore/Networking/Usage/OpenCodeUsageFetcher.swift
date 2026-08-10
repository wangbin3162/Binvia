import Foundation

/// OpenCode 用量查询错误分类（内部用；对外统一转成错误快照，不抛给 GUI）。
enum OpenCodeUsageError: LocalizedError {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "OpenCode 会话 Cookie 无效或已过期，请在设置面板更新（或重设 OPENCODE_COOKIE）"
        case let .networkError(message):
            "OpenCode 用量网络错误：\(message)"
        case let .apiError(message):
            "OpenCode 用量接口错误：\(message)"
        case let .parseFailed(message):
            "OpenCode 用量解析失败：\(message)"
        }
    }
}

/// OpenCode 用量查询器（Cookie web 链路，参考 CodexBar `OpenCodeUsageFetcher`）。
///
/// 上游没有公开的用量 API，用 `opencode.ai` 浏览器 Cookie 调 `_server` RPC：
/// 1. `_server?id=<workspaces>` → 拿 `wrk_...`（可用 `OPENCODE_WORKSPACE_ID` / 设置面板跳过）；
/// 2. `_server?id=<subscription.get>&args=[workspaceID]` → 拿 rollingUsage / weeklyUsage。
///
/// 无 Cookie / Cookie 失效 / 解析失败一律返回带 `error` 的快照（不崩溃）；
/// 网络异常同样收敛为错误快照，保证轮询 Timer 与 GUI 稳定。
public struct OpenCodeUsageFetcher: ProviderUsageFetcher {
    private let client: ProviderHTTPClient

    public init() {
        self.client = .shared
    }

    /// 测试注入用：自定义 URLSession（URLProtocolMock）。
    public init(client: ProviderHTTPClient) {
        self.client = client
    }

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    /// `_server` 函数 ID（上游未公开，取自 CodexBar / 浏览器网络面板实测值）。
    public static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    public static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private struct ServerRequest {
        let serverID: String
        let args: [Any]?
        let method: String
        let referer: URL
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        guard let cookie = OpenCodeCookieConfig.resolveCookieHeader(providerID: "opencode", credential: credential)
        else {
            return errorSnapshot("未配置 OpenCode 浏览器 Cookie：请在设置面板粘贴（或设置 OPENCODE_COOKIE）")
        }

        do {
            let workspaceID: String
            if let override = OpenCodeCookieConfig.resolveWorkspaceID(providerID: "opencode", credential: credential) {
                workspaceID = override
            } else {
                workspaceID = try await fetchWorkspaceID(cookieHeader: cookie)
            }
            let text = try await fetchSubscriptionInfo(workspaceID: workspaceID, cookieHeader: cookie)
            guard let subscription = Self.parseSubscription(text: text, now: .now) else {
                return errorSnapshot("OpenCode 用量响应解析失败（响应中找不到用量字段）")
            }

            var windows: [QuotaWindow] = [
                QuotaWindow(
                    label: "5h 滚动",
                    remainingFraction: Self.remainingFraction(subscription.rollingPercent),
                    resetAt: Self.resetDate(inSec: subscription.rollingResetInSec, now: .now)
                ),
            ]
            if subscription.weeklyPercent > 0 || subscription.weeklyResetInSec > 0 {
                windows.append(QuotaWindow(
                    label: "周配额",
                    remainingFraction: Self.remainingFraction(subscription.weeklyPercent),
                    resetAt: Self.resetDate(inSec: subscription.weeklyResetInSec, now: .now)
                ))
            }
            if let renewsAt = subscription.renewsAt {
                windows.append(QuotaWindow(
                    label: "订阅续订",
                    remainingFraction: 1,
                    resetAt: renewsAt
                ))
            }

            return ProviderUsageSnapshot(
                providerID: "opencode",
                quotaWindows: windows,
                rawJSON: text,
                fetchedAt: .now
            )
        } catch let error as OpenCodeUsageError {
            return errorSnapshot(error.localizedDescription)
        } catch {
            return errorSnapshot("OpenCode 用量查询失败：\(error.localizedDescription)")
        }
    }

    private func errorSnapshot(_ message: String) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(providerID: "opencode", fetchedAt: .now, error: message)
    }

    // MARK: - _server RPC

    private func fetchWorkspaceID(cookieHeader: String) async throws -> String {
        let text = try await fetchServerText(
            request: ServerRequest(
                serverID: Self.workspacesServerID,
                args: nil,
                method: "GET",
                referer: Self.baseURL),
            cookieHeader: cookieHeader)
        if Self.looksSignedOut(text: text) {
            throw OpenCodeUsageError.invalidCredentials
        }
        var ids = Self.parseWorkspaceIDs(text: text)
        if ids.isEmpty {
            ids = Self.parseWorkspaceIDsFromJSON(text: text)
        }
        if ids.isEmpty {
            // GET 拿不到 workspace 时按 CodexBar 实测兜底 POST 重试
            let fallback = try await fetchServerText(
                request: ServerRequest(
                    serverID: Self.workspacesServerID,
                    args: [],
                    method: "POST",
                    referer: Self.baseURL),
                cookieHeader: cookieHeader)
            if Self.looksSignedOut(text: fallback) {
                throw OpenCodeUsageError.invalidCredentials
            }
            ids = Self.parseWorkspaceIDs(text: fallback)
            if ids.isEmpty {
                ids = Self.parseWorkspaceIDsFromJSON(text: fallback)
            }
            if ids.isEmpty {
                throw OpenCodeUsageError.parseFailed("响应中找不到 workspace id")
            }
        }
        return ids[0]
    }

    private func fetchSubscriptionInfo(workspaceID: String, cookieHeader: String) async throws -> String {
        let referer = URL(string: "https://opencode.ai/workspace/\(workspaceID)/billing") ?? Self.baseURL
        let text = try await fetchServerText(
            request: ServerRequest(
                serverID: Self.subscriptionServerID,
                args: [workspaceID],
                method: "GET",
                referer: referer),
            cookieHeader: cookieHeader)
        if Self.looksSignedOut(text: text) {
            throw OpenCodeUsageError.invalidCredentials
        }
        if Self.isExplicitNullPayload(text: text) {
            throw OpenCodeUsageError.apiError(
                "该 workspace 没有 OpenCode 订阅配额数据（免费或 Go 计划无此窗口；若用 OpenCode Go 请看 opencode-go 用量）")
        }
        if Self.parseSubscription(text: text, now: .now) == nil {
            // GET payload 缺用量字段时 POST 兜底（CodexBar 实测路径）
            let fallback = try await fetchServerText(
                request: ServerRequest(
                    serverID: Self.subscriptionServerID,
                    args: [workspaceID],
                    method: "POST",
                    referer: referer),
                cookieHeader: cookieHeader)
            if Self.looksSignedOut(text: fallback) {
                throw OpenCodeUsageError.invalidCredentials
            }
            return fallback
        }
        return text
    }

    private func fetchServerText(
        request serverRequest: ServerRequest,
        cookieHeader: String
    ) async throws -> String {
        let url = Self.serverRequestURL(
            serverID: serverRequest.serverID,
            args: serverRequest.args,
            method: serverRequest.method)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = serverRequest.method
        urlRequest.timeoutInterval = ProviderHTTPClient.nonStreamingTimeout
        urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        urlRequest.setValue(serverRequest.serverID, forHTTPHeaderField: "X-Server-Id")
        urlRequest.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        urlRequest.setValue(serverRequest.referer.absoluteString, forHTTPHeaderField: "Referer")
        urlRequest.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if serverRequest.method.uppercased() != "GET",
           let args = serverRequest.args
        {
            let body = try JSONSerialization.data(withJSONObject: args, options: [])
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await client.data(for: urlRequest)
        guard response.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if Self.looksSignedOut(text: bodyText) {
                throw OpenCodeUsageError.invalidCredentials
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw OpenCodeUsageError.invalidCredentials
            }
            if let message = Self.extractServerErrorMessage(from: bodyText) {
                throw OpenCodeUsageError.apiError("HTTP \(response.statusCode): \(message)")
            }
            throw OpenCodeUsageError.apiError("HTTP \(response.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeUsageError.parseFailed("响应不是 UTF-8")
        }
        return text
    }

    private static func serverRequestURL(serverID: String, args: [Any]?, method: String) -> URL {
        guard method.uppercased() == "GET" else {
            return serverURL
        }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: args, options: []),
           let encodedArgs = String(data: data, encoding: .utf8)
        {
            queryItems.append(URLQueryItem(name: "args", value: encodedArgs))
        }
        components?.queryItems = queryItems
        return components?.url ?? serverURL
    }

    // MARK: - 解析

    /// 解析后的订阅用量（百分比 0...100 + 重置秒数）。
    public struct Subscription {
        public let rollingPercent: Double
        public let weeklyPercent: Double
        public let rollingResetInSec: Int
        public let weeklyResetInSec: Int
        public let renewsAt: Date?

        public init(
            rollingPercent: Double,
            weeklyPercent: Double,
            rollingResetInSec: Int,
            weeklyResetInSec: Int,
            renewsAt: Date?
        ) {
            self.rollingPercent = rollingPercent
            self.weeklyPercent = weeklyPercent
            self.rollingResetInSec = rollingResetInSec
            self.weeklyResetInSec = weeklyResetInSec
            self.renewsAt = renewsAt
        }
    }

    /// 宽容解析：先试 JSON（多字段名 + 嵌套），再退到正则（`text/javascript` 序列化对象）。
    public static func parseSubscription(text: String, now: Date) -> Subscription? {
        if let snapshot = parseSubscriptionJSON(text: text, now: now) {
            return snapshot
        }
        guard let rollingPercent = extractDouble(
            pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text),
            let rollingReset = extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text)
        else {
            return nil
        }
        let weeklyPercent = extractDouble(
            pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text) ?? 0
        let weeklyReset = extractInt(
            pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
            text: text) ?? 0
        return Subscription(
            rollingPercent: rollingPercent,
            weeklyPercent: weeklyPercent,
            rollingResetInSec: rollingReset,
            weeklyResetInSec: weeklyReset,
            renewsAt: nil)
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> Subscription? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return nil
        }
        return parseUsageJSON(object: object, now: now)
    }

    private static func parseUsageJSON(object: Any, now: Date) -> Subscription? {
        guard let dict = object as? [String: Any] else { return nil }
        let renewsAt = dateValue(from: value(from: dict, keys: ["renewAt", "renew_at"]))

        if let snapshot = parseUsageDictionary(dict, now: now, inheritedRenewsAt: renewsAt) {
            return snapshot
        }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = parseUsageDictionary(nested, now: now, inheritedRenewsAt: renewsAt)
            {
                return snapshot
            }
        }
        if let snapshot = parseUsageNested(dict, now: now, depth: 0, inheritedRenewsAt: renewsAt) {
            return snapshot
        }
        return nil
    }

    private static func parseUsageDictionary(
        _ dict: [String: Any],
        now: Date,
        inheritedRenewsAt: Date?
    ) -> Subscription? {
        let renewsAt = dateValue(from: value(from: dict, keys: ["renewAt", "renew_at"])) ?? inheritedRenewsAt
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = parseUsageDictionary(usage, now: now, inheritedRenewsAt: renewsAt)
        {
            return snapshot
        }
        let rolling = firstDict(from: dict, keys: ["rollingUsage", "rolling", "rolling_usage", "rollingWindow"])
        let weekly = firstDict(from: dict, keys: ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow"])
        guard let rolling else { return nil }
        guard let rollingWindow = parseWindow(rolling, now: now) else { return nil }
        let weeklyWindow = weekly.flatMap { parseWindow($0, now: now) }
        return Subscription(
            rollingPercent: rollingWindow.percent,
            weeklyPercent: weeklyWindow?.percent ?? 0,
            rollingResetInSec: rollingWindow.resetInSec,
            weeklyResetInSec: weeklyWindow?.resetInSec ?? 0,
            renewsAt: renewsAt)
    }

    /// 兜底：任意嵌套深度内找含 rolling/weekly 字样的窗口字典。
    private static func parseUsageNested(
        _ dict: [String: Any],
        now: Date,
        depth: Int,
        inheritedRenewsAt: Date?
    ) -> Subscription? {
        if depth > 3 { return nil }
        let renewsAt = dateValue(from: value(from: dict, keys: ["renewAt", "renew_at"])) ?? inheritedRenewsAt
        var rolling: [String: Any]?
        var weekly: [String: Any]?

        for (key, sub) in dict {
            guard let sub = sub as? [String: Any] else { continue }
            let lower = key.lowercased()
            if lower.contains("rolling") {
                rolling = sub
            } else if lower.contains("weekly") || lower.contains("week") {
                weekly = sub
            }
        }
        if let rolling, let rollingWindow = parseWindow(rolling, now: now) {
            let weeklyWindow = weekly.flatMap { parseWindow($0, now: now) }
            return Subscription(
                rollingPercent: rollingWindow.percent,
                weeklyPercent: weeklyWindow?.percent ?? 0,
                rollingResetInSec: rollingWindow.resetInSec,
                weeklyResetInSec: weeklyWindow?.resetInSec ?? 0,
                renewsAt: renewsAt)
        }
        for value in dict.values {
            if let sub = value as? [String: Any],
               let snapshot = parseUsageNested(sub, now: now, depth: depth + 1, inheritedRenewsAt: renewsAt)
            {
                return snapshot
            }
        }
        return nil
    }

    private static func parseWindow(_ dict: [String: Any], now: Date) -> (percent: Double, resetInSec: Int)? {
        var percent = doubleValue(from: dict, keys: [
            "usagePercent", "usedPercent", "percentUsed", "percent",
            "usage_percent", "used_percent", "utilization", "utilizationPercent",
        ])
        let percentIsDirect = percent != nil
        if percent == nil {
            let used = doubleValue(from: dict, keys: ["used", "usage", "consumed", "count", "usedTokens"])
            let limit = doubleValue(from: dict, keys: ["limit", "total", "quota", "max", "cap", "tokenLimit"])
            if let used, let limit, limit > 0 {
                percent = (used / limit) * 100
            }
        }
        guard var resolvedPercent = percent else { return nil }
        // 直接 percent 字段可能是 0...1 的小数或 0...100 的百分数；used/limit 推算值恒为 0...100
        if percentIsDirect, resolvedPercent <= 1.0, resolvedPercent >= 0 {
            resolvedPercent *= 100
        }
        resolvedPercent = max(0, min(100, resolvedPercent))

        var resetInSec = intValue(from: dict, keys: [
            "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec",
            "reset_in_sec", "resetsInSec", "resetsInSeconds", "resetIn",
        ])
        if resetInSec == nil {
            let resetAt = dateValue(from: value(from: dict, keys: [
                "resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset",
            ]))
            if let resetAt {
                resetInSec = max(0, Int(resetAt.timeIntervalSince(now)))
            }
        }
        return (resolvedPercent, max(0, resetInSec ?? 0))
    }

    public static func parseWorkspaceIDs(text: String) -> [String] {
        let pattern = #"id\s*:\s*\"(wrk_[^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: nsrange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func parseWorkspaceIDsFromJSON(text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return []
        }
        var results: [String] = []
        collectWorkspaceIDs(object: object, out: &results)
        return results
    }

    private static func collectWorkspaceIDs(object: Any, out: inout [String]) {
        if let dict = object as? [String: Any] {
            for value in dict.values {
                collectWorkspaceIDs(object: value, out: &out)
            }
            return
        }
        if let array = object as? [Any] {
            for value in array {
                collectWorkspaceIDs(object: value, out: &out)
            }
            return
        }
        if let string = object as? String,
           string.hasPrefix("wrk_"),
           !out.contains(string)
        {
            out.append(string)
        }
    }

    // MARK: - 小工具

    private static func remainingFraction(_ percent: Double) -> Double {
        max(0, min(1, 1 - percent / 100))
    }

    private static func resetDate(inSec: Int, now: Date) -> Date {
        now.addingTimeInterval(TimeInterval(max(0, inSec)))
    }

    static func isExplicitNullPayload(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("null") == .orderedSame {
            return true
        }
        // _server 返回 text/javascript 序列化形态：`...=[],null)`（含 0x 长度前缀）。
        // 裸 JSON `null` 之外，这种 JS 包装的 null 同样是「无数据」，不能触发 POST 兜底。
        if let regex = try? NSRegularExpression(pattern: #"\]\s*,\s*null\s*\)\s*$"#, options: []),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) != nil
        {
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return false
        }
        return object is NSNull
    }

    static func looksSignedOut(text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login")
            || lower.contains("sign in")
            || lower.contains("auth/authorize")
            || lower.contains("not associated with an account")
            || lower.contains("actor of type \"public\"")
    }

    private static func extractServerErrorMessage(from text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = object as? [String: Any]
        {
            if let message = dict["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = dict["error"] as? String, !error.isEmpty {
                return error
            }
            if let detail = dict["detail"] as? String, !detail.isEmpty {
                return detail
            }
        }
        if let match = text.range(of: #"(?i)<title>([^<]+)</title>"#, options: .regularExpression) {
            return String(text[match].dropFirst(7).dropLast(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[range])
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
    }

    private static func doubleValue(from value: Any?) -> Double? {
        let number: Double? = switch value {
        case let number as Double:
            number
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let number as Int:
            number
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private static func doubleValue(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = doubleValue(from: dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func intValue(from dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = intValue(from: dict[key]) {
                return value
            }
        }
        return nil
    }

    private static func value(from dict: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = dict[key] {
                return value
            }
        }
        return nil
    }

    private static func firstDict(from dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] {
                return value
            }
        }
        return nil
    }

    private static func dateValue(from value: Any?) -> Date? {
        guard let value else { return nil }
        if let number = doubleValue(from: value) {
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        if let string = value as? String {
            if let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return dateValue(from: number)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) {
                return parsed
            }
        }
        return nil
    }
}
