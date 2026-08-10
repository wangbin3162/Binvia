import Foundation

/// OpenCode Go web 用量查询错误分类（内部用；上层 `OpenCodeGoUsageFetcher` 统一转错误快照）。
enum OpenCodeGoWebUsageError: LocalizedError {
    case invalidCredentials
    case networkError(String)
    case apiError(String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "OpenCode Go 会话 Cookie 无效或已过期"
        case let .networkError(message):
            "OpenCode Go 用量网络错误：\(message)"
        case let .apiError(message):
            "OpenCode Go 用量接口错误：\(message)"
        case let .parseFailed(message):
            "OpenCode Go 用量解析失败：\(message)"
        }
    }
}

/// OpenCode Go web 用量结果：三窗口配额（5h/周/月）+ 可选 Zen 余额。
public struct OpenCodeGoWebUsage {
    /// 顺序固定：5h 滚动 / 周 / 月（与本地窗口索引对齐，供 overlay 合并）。
    public let windows: [QuotaWindow]
    public let balanceUSD: Double?

    public init(windows: [QuotaWindow], balanceUSD: Double?) {
        self.windows = windows
        self.balanceUSD = balanceUSD
    }
}

/// OpenCode Go web 用量查询（Cookie 链路，参考 CodexBar `OpenCodeGoUsageFetcher` web 部分）。
///
/// 抓取 `https://opencode.ai/workspace/{id}/go` 解析三窗口配额（服务端权威百分比 + 重置时间），
/// 并行抓 dashboard 页面 / `_server` billing RPC 解析 Zen 余额；余额解析失败不影响配额窗口。
///
/// 本类型只做 web 查询；local-first + overlay 合并逻辑在 `OpenCodeGoUsageFetcher`。
public struct OpenCodeGoWebUsageFetcher {
    private let client: ProviderHTTPClient

    public init(client: ProviderHTTPClient = .shared) {
        self.client = client
    }

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    /// `_server` 函数 ID（上游未公开，取自 CodexBar / 浏览器网络面板实测值）。
    public static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    public static let billingServerID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private struct ServerRequest {
        let serverID: String
        let args: String?
        let method: String
        let referer: URL
    }

    /// 完整 web 查询：workspace（override 或发现）→ 用量页 + Zen 余额。
    /// 用量页解析失败时仍尝试余额；两者皆失败才抛错。
    public func fetchUsage(
        cookieHeader: String,
        workspaceIDOverride: String?,
        now: Date = Date()
    ) async throws -> OpenCodeGoWebUsage {
        // 防御性过滤：即便调用方直接传原始 Cookie 头，也只转发 auth / __Host-auth
        guard let requestCookieHeader = OpenCodeCookieConfig.filteredHeader(from: cookieHeader) else {
            throw OpenCodeGoWebUsageError.invalidCredentials
        }
        let workspaceID: String
        if let override = OpenCodeCookieConfig.normalizeWorkspaceID(workspaceIDOverride) {
            workspaceID = override
        } else {
            workspaceID = try await fetchWorkspaceID(cookieHeader: requestCookieHeader)
        }

        let balance: Double?
        do {
            balance = try await fetchZenBalance(workspaceID: workspaceID, cookieHeader: requestCookieHeader)
        } catch {
            balance = nil
        }

        let text = try await fetchUsagePage(workspaceID: workspaceID, cookieHeader: requestCookieHeader)
        guard let windows = Self.parseWindows(text: text, now: now) else {
            // 页面解析失败但余额可用：只回余额（上层可叠加到本地窗口）
            if let balance {
                return OpenCodeGoWebUsage(windows: [], balanceUSD: balance)
            }
            throw OpenCodeGoWebUsageError.parseFailed("响应中找不到用量字段")
        }
        return OpenCodeGoWebUsage(windows: windows, balanceUSD: balance)
    }

    // MARK: - workspace 发现

