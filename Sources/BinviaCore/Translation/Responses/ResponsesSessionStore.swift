import Foundation

/// Responses `previous_response_id` 会话存储协议（H：RouteHandler 注入，便于测试替换）。
public protocol ResponsesSessionStoring: Sendable {
    func store(responseID: String, messages: [ChatMessage])
    func history(for responseID: String) -> [ChatMessage]?
    func reset()
}

/// Responses `previous_response_id` 会话表。
///
/// 实现（对齐计划 §12 阶段 H）：
/// - 持久化到 JSON 文件（原子写 + 0600 权限）；
/// - 条目 `responseID -> {messages, createdAt}`，TTL 24h，启动与写入时清理；
/// - 上限 200 条，超出按 createdAt 丢弃最旧；
/// - 未知 / 过期 id 返回 nil（调用方转 400）。
public final class ResponsesSessionStore: ResponsesSessionStoring, @unchecked Sendable {
    public static let shared = ResponsesSessionStore()

    /// 条目上限（计划 §8）。
    public static let maxEntries = 200
    /// 会话 TTL（24h）。
    public static let ttl: TimeInterval = 24 * 60 * 60

    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        let _ = self.loadEntries() // 启动即清理过期条目
    }

    public func store(responseID: String, messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadEntries()
        entries[responseID] = SessionEntry(messages: messages, createdAt: Date())
        saveEntries(prune(entries))
    }

    public func history(for responseID: String) -> [ChatMessage]? {
        lock.lock()
        defer { lock.unlock() }
        let entries = loadEntries()
        let pruned = prune(entries)
        if pruned.count != entries.count {
            saveEntries(pruned)
        }
        guard let entry = pruned[responseID] else { return nil }
        return entry.messages
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 文件 I/O

    /// 默认路径：`BINVIA_CONFIG` 已设置时与会话文件同目录（测试隔离），
    /// 否则 `~/.config/binvia/responses-sessions.json`。
    static func defaultFileURL() -> URL {
        if let configPath = ProcessInfo.processInfo.environment["BINVIA_CONFIG"], !configPath.isEmpty {
            return URL(fileURLWithPath: configPath)
                .deletingLastPathComponent()
                .appendingPathComponent("responses-sessions.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/binvia/responses-sessions.json")
    }

    private struct SessionEntry: Codable {
        let messages: [ChatMessage]
        let createdAt: Date
    }

    private func loadEntries() -> [String: SessionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: SessionEntry].self, from: data) else {
            return [:]
        }
        return entries
    }

    private func prune(_ entries: [String: SessionEntry]) -> [String: SessionEntry] {
        let now = Date()
        var alive = entries.filter { now.timeIntervalSince($0.value.createdAt) <= Self.ttl }
        if alive.count > Self.maxEntries {
            let sorted = alive.sorted { $0.value.createdAt < $1.value.createdAt }
            for (id, _) in sorted.prefix(alive.count - Self.maxEntries) {
                alive.removeValue(forKey: id)
            }
        }
        return alive
    }

    private func saveEntries(_ entries: [String: SessionEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = fileURL.appendingPathExtension("tmp")
        guard (try? data.write(to: tempURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}
