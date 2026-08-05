import Foundation

/// 可变的配置运行状态盒，支持热更新回调。
/// 线程安全（NSLock），`@unchecked Sendable` 与 AppState 的 `applyConfigHotReload` 同机制。
public final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var config: RouteConfig
    private var _onConfigChanged: (@Sendable (RouteConfig) -> Void)?
    private var adminToken: String?

    public init(config: RouteConfig) {
        self.config = config
    }

    /// 当前配置（线程安全快照）。
    public func get() -> RouteConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    /// 原子更新配置：传入闭包修改，变更后自动触发 `onConfigChanged`。
    public func update(_ mutate: (inout RouteConfig) -> Void) {
        lock.lock()
        mutate(&config)
        let snapshot = config
        let callback = _onConfigChanged
        lock.unlock()
        callback?(snapshot)
    }

    /// 保存配置到磁盘并触发热更新。
    public func saveAndReload() throws {
        let snapshot: RouteConfig
        lock.lock()
        snapshot = config
        lock.unlock()
        try ConfigStore.save(snapshot)
        // 保存成功后触发热更新（回调中 re-read 已持久化的配置）
        lock.lock()
        let callback = _onConfigChanged
        lock.unlock()
        callback?(snapshot)
    }

    /// 配置变更回调（由 `BinviaServer/main.swift` 设置，替换 `RouteHandler`）。
    public var onConfigChanged: (@Sendable (RouteConfig) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onConfigChanged
        }
        set {
            lock.lock()
            _onConfigChanged = newValue
            lock.unlock()
        }
    }

    // MARK: - 面板认证

    /// 验证面板密码：成功时轮换 admin token 并返回 token 字符串；失败返回 nil。
    public func verifyPassword(_ password: String) -> String? {
        lock.lock()
        let stored = config.adminPassword
        lock.unlock()
        guard let stored, !stored.isEmpty else {
            return nil
        }
        guard password == stored else { return nil }
        let newToken = UUID().uuidString
        lock.lock()
        adminToken = newToken
        lock.unlock()
        return newToken
    }

    /// 检查请求是否已授权：未设密码时全部放行。
    public func isAuthorized(_ token: String?) -> Bool {
        lock.lock()
        let password = config.adminPassword
        let currentToken = adminToken
        lock.unlock()
        guard let password, !password.isEmpty else {
            return true // 未设密码，全部放行
        }
        guard let token, let currentToken else {
            return false
        }
        return token == currentToken
    }

    /// 面板是否启用。
    public func isWebPanelEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return config.webPanelEnabled
    }
}