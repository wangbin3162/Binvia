import Foundation
import SQLite3

/// OpenCode Go 本地用量读取错误。
public enum OpenCodeGoLocalUsageError: LocalizedError, Sendable, Equatable {
    case notDetected
    case historyUnavailable(String)
    case sqliteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notDetected:
            "未检测到本地 OpenCode Go 数据：请先用 opencode CLI 登录并调用 opencode-go，或检查 opencode.db。"
        case let .historyUnavailable(message):
            "OpenCode Go 本地用量不可用：\(message)"
        case let .sqliteFailed(message):
            "OpenCode Go 本地数据库读取失败：\(message)"
        }
    }
}

/// OpenCode Go 本地用量读取器（参考 CodexBar `OpenCodeGoLocalUsageReader`）。
///
/// 读取 opencode CLI 的本地 SQLite（默认 `~/.local/share/opencode/opencode.db`），
/// 统计 `providerID ∈ {opencode-go, opencodego}` 的 assistant 成本，按
/// $12/5h、$30/周、$60/月估算三个配额窗口。兼容 `message` 表以及新版
/// `part` 表（`step-finish` 成本，`data.time.created` 缺失时回退 `part.time_created`）。
public struct OpenCodeGoLocalUsageReader: Sendable {
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let week: TimeInterval = 7 * 24 * 60 * 60
    private static let limits = (session: 12.0, weekly: 30.0, monthly: 60.0)

    private let authURL: URL
    private let databaseURL: URL

