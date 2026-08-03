import Foundation

/// Token 用量（上游 OpenAI 兼容 `usage` 字段的标准化结构，缺失字段默认为 0）。
public struct TokenUsage: Sendable, Codable, Equatable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
}

public struct RequestLogEntry: Sendable, Codable, Equatable {
    /// 条目唯一标识：流式请求在流结束回填 token 时用于定位（默认自动生成，不破坏现有调用点）。
    public let id: UUID
    public let timestamp: Date
    public let method: String
    public let path: String
    public let providerID: String?
    public let model: String?
    public let statusCode: Int
    public let durationMS: Double
    public let error: String?
    /// 上游返回的 token 用量。流式请求在流结束后才回填，回填前为 nil。
    public var tokens: TokenUsage?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        method: String,
        path: String,
        providerID: String?,
        model: String?,
        statusCode: Int,
        durationMS: Double,
        error: String? = nil,
        tokens: TokenUsage? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.providerID = providerID
        self.model = model
        self.statusCode = statusCode
        self.durationMS = durationMS
        self.error = error
        self.tokens = tokens
    }
}

public struct ProviderUsage: Sendable, Codable, Equatable {
    public var requestCount: Int
    public var errorCount: Int
    public var totalDurationMS: Double
    public var models: [String: Int]
    /// Token 用量聚合（Phase 22：summary() 累加 entry.tokens）。
    public var totalPromptTokens: Int
    public var totalCompletionTokens: Int
    public var totalTokens: Int

    public init() {
        self.requestCount = 0
        self.errorCount = 0
        self.totalDurationMS = 0
        self.models = [:]
        self.totalPromptTokens = 0
        self.totalCompletionTokens = 0
        self.totalTokens = 0
    }
}

public struct UsageSummary: Sendable, Codable, Equatable {
    public var byProvider: [String: ProviderUsage]

    public init(byProvider: [String: ProviderUsage] = [:]) {
        self.byProvider = byProvider
    }
}

/// 请求日志与用量统计（内存实现，线程安全）。
public final class RequestLogger: @unchecked Sendable {
    public static let shared = RequestLogger()

    private let lock = NSLock()
    private var entries: [RequestLogEntry] = []

    public init() {}

    public func log(_ entry: RequestLogEntry) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        // 简单上限，防止无界增长
        if entries.count > 10_000 {
            entries.removeFirst(entries.count - 10_000)
        }
    }

    public func allEntries() -> [RequestLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// 流式请求结束时回填 token 用量（按条目 id 定位，找不到时静默忽略）。
    public func updateTokens(id: UUID, tokens: TokenUsage) {
        lock.lock()
        defer { lock.unlock() }
        if let index = entries.lastIndex(where: { $0.id == id }) {
            entries[index].tokens = tokens
        }
    }

    public func summary() -> UsageSummary {
        lock.lock()
        defer { lock.unlock() }
        var summary = UsageSummary()
        for entry in entries {
            let pid = entry.providerID ?? "unknown"
            var usage = summary.byProvider[pid] ?? ProviderUsage()
            usage.requestCount += 1
            if entry.statusCode >= 400 || entry.error != nil {
                usage.errorCount += 1
            }
            usage.totalDurationMS += entry.durationMS
            if let model = entry.model {
                usage.models[model, default: 0] += 1
            }
            if let tokens = entry.tokens {
                usage.totalPromptTokens += tokens.promptTokens
                usage.totalCompletionTokens += tokens.completionTokens
                usage.totalTokens += tokens.totalTokens
            }
            summary.byProvider[pid] = usage
        }
        return summary
    }
}
