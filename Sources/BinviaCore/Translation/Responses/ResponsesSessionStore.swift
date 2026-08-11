import Foundation

/// Responses `previous_response_id` 内存会话表。
///
/// 第一版实现（计划 §5.1 / §8）：保存每个 Response 的 Chat 消息历史，上限 200 条；
/// 重启即失效。线程安全，供并发请求读取。
public final class ResponsesSessionStore: @unchecked Sendable {
    public static let shared = ResponsesSessionStore()

    private let lock = NSLock()
    private var history: [String: [ChatMessage]] = [:]

    public init() {}

    /// 保存一个已完成的 Response 及其 Chat 历史（含当轮 assistant 消息）。
    public func store(responseID: String, messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        history[responseID] = messages
        if history.count > 200 {
            let oldest = history.keys.sorted().first
            if let oldest {
                history.removeValue(forKey: oldest)
            }
        }
    }

    /// 取出历史消息；未知 id 返回 nil。
    public func history(for responseID: String) -> [ChatMessage]? {
        lock.lock()
        defer { lock.unlock() }
        return history[responseID]
    }

    /// 测试辅助：清空会话表。
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
    }
}
