import Foundation

/// 流式工具参数增量去重（F3）。
///
/// 上游有两种合法形态：
/// - 增量碎片：每块只带新增片段，必须原样拼接（保留重复字符，如 `ls -ll` 的双 `l`）；
/// - 完整快照：每块重发累计结果，继续拼接会产生重复。
///
/// 只处理无歧义的快照情况（完全相同、或从 existing 开头增长的完整结果），
/// 其余一律视为增量碎片原样追加；禁止模糊前后缀裁剪，避免静默截断。
/// 非字符串（对象/数组）先 JSON 序列化成合法参数片段，不丢弃。
public enum ToolCallArgumentDelta {
    public static func append(existing: String?, incoming: Any?) -> String {
        let current = existing ?? ""
        let next = normalizedFragment(incoming)
        if current.isEmpty { return next }
        if next.isEmpty { return current }
        if next == current { return current }
        if next.hasPrefix(current) { return next }
        return current + next
    }

    private static func normalizedFragment(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let value else { return "" }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return ""
    }
}
