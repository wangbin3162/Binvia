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
        // 1. 解析全部 api key（多 Key 余额查询）：config apiKeys 数组 + 环境变量，去重。
        let keys = resolveAllKeys(credential: credential)
        guard !keys.isEmpty else {
            throw ProviderError.missingCredentials(
                "DEEPSEEK_API_KEY or config providers.deepseek.credential.apiKey"
            )
        }

        // 2. 并发查询每个 Key 的余额（参考 CodexBar DeepSeekUsageFetcher 的 balance 接口）。
        let results = await withTaskGroup(of: (String, DeepSeekBalanceResult?).self) { group in
            for key in keys {
                group.addTask {
                    if let balance = try? await Self.fetchBalance(forKey: key) {
                        return (key, balance)
                    }
                    return (key, nil)
                }
            }
            var collected: [(String, DeepSeekBalanceResult?)] = []
            for await item in group {
                collected.append(item)
            }
            // 保持 keys 原始顺序
            return keys.compactMap { k in collected.first { $0.0 == k } }
        }

        var balances: [KeyedBalance] = []
        var firstBalance: Decimal?
        var firstCurrency: String?
        var lastError: String?
        var rawFirst: String?
        for (key, result) in results {
            let label = Self.maskedKey(key)
            if let result {
                balances.append(KeyedBalance(label: label, balance: result.totalBalance, currency: result.currency))
                if firstBalance == nil {
                    firstBalance = result.totalBalance
                    firstCurrency = result.currency
                    rawFirst = result.raw
                }
            } else {
                lastError = "Key \(label) 余额查询失败"
            }
        }

        // 全部失败时抛错，由 AppState 写失败快照
        if balances.isEmpty {
            throw ProviderError.upstreamError(
                statusCode: 0,
                message: lastError ?? "DeepSeek 余额查询失败"
            )
        }

        return ProviderUsageSnapshot(
            providerID: "deepseek",
            balance: firstBalance,
            currency: firstCurrency,
            balances: balances,
            rawJSON: rawFirst,
            fetchedAt: .now
        )
    }

    /// 解析全部可用 api key：credential.apiKey（主）+ config apiKeys 数组 + 环境变量。去重。
    private func resolveAllKeys(credential: ProviderCredential) -> [String] {
        var keys: [String] = []
        if let apiKey = credential.apiKey, !apiKey.isEmpty {
            keys.append(apiKey)
        }
        if let config = try? ConfigStore.load() {
            keys.append(contentsOf: config.apiKeys(for: "deepseek"))
        }
        if let env = RouteConfig.envValue(["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]), !env.isEmpty {
            keys.append(env)
        }
        var seen = Set<String>()
        return keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 掩码 Key：前 6 位 + •••• + 后 4 位。
    private static func maskedKey(_ key: String) -> String {
        guard key.count > 10 else { return String(key.prefix(3)) + "••••" }
        return "\(String(key.prefix(6)))••••\(String(key.suffix(4)))"
    }

    /// 单 Key 余额查询：`GET {base}/user/balance`（Bearer apiKey）。
    private static func fetchBalance(forKey key: String) async throws -> DeepSeekBalanceResult {
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
            throw ProviderError.invalidResponse("user/balance 响应非 JSON")
        }
        let infos = (json["balance_infos"] as? [[String: Any]] ?? []).map { info in
            BalanceInfo(
                currency: info["currency"] as? String,
                totalBalance: parseDecimal(info["total_balance"]),
                grantedBalance: parseDecimal(info["granted_balance"]),
                toppedUpBalance: parseDecimal(info["topped_up_balance"])
            )
        }
        guard let first = infos.first else {
            throw ProviderError.invalidResponse("user/balance 响应缺少 balance_infos")
        }
        return DeepSeekBalanceResult(
            currency: first.currency,
            totalBalance: first.totalBalance ?? 0,
            raw: raw
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

/// 单个 Key 的余额查询结果（内部承载）。
private struct DeepSeekBalanceResult: Sendable {
    let currency: String?
    let totalBalance: Decimal
    let raw: String
}
