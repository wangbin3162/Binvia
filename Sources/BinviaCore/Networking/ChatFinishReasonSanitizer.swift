import Foundation

/// 非流式 Chat 响应 body 的 `finish_reason` 清洗器。
///
/// 背景：部分上游（如 opencode.ai 的 grok 模型）偶发在非流式 JSON body 中返回
/// `finish_reason: ""`（空串）。OpenAI 协议里该字段应为 `null` 或具体原因值，
/// 空串无合法语义。下游严格枚举客户端（Rust serde）会报
/// `unknown variant ``, expected one of stop/length/...` 并拒绝整个响应。
///
/// 本清洗器走**定点字节重写**而非"解析→改字段→重新序列化"：
/// - 不改动字段顺序、数字精度、空白格式等其余内容（除被替换的子串本身）；
/// - 仅把值为空串的 `finish_reason` 改写为 `null`；
/// - 非空值原样保留（含将来可能出现的未知值——交给 FinishReasonNormalizer 兜底）。
///
/// 仅用于 `/v1/chat/completions` 非流式透传分支（`handleChat` 中 `isStreaming == false`）。
/// 流式路径由 `SSEStreamNormalizer` + `StreamFormat.finishReason`（`!reason.isEmpty`）处理；
/// 聚合路径（CodeBuddy/Kimi）由 `SSEJSONAggregator` 处理；二者均已对空串免疫。
public enum ChatFinishReasonSanitizer {

    /// 把 body 中所有 `"finish_reason": ""`（空串）改写为 `"finish_reason": null`。
    /// 若无空串命中则原样返回入参。非 UTF-8 body 不改写。
    @discardableResult
    public static func sanitize(_ body: Data) -> Data {
        guard !body.isEmpty,
              let text = String(data: body, encoding: .utf8) else {
            return body
        }
        // 扫描所有 `"finish_reason"` 出现位置，定位其后紧跟的空串值并替换为 null。
        // 仅替换值子串（`""` → `null`），其余字节保持不变，避免全量重序列化带来的
        // 字段顺序/数字精度/空白格式副作用。
        var result = ""
        var cursor = text.startIndex
        var didReplace = false
        let key = #""finish_reason""#

        while let range = text.range(of: key, range: cursor..<text.endIndex) {
            // 拷贝键之前的未处理段
            result.append(contentsOf: text[cursor..<range.lowerBound])
            result.append(key)

            var i = range.upperBound
            // 跳过键名后到冒号前的空白
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            if i < text.endIndex, text[i] == ":" {
                result.append(contentsOf: text[range.upperBound...i])
                i = text.index(after: i)
                // 跳过冒号后到值前的空白
                let valueStart = i
                while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
                result.append(contentsOf: text[valueStart..<i])
                // 命中空串 `""`：替换为 `null`，跳过这两个引号
                if i < text.endIndex, text[i] == "\"",
                   let next = text.index(i, offsetBy: 1, limitedBy: text.endIndex),
                   next < text.endIndex, text[next] == "\"" {
                    result.append("null")
                    cursor = text.index(after: next)
                    didReplace = true
                } else {
                    cursor = i
                }
            } else {
                cursor = range.upperBound
            }
        }
        guard didReplace else { return body }
        result.append(contentsOf: text[cursor..<text.endIndex])
        return Data(result.utf8)
    }
}
