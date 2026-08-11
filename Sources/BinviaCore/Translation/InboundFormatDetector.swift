import Foundation

/// 入站格式识别：路径优先，body 双识别。
public enum InboundFormat: Sendable, Equatable {
    case openaiChat
    case responses
}

public enum InboundFormatDetector {
    public static func detect(path: String, body: Data?) -> InboundFormat {
        let normalized = path.hasPrefix("/v1") ? path : "/v1" + path
        switch normalized {
        case "/v1/responses":
            return .responses
        default:
            break
        }
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .openaiChat
        }
        if json["input"] != nil
            || json["max_output_tokens"] != nil
            || json["previous_response_id"] != nil
            || json["instructions"] != nil {
            return .responses
        }
        return .openaiChat
    }
}
