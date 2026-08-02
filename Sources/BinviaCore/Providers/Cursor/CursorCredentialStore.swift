import Foundation
import SQLite3

/// 从 Cursor IDE 本地数据库发现的凭据。
public struct CursorIDEIdentity: Sendable, Equatable {
    /// WorkOS JWT（`{userId}::{jwt}` 双段格式时已剥离前缀）。
    public let accessToken: String
    /// `storage.serviceMachineId`（生成 `x-cursor-checksum` 用）。
    public let machineId: String?
    /// JWT `exp` 声明解析出的过期时间（无法解析时为 nil）。
    public let expiresAt: Date?

    public init(accessToken: String, machineId: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.machineId = machineId
        self.expiresAt = expiresAt
    }
}

/// Cursor IDE 凭据探测结果（GUI / CLI 展示用）。
public enum CursorDetection: Sendable, Equatable {
    case found(CursorIDEIdentity)
    /// 未找到 Cursor 的 state.vscdb（未安装 / 从未运行过）。
    case noInstallation
    /// 数据库存在但无 accessToken（未登录）。
    case notSignedIn
    /// 数据库存在但打开/读取失败。
    case unreadable(String)
}

/// Cursor 客户端常量。请求头 `x-cursor-client-version` 与 User-Agent 用。
public enum CursorConstants {
    /// Cursor 客户端版本。参考 OmniRoute `oauth/constants/oauth.ts` 的 CURSOR_CONFIG.clientVersion。
    public static let clientVersion = "3.2.14"
}

/// Cursor `x-cursor-checksum`（jyh 密码）：
/// 时间戳字符串逐字符 XOR 滚动 key（初始 165，`key = (key + charCode) & 0xff`），
/// 标准 base64，格式 `{encoded},{machineId}`。参考 OmniRoute `CursorService.generateChecksum`。
public enum CursorChecksum {
    public static func generate(machineId: String, timestamp: Int? = nil) -> String {
        let seconds = timestamp ?? Int(Date().timeIntervalSince1970)
        var key: UInt8 = 165
        var bytes: [UInt8] = []
        for charCode in String(seconds).utf8 {
            bytes.append(charCode ^ key)
            key = key &+ charCode
        }
        let base64 = Data(bytes).base64EncodedString()
        return "\(base64),\(machineId)"
    }
}

/// Cursor IDE 凭据发现。参考 OmniRoute `app/api/oauth/cursor/auto-import` 的 state.vscdb 读取。
///
/// 数据源：`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// （含 `Cursor - Insiders` 变体；`CURSOR_STATE_DB_PATH` 环境变量可覆盖，供测试/自定义路径）。
/// 用 `import SQLite3`（macOS 系统库，零第三方依赖）只读查询 `itemTable` 表：
/// - `cursorAuth/accessToken` → WorkOS JWT（IDE 订阅凭证）
/// - `storage.serviceMachineId` → machineId（checksum 用）
///
/// 令牌约 24h 轮换，缓存 4h 后自动重读（`CURSOR_TOKEN` 环境变量可跳过 DB 读取，测试/自检用）。
public actor CursorCredentialStore {
    public static let shared = CursorCredentialStore()

    /// 缓存有效期（秒）。IDE 令牌 24h 轮换，4h 缓存足够新。
    public var cacheTTL: TimeInterval = 4 * 3600

    private var cached: CursorIDEIdentity?
    private var cachedAt: Date?

    public init() {}

    /// 调整缓存有效期（测试用）。
    public func setCacheTTL(_ ttl: TimeInterval) {
        cacheTTL = ttl
    }

    /// 清空缓存（测试用 / 用户登出后主动清除）。
    public func clearCache() {
        cached = nil
        cachedAt = nil
    }

    /// 带缓存的读取：缓存新鲜直接返回，否则重新探测（供 Provider 请求时调用）。
    public func identity() async -> CursorIDEIdentity? {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        if case .found(let identity) = await refresh() {
            return identity
        }
        return nil
    }

    /// 强制重新探测（更新缓存，忽略已有缓存）。返回详细状态供 GUI/CLI 展示。
    @discardableResult
    public func refresh() async -> CursorDetection {
        let detection = await detect()
        switch detection {
        case .found(let identity):
            cached = identity
            cachedAt = Date()
        case .noInstallation, .notSignedIn, .unreadable:
            cached = nil
            cachedAt = nil
        }
        return detection
    }

    /// 探测一次（不更新缓存）。返回详细状态供 GUI/CLI 展示。
    public func detect() async -> CursorDetection {
        // 1. 环境变量覆盖（测试/自检）：跳过 DB 读取
        if let override = RouteConfig.envValue(["CURSOR_TOKEN"]), !override.isEmpty {
            return .found(CursorIDEIdentity(
                accessToken: normalizeToken(override),
                machineId: nil,
                expiresAt: nil
            ))
        }
        // 2. 候选数据库路径
        let paths = candidatePaths()
        guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return .noInstallation
        }
        // 3. 打开数据库（只读，绝不修改用户的 Cursor 库）
        guard let db = openDatabase(path) else {
            return .unreadable("无法打开 Cursor 数据库：\(path)")
        }
        defer { closeDatabase(db) }
        // 4. 读取 accessToken
        guard let rawToken = read(db, key: "cursorAuth/accessToken")?
            .compactMap({ normalizeToken($0) })
            .first(where: { !$0.isEmpty }) else {
            return .notSignedIn
        }
        // 5. 读取 machineId（可选）
        let machineId = read(db, key: "storage.serviceMachineId")?
            .compactMap({ normalizeToken($0) })
            .first(where: { !$0.isEmpty })
        return .found(CursorIDEIdentity(
            accessToken: rawToken,
            machineId: machineId,
            expiresAt: parseJWTExpiresAt(rawToken)
        ))
    }

    // MARK: - 路径

    /// 候选 state.vscdb 路径（`CURSOR_STATE_DB_PATH` 覆盖时仅返回该路径）。
    public func candidatePaths() -> [String] {
        if let override = RouteConfig.envValue(["CURSOR_STATE_DB_PATH"]), !override.isEmpty {
            return [override]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor - Insiders/User/globalStorage/state.vscdb",
        ]
    }

    // MARK: - SQLite（只读）

    private func openDatabase(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        return db
    }

    private func closeDatabase(_ db: OpaquePointer?) {
        sqlite3_close(db)
    }

    private func read(_ db: OpaquePointer, key: String) -> [String]? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let query = "SELECT value FROM itemTable WHERE key = ?1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        key.withCString { cstr in
            sqlite3_bind_text(stmt, 1, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                values.append(String(cString: cstr))
            }
        }
        return values.isEmpty ? nil : values
    }

    // MARK: - 值规范化

    /// 处理 `"..."` JSON 字符串包裹与 `{userId}::{jwt}` 双段格式（取 `::` 后段）。
    func normalizeToken(_ raw: String) -> String {
        var value = raw
        // JSON 字符串包裹（如 `"eyJ..."`）；顶层标量需 `.fragmentsAllowed`
        if let data = value.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let str = obj as? String {
            value = str
        }
        // `{userId}::{jwt}`：取第一个 `::` 之后的部分
        if let range = value.range(of: "::") {
            value = String(value[range.upperBound...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析 JWT `exp` claim（base64url 解码中间 payload 段）。
    func parseJWTExpiresAt(_ token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        guard let data = decodeBase64URL(String(segments[1])) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let exp = json["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}
