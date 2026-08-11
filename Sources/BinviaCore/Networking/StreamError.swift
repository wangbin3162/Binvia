import Foundation

/// 流式服务错误码（对齐 OmniRoute 的错误分类，供 `/v1/usage` 与客户端错误体使用）。
public enum StreamErrorCode: String, Sendable, Codable {
    case streamReadinessTimeout = "stream_readiness_timeout"
    case streamIdleTimeout = "stream_idle_timeout"
    case streamEarlyEOF = "stream_early_eof"
    case upstreamError = "upstream_error"
    case clientDisconnected = "client_disconnected"
}

/// 流式服务错误：错误码 + 客户端可读消息 + 建议 HTTP 状态码。
public struct StreamError: Error, Sendable {
    public let code: StreamErrorCode
    public let message: String
    public let statusCode: Int

    public init(code: StreamErrorCode, message: String, statusCode: Int) {
        self.code = code
        self.message = message
        self.statusCode = statusCode
    }
}

extension StreamError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 流式服务超时/重试配置。环境变量在读取时解析，支持运行时覆盖，不缓存。
public enum StreamConfig {
    /// 首个事件（首包）超时，默认 60s。
    public static var readinessTimeout: TimeInterval {
        env("BINVIA_STREAM_READINESS_TIMEOUT", default: 60)
    }

    /// 两次事件之间的空闲超时，默认 120s。
    public static var idleTimeout: TimeInterval {
        env("BINVIA_STREAM_IDLE_TIMEOUT", default: 120)
    }

    /// 首包前早断（空流）的最大重试次数，默认 1，设为 0 关闭。
    public static var earlyEOFRetryLimit: Int {
        guard let raw = ProcessInfo.processInfo.environment["BINVIA_STREAM_EARLY_EOF_RETRY"],
              let value = Int(raw), value >= 0 else { return 1 }
        return value
    }

    /// 空闲看门狗检查周期（秒）。
    public static let watchdogInterval: TimeInterval = 10

    private static func env(_ name: String, default defaultValue: TimeInterval) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[name],
              let value = TimeInterval(raw), value > 0 else { return defaultValue }
        return value
    }
}
