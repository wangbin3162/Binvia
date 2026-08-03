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
        // 1. 解析全部 api key（多 Key 余额查询）：config apiKeys 数组（带标签） + 环境变量，去重。
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
                    if let balance = try? await Self.fetchBalance(forKey: key.value) {
                        return (key.value, balance)
                    }
                    return (key.value, nil)
                }
            }
            var collected: [(String, DeepSeekBalanceResult?)] = []
            for await item in group {
                collected.append(item)
            }
            // 保持 keys 原始顺序
            return keys.compactMap { k in collected.first { $0.0 == k.value } }
        }

        var balances: [KeyedBalance] = []
        var firstBalance: Decimal?
        var firstCurrency: String?
        var lastError: String?
        var rawFirst: String?
        for (keyValue, result) in results {
            // 展示标签：优先用户配置的标签；环境变量/未配置标签回退掩码。
            let label = keys.first { $0.value == keyValue }?.label
                ?? Self.maskedKey(keyValue)
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

    /// 解析全部可用 api key：config apiKeys 数组（带标签）优先 + credential.apiKey + 环境变量。
    /// 去重、过滤空值；返回带展示标签的令牌（无标签回退掩码）。
    /// 注意：AppState 会用 config 首个 apiKey 填充 `credential.apiKey`，因此 config 必须
    /// 先于 credential 处理，保证同 value 时展示用户配置的标签而非掩码。
    private func resolveAllKeys(credential: ProviderCredential) -> [KeyedToken] {
        var tokens: [KeyedToken] = []
        var seen = Set<String>()
        // 1. config 优先：带用户标签的令牌（含 env 兜底掩码）
        if let config = try? ConfigStore.load() {
            for token in config.keyedTokens(for: "deepseek") {
                let value = token.value.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = token.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, seen.insert(value).inserted else { continue }
                tokens.append(KeyedToken(label: label, value: value))
            }
        }
        // 2. credential.apiKey 兜底（掩码标签）：已出现在 config 中的 value 不再重复添加
        if let apiKey = credential.apiKey, !apiKey.isEmpty {
            let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, seen.insert(value).inserted {
                tokens.append(KeyedToken(value: value))
            }
        }
        return tokens
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
