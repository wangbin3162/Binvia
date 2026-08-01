import Foundation

/// 供应商用量快照缓存（actor，线程安全）。
///
/// 按 provider 缓存 `ProviderUsageSnapshot`，默认 5 分钟 TTL，避免 GUI 用量轮询
/// 与手动刷新高频重复打上游。成功快照与带 `error` 的失败快照均可缓存，
/// 由调用方（`AppState.startUsageRefresh`）决定何时失效重取。
public actor UsageCache {
    public static let shared = UsageCache()

    private struct Entry {
        let snapshot: ProviderUsageSnapshot
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// 读取指定 provider 的缓存快照；未命中或已过期返回 nil。
    public func get(_ providerID: String) -> ProviderUsageSnapshot? {
        guard let entry = entries[providerID] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < Self.ttl else {
            entries[providerID] = nil
            return nil
        }
        return entry.snapshot
    }

    /// 写入缓存快照（以 `snapshot.providerID` 为 key）。
    public func set(_ snapshot: ProviderUsageSnapshot) {
        entries[snapshot.providerID] = Entry(snapshot: snapshot, storedAt: Date())
    }

    /// 清除指定 provider 的缓存。
    public func invalidate(_ providerID: String) {
        entries[providerID] = nil
    }

    /// TTL（秒）：5 分钟。
    public static let ttl: TimeInterval = 300
}
