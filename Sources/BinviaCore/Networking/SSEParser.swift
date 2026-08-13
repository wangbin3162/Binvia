import Foundation

/// SSE（Server-Sent Events）流解析器。
/// 上游数据块可能把事件切分到多个 chunk，这里用内部 buffer 跨 chunk 累积，
/// 仅在遇到空行（`\n\n`）时输出一个完整事件。
public struct SSEParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// 追加一段上游数据，返回新解析出的完整事件文本（包含 `data:` 行）。
    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        return drain()
    }

    /// 流结束时调用，冲刷剩余 buffer。
    public mutating func finish() -> [String] {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return [] }
        return [String(decoding: buffer, as: UTF8.self)]
    }

    private mutating func drain() -> [String] {
        var events: [String] = []
        let separator = Data("\n\n".utf8)
        while let range = buffer.range(of: separator) {
            let eventData = buffer.subdata(in: 0 ..< range.lowerBound)
            buffer.removeSubrange(0 ..< range.upperBound)
            // 只处理含非空白内容的块（跳过心跳 `: keep-alive`）
            if !eventData.isEmpty {
                events.append(String(decoding: eventData, as: UTF8.self))
            }
        }
        return events
    }
}

/// SSE 事件文本工具。
public enum SSEEvent {
    /// 从事件文本中提取 `data:` 字段值（多行时取最后一行，剥离尾部 `\r`）。
    public static func dataValue(from event: String) -> String? {
        var value: String?
        for line in event.components(separatedBy: "\n") {
            let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if cleaned.hasPrefix("data:") {
                value = String(cleaned.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    /// 是否结束标记 `[DONE]`。
    public static func isDone(_ value: String) -> Bool {
        value == "[DONE]"
    }

    /// 把事件里所有 `data:` 行的值替换为 `newValue`，其余行（event:/注释等）原样保留。
    /// 保留原行 `data:` 后的空白风格（`data: ` / `data:`）。无 data 行时返回 nil。
    public static func replacingDataValue(in event: String, with newValue: String) -> String? {
        var hasData = false
        var rebuilt = ""
        for line in event.components(separatedBy: "\n") {
            let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if cleaned.hasPrefix("data:") {
                hasData = true
                // 保留冒号后到原值之间的空白（常见为单个空格，也可能无空格）。
                let afterColon = cleaned.dropFirst(5)
                let whitespace = afterColon.prefix(while: { $0 == " " || $0 == "\t" })
                rebuilt += "data:" + whitespace + newValue
            } else {
                rebuilt += line
            }
            rebuilt += "\n"
        }
        return hasData ? String(rebuilt.dropLast()) : nil
    }
}