    private func fetchWorkspaceID(cookieHeader: String) async throws -> String {
        let text = try await fetchServerText(
            request: ServerRequest(
                serverID: Self.workspacesServerID,
                args: nil,
                method: "GET",
                referer: Self.baseURL),
            cookieHeader: cookieHeader)
        if Self.looksSignedOut(text: text) {
            throw OpenCodeGoWebUsageError.invalidCredentials
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
                    args: "[]",
                    method: "POST",
                    referer: Self.baseURL),
                cookieHeader: cookieHeader)
            if Self.looksSignedOut(text: fallback) {
                throw OpenCodeGoWebUsageError.invalidCredentials
            }
            ids = Self.parseWorkspaceIDs(text: fallback)
            if ids.isEmpty {
                ids = Self.parseWorkspaceIDsFromJSON(text: fallback)
            }
            if ids.isEmpty {
                throw OpenCodeGoWebUsageError.parseFailed("响应中找不到 workspace id")
            }
        }
        return ids[0]
    }

    // MARK: - 用量页 / 余额

    private func fetchUsagePage(workspaceID: String, cookieHeader: String) async throws -> String {
        let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go") ?? Self.baseURL
        let text = try await fetchPageText(url: url, cookieHeader: cookieHeader)
        if Self.looksSignedOut(text: text) {
            throw OpenCodeGoWebUsageError.invalidCredentials
        }
        return text
    }

    private func fetchZenBalance(workspaceID: String, cookieHeader: String) async throws -> Double? {
        let dashboardURL = URL(string: "https://opencode.ai/workspace/\(workspaceID)") ?? Self.baseURL
        let text = try await fetchPageText(url: dashboardURL, cookieHeader: cookieHeader)
        if Self.looksSignedOut(text: text) {
            throw OpenCodeGoWebUsageError.invalidCredentials
        }
        if let balance = OpenCodeZenBalanceParser.parse(text: text) {
            return balance
        }
        // dashboard 解析不到 → billing RPC 兜底
        let billingText = try await fetchZenBillingText(workspaceID: workspaceID, cookieHeader: cookieHeader)
        if Self.looksSignedOut(text: billingText) {
            throw OpenCodeGoWebUsageError.invalidCredentials
        }
        return OpenCodeZenBalanceParser.parseBillingServerResponse(text: billingText)
    }

    private func fetchZenBillingText(workspaceID: String, cookieHeader: String) async throws -> String {
        let argsData = try JSONSerialization.data(withJSONObject: [workspaceID])
        guard let args = String(data: argsData, encoding: .utf8) else {
            throw OpenCodeGoWebUsageError.parseFailed("无法编码 billing 请求")
        }
        return try await fetchServerText(
            request: ServerRequest(
                serverID: Self.billingServerID,
                args: args,
                method: "GET",
                referer: URL(string: "https://opencode.ai/workspace/\(workspaceID)") ?? Self.baseURL),
            cookieHeader: cookieHeader)
    }

    // MARK: - HTTP

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
            urlRequest.httpBody = args.data(using: .utf8)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await client.data(for: urlRequest)
        return try Self.validateResponse(data: data, response: response)
    }

    private func fetchPageText(url: URL, cookieHeader: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ProviderHTTPClient.nonStreamingTimeout
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")

        let (data, response) = try await client.data(for: request)
        return try Self.validateResponse(data: data, response: response)
    }

    /// 统一响应校验：200 + UTF-8；401/403/登出特征 → invalidCredentials。
    private static func validateResponse(data: Data, response: HTTPURLResponse) throws -> String {
        guard response.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if looksSignedOut(text: bodyText) {
                throw OpenCodeGoWebUsageError.invalidCredentials
            }
            if response.statusCode == 401 || response.statusCode == 403 {
                throw OpenCodeGoWebUsageError.invalidCredentials
            }
            if let message = extractServerErrorMessage(from: bodyText) {
                throw OpenCodeGoWebUsageError.apiError("HTTP \(response.statusCode): \(message)")
            }
            throw OpenCodeGoWebUsageError.apiError("HTTP \(response.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeGoWebUsageError.parseFailed("响应不是 UTF-8")
        }
        return text
    }

    private static func serverRequestURL(serverID: String, args: String?, method: String) -> URL {
        guard method.uppercased() == "GET" else {
            return serverURL
        }
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "id", value: serverID)]
        if let args, !args.isEmpty {
            queryItems.append(URLQueryItem(name: "args", value: args))
        }
        components?.queryItems = queryItems
        return components?.url ?? serverURL
    }

    // MARK: - 解析

    /// 解析后的 Go 订阅用量（百分比 0...100；weekly/monthly 可缺省）。
    private struct GoSubscription {
        let rollingPercent: Double
        let weeklyPercent: Double?
        let monthlyPercent: Double?
        let rollingResetInSec: Int
        let weeklyResetInSec: Int?
        let monthlyResetInSec: Int?
    }

    /// 宽容解析三窗口：先试 JSON（多字段名 + 嵌套），再退到正则（`text/javascript` 序列化对象）。
    /// 返回顺序固定：5h 滚动 / 周 / 月（与本地窗口索引对齐，供 overlay 合并）。
    public static func parseWindows(text: String, now: Date) -> [QuotaWindow]? {
        guard let subscription = parseSubscription(text: text, now: now) else {
            return nil
        }
        var windows: [QuotaWindow] = [
            QuotaWindow(
                label: "5h 滚动",
                remainingFraction: remainingFraction(subscription.rollingPercent),
                resetAt: resetDate(inSec: subscription.rollingResetInSec, now: now)
            ),
        ]
        if let weeklyPercent = subscription.weeklyPercent,
           let weeklyReset = subscription.weeklyResetInSec
        {
            windows.append(QuotaWindow(
                label: "周配额",
                remainingFraction: remainingFraction(weeklyPercent),
                resetAt: resetDate(inSec: weeklyReset, now: now)
            ))
        }
        if let monthlyPercent = subscription.monthlyPercent,
           let monthlyReset = subscription.monthlyResetInSec
        {
            windows.append(QuotaWindow(
                label: "月配额",
                remainingFraction: remainingFraction(monthlyPercent),
                resetAt: resetDate(inSec: monthlyReset, now: now)
            ))
        }
        return windows
    }

    private static func parseSubscription(text: String, now: Date) -> GoSubscription? {
        if let snapshot = parseSubscriptionJSON(text: text, now: now) {
            return snapshot
        }
        // 正则兜底（text/javascript 序列化对象，CodexBar 实测形态）
        guard let rollingPercent = extractDouble(
            pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
            text: text),
            let rollingReset = extractInt(
                pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text)
        else {
            return nil
        }
        return GoSubscription(
            rollingPercent: rollingPercent,
            weeklyPercent: extractDouble(
                pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
                text: text),
            monthlyPercent: extractDouble(
                pattern: #"monthlyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#,
                text: text),
            rollingResetInSec: rollingReset,
            weeklyResetInSec: extractInt(
                pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text),
            monthlyResetInSec: extractInt(
                pattern: #"monthlyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#,
                text: text))
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> GoSubscription? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return nil
        }
        return parseUsageJSON(object: object, now: now)
    }

    private static func parseUsageJSON(object: Any, now: Date) -> GoSubscription? {
        guard let dict = object as? [String: Any] else { return nil }
        if let snapshot = parseUsageDictionary(dict, now: now) {
            return snapshot
        }
        for key in ["data", "result", "usage", "billing", "payload"] {
            if let nested = dict[key] as? [String: Any],
               let snapshot = parseUsageDictionary(nested, now: now)
            {
                return snapshot
            }
        }
        if let snapshot = parseUsageNested(dict, now: now, depth: 0) {
            return snapshot
        }
        return nil
    }

    private static func parseUsageDictionary(_ dict: [String: Any], now: Date) -> GoSubscription? {
        if let usage = dict["usage"] as? [String: Any],
           let snapshot = parseUsageDictionary(usage, now: now)
        {
            return snapshot
        }
        let rolling = firstDict(from: dict, keys: ["rollingUsage", "rolling", "rolling_usage", "rollingWindow"])
        let weekly = firstDict(from: dict, keys: ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow"])
        let monthly = firstDict(from: dict, keys: ["monthlyUsage", "monthly", "monthly_usage", "monthlyWindow"])
        guard let rolling, let rollingWindow = parseWindow(rolling, now: now) else { return nil }
        return GoSubscription(
            rollingPercent: rollingWindow.percent,
            weeklyPercent: weekly.flatMap { parseWindow($0, now: now)?.percent },
            monthlyPercent: monthly.flatMap { parseWindow($0, now: now)?.percent },
            rollingResetInSec: rollingWindow.resetInSec,
            weeklyResetInSec: weekly.flatMap { parseWindow($0, now: now)?.resetInSec },
            monthlyResetInSec: monthly.flatMap { parseWindow($0, now: now)?.resetInSec })
    }

    /// 兜底：任意嵌套深度内找含 rolling/weekly/monthly 字样的窗口字典。
    private static func parseUsageNested(_ dict: [String: Any], now: Date, depth: Int) -> GoSubscription? {
        if depth > 3 { return nil }
        var rolling: [String: Any]?
        var weekly: [String: Any]?
        var monthly: [String: Any]?

        for (key, value) in dict {
            guard let sub = value as? [String: Any] else { continue }
            let lower = key.lowercased()
            if lower.contains("rolling") {
                rolling = sub
            } else if lower.contains("weekly") || lower.contains("week") {
                weekly = sub
            } else if lower.contains("monthly") || lower.contains("month") {
                monthly = sub
            }
        }
        if let rolling, let rollingWindow = parseWindow(rolling, now: now) {
            return GoSubscription(
                rollingPercent: rollingWindow.percent,
                weeklyPercent: weekly.flatMap { parseWindow($0, now: now)?.percent },
                monthlyPercent: monthly.flatMap { parseWindow($0, now: now)?.percent },
                rollingResetInSec: rollingWindow.resetInSec,
                weeklyResetInSec: weekly.flatMap { parseWindow($0, now: now)?.resetInSec },
                monthlyResetInSec: monthly.flatMap { parseWindow($0, now: now)?.resetInSec })
        }
        for value in dict.values {
            if let sub = value as? [String: Any],
               let snapshot = parseUsageNested(sub, now: now, depth: depth + 1)
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

    // MARK: - workspace 解析

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
