import Foundation

/// 余额文本格式化（币种符号 + 金额）。DeepSeek / Kimi 用量卡与概览健康行共用。
///
/// 规则：
/// - CNY / CN / RMB → `¥`；USD / US → `$`；空币种按人民币处理（DeepSeek / Kimi 均为国内站点）；
/// - 金额保留 2 位小数并补齐尾零（`120.5` → `120.50`，`49.58894` → `49.59`）。
enum UsageBalanceText {
    /// "¥120.50" / "$12.34" / "EUR 1.00"
    static func format(_ amount: Decimal, currency: String?) -> String {
        "\(symbol(for: currency))\(amountText(amount))"
    }

    /// 币种符号；未知币种用「代码 + 空格」前缀。
    static func symbol(for currency: String?) -> String {
        switch (currency ?? "").uppercased() {
        case "CNY", "CN", "RMB", "": return "¥"
        case "USD", "US": return "$"
        default: return "\(currency ?? "") "
        }
    }

    /// 金额文本：四舍五入到 2 位小数并补齐尾零。
    private static func amountText(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let text = "\(rounded)"
        guard let dotIndex = text.firstIndex(of: ".") else {
            return "\(text).00"
        }
        var fraction = String(text[text.index(after: dotIndex)...])
        while fraction.count < 2 {
            fraction += "0"
        }
        return "\(text[..<dotIndex]).\(fraction)"
    }
}
