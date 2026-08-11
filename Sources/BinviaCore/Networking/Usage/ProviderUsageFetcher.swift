import Foundation

/// 供应商用量查询协议。每个支持用量/余额展示的供应商实现一个 fetcher，
/// 由 `ProviderDescriptor.usageFetcherFactory` 工厂创建并挂到注册表上。
///
/// 实现约定：
/// - 上游接口不可用时（无凭据 / 网络失败 / 非 2xx）抛错，由调用方（`UsageCache`/GUI）处理，
///   不返回「假成功」。
/// - `fetchUsage` 只查询一次，不做本地缓存；5min TTL 由 `UsageCache` actor 统一管理。
public protocol ProviderUsageFetcher: Sendable {
    /// 抓取该供应商当前的用量 / 余额快照。
    func fetchUsage(credential: ProviderCredential) async throws -> ProviderUsageSnapshot
}

/// 配额窗口（如 CodeBuddy 的积分配额窗口）。
public struct QuotaWindow: Sendable, Codable, Equatable {
    /// 展示用名称（如 "5h"、"Weekly"、模型组名）。
    public let label: String
    /// 剩余比例（0...1；`unlimited == true` 时视为 1）。
    public let remainingFraction: Double
    /// 配额重置时间（nil = 无重置或 unlimited）。
    public let resetAt: Date?
    /// 是否无限配额。
    public let unlimited: Bool
    /// 归一化后的已用额度（unlimited 时为 0）。
    public let used: Int
    /// 归一化后的总配额（unlimited 时为 0）。
    public let total: Int

    public init(
        label: String,
        remainingFraction: Double,
        resetAt: Date? = nil,
        unlimited: Bool = false,
        used: Int = 0,
        total: Int = 0
    ) {
        self.label = label
        self.remainingFraction = remainingFraction
        self.resetAt = resetAt
        self.unlimited = unlimited
        self.used = used
        self.total = total
    }

    /// 剩余百分比（0...100），unlimited 时恒为 100。
    public var remainingPercentage: Double {
        unlimited ? 100 : remainingFraction * 100
    }
}

/// 模型级配额（按模型的剩余配额 bucket）。
public struct ModelQuota: Sendable, Codable, Equatable {
    public let modelID: String
    public let remainingFraction: Double
    public let resetAt: Date?
    public let unlimited: Bool

    public init(modelID: String, remainingFraction: Double, resetAt: Date? = nil, unlimited: Bool = false) {
        self.modelID = modelID
        self.remainingFraction = remainingFraction
        self.resetAt = resetAt
        self.unlimited = unlimited
    }

    public var remainingPercentage: Double {
        unlimited ? 100 : remainingFraction * 100
    }
}

/// 多 Key 余额条目（如 DeepSeek 多 api-key 各自的余额）。`label` 为掩码后的 Key 标识。
public struct KeyedBalance: Sendable, Codable, Equatable {
    public let label: String
    public let balance: Decimal
    public let currency: String?

    public init(label: String, balance: Decimal, currency: String? = nil) {
        self.label = label
        self.balance = balance
        self.currency = currency
    }
}

/// 用量快照。由 `ProviderUsageFetcher.fetchUsage` 返回，`AppState.usageSnapshots` 持有并驱动 GUI。
///
/// 注意：`rawJSON` 存 JSON 文本而非 `[String: Any]`，保持 `Sendable`/`Codable` 兼容（UI 详情可再解析）。
public struct ProviderUsageSnapshot: Sendable, Codable, Equatable {
    public let providerID: String
    /// 账户余额（DeepSeek `total_balance`；无则 nil）。
    public let balance: Decimal?
    /// 余额币种（如 "CNY" / "USD"）。
    public let currency: String?
    /// 多 Key 余额条目（DeepSeek 多 api-key 各自余额）。非空时 GUI 逐 Key 展示。
    public let balances: [KeyedBalance]
    /// 配额窗口（无则空数组）。
    public let quotaWindows: [QuotaWindow]
    /// 模型级配额。
    public let modelQuotas: [ModelQuota]
    /// 上游原始 JSON（详情展开用；无则 nil）。
    public let rawJSON: String?
    /// 抓取时间。
    public let fetchedAt: Date
    /// 抓取失败信息（成功时 nil）。
    public let error: String?

    public init(
        providerID: String,
        balance: Decimal? = nil,
        currency: String? = nil,
        balances: [KeyedBalance] = [],
        quotaWindows: [QuotaWindow] = [],
        modelQuotas: [ModelQuota] = [],
        rawJSON: String? = nil,
        fetchedAt: Date = Date(),
        error: String? = nil
    ) {
        self.providerID = providerID
        self.balance = balance
        self.currency = currency
        self.balances = balances
        self.quotaWindows = quotaWindows
        self.modelQuotas = modelQuotas
        self.rawJSON = rawJSON
        self.fetchedAt = fetchedAt
        self.error = error
    }
}
