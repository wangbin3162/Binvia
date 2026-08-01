import Foundation

public struct RequestLogEntry: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let method: String
    public let path: String
    public let providerID: String?
    public let model: String?
    public let statusCode: Int
    public let durationMS: Double
    public let error: String?

    public init(
        timestamp: Date,
        method: String,
        path: String,
        providerID: String?,
        model: String?,
        statusCode: Int,
        durationMS: Double,
        error: String? = nil
    ) {
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.providerID = providerID
        self.model = model
        self.statusCode = statusCode
        self.durationMS = durationMS
        self.error = error
    }
}

public struct ProviderUsage: Sendable, Codable, Equatable {
    public var requestCount: Int
    public var errorCount: Int
    public var totalDurationMS: Double
    public var models: [String: Int]

    public init() {
        self.requestCount = 0
        self.errorCount = 0
        self.totalDurationMS = 0
        self.models = [:]
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
            summary.byProvider[pid] = usage
        }
        return summary
    }
}
