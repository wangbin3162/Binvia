import Foundation

/// 非流式 OpenAI Chat Completion 响应归一化器。
///
/// 部分 OpenAI 兼容上游会返回 completion 结构但遗漏协议字段，严格客户端
/// 会在解码阶段失败。本归一化器只修复确认是 completion 的 JSON，不处理错误体。
public enum ChatCompletionResponseNormalizer {
    /// 补齐基础字段并清洗空的 `finish_reason`；非 completion 响应保持原样（除空串清洗）。
    public static func normalize(_ body: Data, model fallbackModel: String?) -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              root["error"] == nil,
              root["choices"] is [[String: Any]] else {
            return ChatFinishReasonSanitizer.sanitize(body)
        }

        var didModify = false
        if !(root["id"] is String) || (root["id"] as? String)?.isEmpty == true {
            root["id"] = "chatcmpl-binvia-\(UUID().uuidString.lowercased())"
            didModify = true
        }
        if root["object"] == nil {
            root["object"] = "chat.completion"
            didModify = true
        }
        if root["created"] == nil {
            root["created"] = Int(Date().timeIntervalSince1970)
            didModify = true
        }
        if root["model"] == nil, let fallbackModel, !fallbackModel.isEmpty {
            root["model"] = fallbackModel
            didModify = true
        }
        // 字段齐全时不做整体重序列化，原字节返回（仅走 finish_reason 空串清洗），
        // 避免解析→改字段→重新序列化带来的键序/数字精度/空白格式副作用。
        guard didModify else {
            return ChatFinishReasonSanitizer.sanitize(body)
        }

        guard let normalized = try? JSONSerialization.data(withJSONObject: root, options: []) else {
            return ChatFinishReasonSanitizer.sanitize(body)
        }
        return ChatFinishReasonSanitizer.sanitize(normalized)
    }
}
