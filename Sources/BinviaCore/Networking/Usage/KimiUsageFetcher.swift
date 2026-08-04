import Foundation

/// Kimi（Moonshot）余额查询器。与 DeepSeek 对齐：多 Key 并发查询，逐 Key 展示令牌标签 + 余额。
///
/// 默认国内站点 `api.moonshot.cn`（可用 `KIMI_BASE_URL` / `MOONSHOT_BASE_URL` 覆盖）。
/// 打 `GET {base}/users/me/balance`（Bearer apiKey）。Moonshot 余额接口现行响应：
/// `{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"status":true}`
/// （`data` 为字典；旧格式为数组 `data[0].available_balance`，兼容两者）。
/// 币种：响应未带 currency 时默认 `CNY`（国内站点按人民币展示）。
/// 多 Key 来源：config `apiKeys`（带用户标签）→ `credential.apiKey` → 环境变量，按值去重；
/// 每个 Key 并发查询余额，失败不影响其他 Key（全部失败才抛错）。
public struct KimiUsageFetcher: ProviderUsageFetcher {
    public init() {}

    private enum Endpoint {
        static var base: String {
            RouteConfig.envValue(["KIMI_BASE_URL", "MOONSHOT_BASE_URL"]) ?? "https://api.moonshot.cn/v1"
        }
        static var balance: URL { URL(string: "\(base)/users/me/balance")! }
    }

    public func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot {
        // 1. 解析全部 api key（多 Key 余额查询）：config apiKeys 数组（带标签）+ credential + 环境变量，去重
        let keys = resolveAllKeys(credential: credential)
        guard !keys.isEmpty else {
            throw ProviderError.missingCredentials(
                "KIMI_API_KEY or config providers.kimi.credential.apiKey"
            )
        }

        // 2. 并发查询每个 Key 的余额（参考 DeepSeekUsageFetcher 的 task group 模式）
        let results = await withTaskGroup(of: (String, KimiBalanceResult?).self) { group in
            for key in keys {
                group.addTask {
                    if let balance = try? await Self.fetchBalance(forKey: key.value) {
                        return (key.value, balance)
                    }
                    return (key.value, nil)
                }
            }
            var collected: [(String, KimiBalanceResult?)] = []
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
                balances.append(KeyedBalance(label: label, balance: result.balance, currency: result.currency))
                if firstBalance == nil {
                    firstBalance = result.balance
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
                message: lastError ?? "Kimi 余额查询失败"
            )
        }

        return ProviderUsageSnapshot(
            providerID: "kimi",
            balance: firstBalance,
            currency: firstCurrency,
            balances: balances,
            rawJSON: rawFirst,
            fetchedAt: .now
        )
    }

    // MARK: - 内部

    /// 解析全部可用 api key：config apiKeys 数组（带标签）优先 + credential.apiKey + 环境变量。
    /// 去重、过滤空值；返回带展示标签的令牌（无标签回退掩码）。
    /// 注意：AppState 会用 config 首个 apiKey 填充 `credential.apiKey`，因此 config 必须
    /// 先于 credential 处理，保证同 value 时展示用户配置的标签而非掩码。
    private func resolveAllKeys(credential: ProviderCredential) -> [KeyedToken] {
        var tokens: [KeyedToken] = []
        var seen = Set<String>()
        // 1. config 优先：带用户标签的令牌（含 env 兜底掩码）
        if let config = try? ConfigStore.load() {
            for token in config.keyedTokens(for: "kimi") {
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

    /// 单 Key 余额查询：`GET {base}/users/me/balance`（Bearer apiKey）。
    /// 非 2xx / 非 JSON / `code != 0` / 缺余额字段 → 抛错（由调用方按 Key 失败处理）。
    private static func fetchBalance(forKey key: String) async throws -> KimiBalanceResult {
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

        // 业务状态码：`code != 0` 视为接口错误（现行响应带 `code` / `status` 字段）
        if let codeValue = json["code"], let code = Self.parseDecimal(codeValue), code != 0 {
            throw ProviderError.invalidResponse(
                "users/me/balance 业务错误: \((json["msg"] as? String) ?? "code \(code)")"
            )
        }

        // 解析可用余额：`data` 可能是数组（旧格式 data[0].available_balance）或
        // 字典（现行格式 {"available_balance":49.58,...}），最后回退顶层 available_balance
        var balance: Decimal?
        var currency: String?
        if let dataArray = json["data"] as? [[String: Any]], let first = dataArray.first {
            balance = Self.parseDecimal(first["available_balance"]) ?? Self.parseDecimal(first["balance"])
            currency = first["currency"] as? String
        } else if let dataDict = json["data"] as? [String: Any] {
            balance = Self.parseDecimal(dataDict["available_balance"]) ?? Self.parseDecimal(dataDict["balance"])
            currency = dataDict["currency"] as? String
        }
        if balance == nil {
            balance = Self.parseDecimal(json["available_balance"])
        }
        if currency == nil {
            currency = json["currency"] as? String
        }
        guard let balance else {
            throw ProviderError.invalidResponse("users/me/balance 缺少可用余额字段")
        }

        // 国内站点按人民币展示：响应未带币种时默认 CNY
        let effectiveCurrency: String
        if let c = currency, !c.isEmpty {
            effectiveCurrency = c
        } else {
            effectiveCurrency = "CNY"
        }
        return KimiBalanceResult(
            balance: balance,
            currency: effectiveCurrency,
            raw: raw
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

/// 单个 Key 的余额查询结果（内部承载）。
private struct KimiBalanceResult: Sendable {
    let balance: Decimal
    let currency: String
    let raw: String
}
