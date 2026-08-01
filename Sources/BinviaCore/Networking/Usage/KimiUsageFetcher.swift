import Foundation

/// Kimi（Moonshot）余额查询器。
///
/// 打 `GET {base}/users/me/balance`（Bearer apiKey）。Moonshot 余额接口返回
/// `{"data":[{"available_balance":"88.50","voucher_balance":"0.00","currency":"CNY",...}]}`。
/// 解析 `data[0].available_balance`（上游为字符串），容错回退顶层 `available_balance`；
/// 两者均缺时返回 error 快照（「有则展示无则隐藏」，不抛错）。
/// `base` 尊重 `KIMI_BASE_URL` / `MOONSHOT_BASE_URL` 环境变量（与 `KimiProvider.Endpoint.base`
/// 一致），便于本地 mock 测试。
public struct KimiUsageFetcher: ProviderUsageFetcher {
    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["KIMI_BASE_URL", "MOONSHOT_BASE_URL"]) ?? "https://api.moonshot.ai/v1"
        }
        static var balance: URL { URL(string: "\(base)/users/me/balance")! }
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        // 1. 解析 api key：credential 优先，回退环境变量
        let key: String
        if let apiKey = credential.apiKey, !apiKey.isEmpty {
            key = apiKey
        } else if let env = RouteConfig.envValue(["KIMI_API_KEY", "MOONSHOT_API_KEY"]), !env.isEmpty {
            key = env
        } else {
            throw ProviderError.missingCredentials(
                "KIMI_API_KEY or config providers.kimi.credential.apiKey"
            )
        }

        // 2. 打上游
        var request = URLRequest(url: Endpoint.balance)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await ProviderHTTPClient.shared.data(for: request)
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ProviderError.upstreamError(
                statusCode: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("users/me/balance 响应非 JSON")
        }

        // 3. 解析可用余额：优先 data[0].available_balance，回退顶层 available_balance
        var balance: Decimal?
        var currency: String?
        if let dataArray = json["data"] as? [[String: Any]], let first = dataArray.first {
            balance = Self.parseDecimal(first["available_balance"]) ?? Self.parseDecimal(first["balance"])
            currency = first["currency"] as? String
        }
        if balance == nil {
            balance = Self.parseDecimal(json["available_balance"])
        }
        if currency == nil {
            currency = json["currency"] as? String
        }

        return ProviderUsageSnapshot(
            providerID: "kimi",
            balance: balance,
            currency: currency,
            rawJSON: raw,
            fetchedAt: .now,
            error: balance == nil ? "可用余额字段缺失" : nil
        )
    }

    /// 容错解析 Decimal：上游可能是 JSON number（NSNumber）或 string（如 "88.50"）。
    private static func parseDecimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber {
            return number.decimalValue
        }
        if let string = value as? String, let decimal = Decimal(string: string) {
            return decimal
        }
        return nil
    }
}
