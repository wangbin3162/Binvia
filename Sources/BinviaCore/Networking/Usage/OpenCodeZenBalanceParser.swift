import Foundation

/// OpenCode Go Zen 余额解析器（参考 CodexBar `OpenCodeGoZenBalanceParser`）。
///
/// 上游无公开余额端点，余额从三个来源提取：
/// 1. dashboard 页面 JSON：显式余额键（`zenBalance` / `currentBalanceUSD` 等）；
/// 2. 页面文本中的 `$` 金额（如 "Current balance $12.34"）；
/// 3. `_server` billing RPC 响应：原始整数余额 / `100_000_000` = USD。
///
/// 解析失败返回 nil（余额是可选信息，失败不阻断配额窗口展示）。
public enum OpenCodeZenBalanceParser {
    private static let billingScale = 100_000_000.0

    /// 从 dashboard 页面文本提取余额（JSON → $ 金额 → balance 附近 $ 金额）。
    public static func parse(text: String) -> Double? {
        if let value = parseJSON(text: text) {
            return value
        }
        let localizedPattern = [
            #"(?i)(?:current\s+balance|zen\s+balance|現在の残高)"#,
            #"[^$]{0,80}\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#,
        ].joined()
        if let value = extractNumber(pattern: localizedPattern, text: text) {
            return value
        }
        let nearbyPattern = #"(?i)(?:balance|残高)[\s\S]{0,120}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#
        return extractNumber(pattern: nearbyPattern, text: text)
    }

    /// 从 `_server` billing RPC 响应提取余额（原始整数 / 1e8）。
    public static func parseBillingServerResponse(text: String) -> Double? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let rawBalance = findRawBillingBalance(in: object)
        {
            return rawBalance / billingScale
        }

        // 非 JSON（text/javascript 序列化对象）：先确认存在 customerID，再取 balance
        let customerPattern =
            #"(?:\"customerID\"|customerID)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?\"[^\"]+\""#
        guard containsMatch(pattern: customerPattern, text: text) else {
            return nil
        }
        let pattern = #"(?:\"balance\"|balance)\s*:\s*(?:\$R\[\d+\]\s*=\s*)?(-?[0-9]+(?:\.[0-9]+)?)"#
        guard let rawBalance = extractNumber(pattern: pattern, text: text) else {
            return nil
        }
        return rawBalance / billingScale
    }

    // MARK: - JSON 路径

    private static func parseJSON(text: String) -> Double? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return nil
        }
        return findBalanceValue(in: object)
    }

    /// 递归找显式余额键（当前值即 USD，无需缩放）。
    private static func findBalanceValue(in object: Any) -> Double? {
        if let dict = object as? [String: Any] {
            for (key, value) in dict {
                if isExplicitBalanceAmountKey(key),
                   let number = doubleValue(from: value)
                {
                    return number
                }
                if let found = findBalanceValue(in: value) {
                    return found
                }
            }
            return nil
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findBalanceValue(in: value) {
                    return found
                }
            }
        }
        return nil
    }

    /// 找 billing RPC 响应里的原始余额：要求同层存在非空 `customerID`，`balance` 才是账户余额。
    private static func findRawBillingBalance(in object: Any) -> Double? {
        if let dict = object as? [String: Any] {
            if dict["balance"] != nil {
                guard let customerID = dict["customerID"] as? String, !customerID.isEmpty else {
                    return nil
                }
                guard let rawBalance = doubleValue(from: dict["balance"]) else {
                    return nil
                }
                return rawBalance
            }
            for value in dict.values {
                if let found = findRawBillingBalance(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = findRawBillingBalance(in: value) {
                    return found
                }
            }
        }
        return nil
    }

    private static func containsMatch(pattern: String, text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: nsrange) != nil
    }

    private static func isExplicitBalanceAmountKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        return [
            "zenbalance",
            "zencurrentbalance",
            "currentbalance",
            "currentbalanceusd",
            "balanceusd",
            "usdbalance",
        ].contains(normalized)
    }

    private static func extractNumber(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsrange),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[range].replacingOccurrences(of: ",", with: ""))
    }

    private static func doubleValue(from value: Any?) -> Double? {
        switch value {
        case is Bool:
            nil
        case let number as Double:
            number
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(
                string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: ",", with: ""))
        default:
            nil
        }
    }
}