    public init() {
        if let dir = RouteConfig.envValue(["OPENCODE_GO_LOCAL_DIR"]), !dir.isEmpty {
            self.init(localDirectory: URL(fileURLWithPath: dir))
        } else {
            self.init(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    public init(homeDirectory: URL) {
        let openCodeDirectory = homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
        self.init(localDirectory: openCodeDirectory)
    }

    public init(authURL: URL, databaseURL: URL) {
        self.authURL = authURL
        self.databaseURL = databaseURL
    }

    private init(localDirectory: URL) {
        self.authURL = localDirectory.appendingPathComponent("auth.json", isDirectory: false)
        self.databaseURL = localDirectory.appendingPathComponent("opencode.db", isDirectory: false)
    }

    /// 读取本地用量快照。数据库或 auth.json 不存在、没有 opencode-go 记录时抛错。
    public func fetch(now: Date = Date()) throws -> ProviderUsageSnapshot {
        let hasAuth = Self.hasAuthKey(at: self.authURL)
        guard FileManager.default.fileExists(atPath: self.databaseURL.path) else {
            if hasAuth {
                throw OpenCodeGoLocalUsageError.historyUnavailable("opencode.db 不存在")
            }
            throw OpenCodeGoLocalUsageError.notDetected
        }

        let rows = try self.readRows()
        guard hasAuth || !rows.isEmpty else {
            throw OpenCodeGoLocalUsageError.notDetected
        }
        guard !rows.isEmpty else {
            throw OpenCodeGoLocalUsageError.historyUnavailable("没有本地 opencode-go 使用记录")
        }
        return Self.snapshot(rows: rows, now: now)
    }

    // MARK: - SQLite

    private func readRows() throws -> [UsageRow] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(self.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw OpenCodeGoLocalUsageError.sqliteFailed(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = self.hasPartTable(db: db) ? Self.messageAndPartUsageSQL : Self.messageUsageSQL
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw OpenCodeGoLocalUsageError.sqliteFailed(message)
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [UsageRow] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
                throw OpenCodeGoLocalUsageError.sqliteFailed(message)
            }
            let createdMs = sqlite3_column_int64(stmt, 0)
            let cost = sqlite3_column_double(stmt, 1)
            guard createdMs > 0, cost >= 0, cost.isFinite else { continue }
            rows.append(UsageRow(createdMs: createdMs, cost: cost))
        }
        return rows
    }

    private func hasPartTable(db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'part' LIMIT 1",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 无 `part` 表的旧库：直接读 `message` 上的 assistant 成本。
    private static let messageUsageSQL = """
        SELECT
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') IN ('opencode-go', 'opencodego')
          AND json_extract(data, '$.role') = 'assistant'
          AND json_type(data, '$.cost') IN ('integer', 'real')
    """

    /// 新版库：优先取 `part` 的 `step-finish` 成本（消息无 step-finish 成本时回退 message 成本），
    /// 避免同一请求在 message 与 part 各计一次。
    private static let messageAndPartUsageSQL = """
        WITH provider_messages AS (
          SELECT
            id AS messageID,
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost,
            json_type(data, '$.cost') IN ('integer', 'real') AS hasCost
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') IN ('opencode-go', 'opencodego')
            AND json_extract(data, '$.role') = 'assistant'
        )
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
    """

    private struct UsageRow {
        let createdMs: Int64
        let cost: Double
    }

    // MARK: - 快照计算（参考 CodexBar）

    private static func snapshot(rows: [UsageRow], now: Date) -> ProviderUsageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStartMs = nowMs - Int64(self.fiveHours * 1000)
        let weekStartMs = Int64(self.startOfUTCWeek(now: now).timeIntervalSince1970 * 1000)
        let weekEndMs = weekStartMs + Int64(self.week * 1000)
        let earliestMs = rows.map(\.createdMs).min()
        let monthBounds = self.monthBounds(now: now, anchorMs: earliestMs)

        var sessionCost = 0.0
        var weeklyCost = 0.0
        var monthlyCost = 0.0
        var oldestSessionMs: Int64?
        for row in rows {
            if row.createdMs >= sessionStartMs, row.createdMs < nowMs {
                sessionCost += row.cost
                if oldestSessionMs.map({ row.createdMs < $0 }) ?? true {
                    oldestSessionMs = row.createdMs
                }
            }
            if row.createdMs >= weekStartMs, row.createdMs < weekEndMs {
                weeklyCost += row.cost
            }
            if row.createdMs >= monthBounds.startMs, row.createdMs < monthBounds.endMs {
                monthlyCost += row.cost
            }
        }

        let rollingResetInSec = max(
            0,
            Int(((oldestSessionMs ?? nowMs) + Int64(self.fiveHours * 1000) - nowMs) / 1000)
        )
        let weeklyResetInSec = max(0, Int((weekEndMs - nowMs) / 1000))
        let monthlyResetInSec = max(0, Int((monthBounds.endMs - nowMs) / 1000))

        let sessionPercent = self.percent(used: sessionCost, limit: self.limits.session)
        let weeklyPercent = self.percent(used: weeklyCost, limit: self.limits.weekly)
        let monthlyPercent = self.percent(used: monthlyCost, limit: self.limits.monthly)

        let windows = [
            QuotaWindow(
                label: "$12 / 5小时",
                remainingFraction: 1 - sessionPercent / 100,
                resetAt: now.addingTimeInterval(TimeInterval(rollingResetInSec)),
                used: Int((sessionPercent / 100 * self.limits.session).rounded()),
                total: Int(self.limits.session.rounded())
            ),
            QuotaWindow(
                label: "$30 / 周",
                remainingFraction: 1 - weeklyPercent / 100,
                resetAt: now.addingTimeInterval(TimeInterval(weeklyResetInSec)),
                used: Int((weeklyPercent / 100 * self.limits.weekly).rounded()),
                total: Int(self.limits.weekly.rounded())
            ),
            QuotaWindow(
                label: "$60 / 月",
                remainingFraction: 1 - monthlyPercent / 100,
                resetAt: now.addingTimeInterval(TimeInterval(monthlyResetInSec)),
                used: Int((monthlyPercent / 100 * self.limits.monthly).rounded()),
                total: Int(self.limits.monthly.rounded())
            ),
        ]

        return ProviderUsageSnapshot(
            providerID: "opencode-go",
            quotaWindows: windows,
            fetchedAt: now
        )
    }

    private static func percent(used: Double, limit: Double) -> Double {
        guard used.isFinite, limit > 0 else { return 0 }
        return max(0, min(100, used / limit * 100))
    }

    private static func hasAuthKey(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        for key in ["opencode-go", "opencodego"] {
            if let entry = object[key] as? [String: Any],
               let value = entry["key"] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return true
            }
        }
        return false
    }

    private static func startOfUTCWeek(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return calendar.date(from: components) ?? now
    }

    /// 月度窗口以最早一条本地记录为锚点，尽量贴近真实计费周期。
    private static func monthBounds(now: Date, anchorMs: Int64?) -> (startMs: Int64, endMs: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

        guard let anchorMs else {
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
        }

        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
        let anchorComponents = calendar.dateComponents(
            [.day, .hour, .minute, .second, .nanosecond],
            from: anchor
        )
        let nowComponents = calendar.dateComponents([.year, .month], from: now)

        var startMonthComponents = nowComponents
        var start = self.anchoredMonth(
            calendar: calendar,
            month: startMonthComponents,
            anchor: anchorComponents
        )
        if start > now {
            guard let previous = calendar.date(byAdding: .month, value: -1, to: start) else {
                let end = self.anchoredMonth(
                    calendar: calendar,
                    month: self.monthComponents(after: startMonthComponents, calendar: calendar),
                    anchor: anchorComponents
                )
                return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
            }
            startMonthComponents = calendar.dateComponents([.year, .month], from: previous)
            start = self.anchoredMonth(
                calendar: calendar,
                month: startMonthComponents,
                anchor: anchorComponents
            )
        }
        let end = self.anchoredMonth(
            calendar: calendar,
            month: self.monthComponents(after: startMonthComponents, calendar: calendar),
            anchor: anchorComponents
        )
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    private static func monthComponents(after month: DateComponents, calendar: Calendar) -> DateComponents {
        let monthStart = calendar.date(from: month) ?? Date()
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        return calendar.dateComponents([.year, .month], from: nextMonth)
    }

    private static func anchoredMonth(
        calendar: Calendar,
        month: DateComponents,
        anchor: DateComponents
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = month.year
        components.month = month.month
        components.day = anchor.day
        components.hour = anchor.hour
        components.minute = anchor.minute
        components.second = anchor.second
        components.nanosecond = anchor.nanosecond

        if let date = calendar.date(from: components),
           calendar.component(.month, from: date) == month.month
        {
            return date
        }

        let monthStart = calendar.date(from: month) ?? Date()
        components.day = calendar.range(of: .day, in: .month, for: monthStart)?.count
        return calendar.date(from: components) ?? Date()
    }
}
