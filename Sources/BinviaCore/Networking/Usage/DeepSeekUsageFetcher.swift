import Foundation

/// DeepSeek 余额查询器。
///
/// 打 `GET {base}/user/balance`（Bearer apiKey），解析 `balance_infos[]` 返回
/// 账户余额。`base` 尊重环境变量 `DEEPSEEK_BASE_URL`（与 `DeepSeekProvider.Endpoint.base`
/// 一致），便于本地 mock 测试。
///
/// 响应字段 `total_balance` / `granted_balance` / `topped_up_balance` 上游可能是
/// 字符串或数字，统一用 `Decimal` 容错解析。
public struct DeepSeekUsageFetcher: ProviderUsageFetcher {
    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["DEEPSEEK_BASE_URL"]) ?? "https://api.deepseek.com/v1"
        }
        static var balance: URL { URL(string: "\(base)/user/balance")! }
    }

    /// 解析 `balance_infos[]` 单条。全部余额字段容错为 Decimal。
    private struct BalanceInfo {
        let currency: String?
        let totalBalance: Decimal?
        let grantedBalance: Decimal?
        let toppedUpBalance: Decimal?
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        // 1. 解析 api key：credential 优先，回退环境变量
        let key: String
        if let apiKey = credential.apiKey, !apiKey.isEmpty {
            key = apiKey
        } else if let env = RouteConfig.envValue(["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]), !env.isEmpty {
            key = env
        } else {
            throw ProviderError.missingCredentials(
                "DEEPSEEK_API_KEY or config providers.deepseek.credential.apiKey"
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

        // 3. 解析 balance_infos[]（JSONSerialization + 容错 Decimal）
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse("user/balance 响应非 JSON")
        }
        let infos = (json["balance_infos"] as? [[String: Any]] ?? []).map { info in
            BalanceInfo(
                currency: info["currency"] as? String,
                totalBalance: Self.parseDecimal(info["total_balance"]),
                grantedBalance: Self.parseDecimal(info["granted_balance"]),
                toppedUpBalance: Self.parseDecimal(info["topped_up_balance"])
            )
        }
        guard let first = infos.first else {
            throw ProviderError.invalidResponse("user/balance 响应缺少 balance_infos")
        }

        return ProviderUsageSnapshot(
            providerID: "deepseek",
            balance: first.totalBalance,
            currency: first.currency,
            rawJSON: raw,
            fetchedAt: .now
        )
    }

    /// 容错解析 Decimal：上游可能是 JSON number（NSNumber）或 string（如 "120.50"）。
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
