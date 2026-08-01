import Foundation

/// 动态模型缓存（actor，线程安全）。避免每次 `/v1/models` 请求都打上游。
/// 由 Provider 的 `listModels` 调用：命中且未过期则直接返回静态/缓存结果。
public actor ModelCache {
    public static let shared = ModelCache()

    private var cached: [String: [Model]] = [:]
    private var timestamps: [String: Date] = [:]

    public init() {}

    /// 读取缓存。`key` 通常为 provider id；过期返回 nil。
    public func get(_ key: String, ttl: TimeInterval = 300) -> [Model]? {
        guard let models = cached[key], let time = timestamps[key] else { return nil }
        guard Date().timeIntervalSince(time) < ttl else {
            cached.removeValue(forKey: key)
            timestamps.removeValue(forKey: key)
            return nil
        }
        return models
    }

    public func set(_ key: String, models: [Model]) {
        cached[key] = models
        timestamps[key] = Date()
    }

    public func invalidate(_ key: String) {
        cached.removeValue(forKey: key)
        timestamps.removeValue(forKey: key)
    }
}
