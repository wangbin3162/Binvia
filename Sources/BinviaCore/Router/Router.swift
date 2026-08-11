import Foundation

/// 模型路由引擎。借鉴 OmniRoute `parseModel`。
///
/// 支持的 model 语法：
/// - `provider/model`：如 `deepseek/deepseek-v4-pro`
/// - `alias/model`：如 `ds/deepseek-v4-pro`
/// - `model`：裸模型名，在所有已注册 Provider 的静态目录中查找归属
///
/// 二期消歧升级（Phase 12，OmniRoute 风格三段式 + 兜底）：
/// 1. **显式前缀**：`provider/model`、`alias/model` → 直接命中，最高优先。
/// 2. **单候选直选**：裸模型名全局唯一供应商拥有 → 直接命中。
/// 3. **前缀启发式**：按模型名前缀推断归属（`gpt-*` → OpenAI 系、`glm-*` → GLM 系、
///    `deepseek-*` → DeepSeek 等），仅在多个供应商拥有同名模型时生效。
/// 4. **前缀优先 + 字母序兜底**：模型 id 以供应商 id/别名开头者优先，仍歧义取字母序第一个。
public struct Router: Sendable {
    public let registry: ProviderRegistry

    public init(registry: ProviderRegistry = .shared) {
        self.registry = registry
    }

    public struct Resolution: Sendable, Equatable {
        public let providerID: String
        public let modelID: String

        public init(providerID: String, modelID: String) {
            self.providerID = providerID
            self.modelID = modelID
        }
    }

    /// 解析模型字符串。失败返回 nil（未知 provider 或未知模型）。
    public func resolve(_ model: String) -> Resolution? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 阶段 1：显式前缀
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let providerPart = String(parts[0])
            let modelPart = String(parts[1])
            guard let canonical = registry.canonicalProviderID(providerPart) else { return nil }
            guard registry.descriptor(for: canonical) != nil else { return nil }
            return Resolution(providerID: canonical, modelID: modelPart)
        }

        let owners = registry.providers(forModel: trimmed)
        guard !owners.isEmpty else { return nil }

        // 阶段 2：单候选直选
        if owners.count == 1 {
            return Resolution(providerID: owners[0], modelID: trimmed)
        }

        // 阶段 3：前缀启发式（仅在多供应商拥有同名模型时消歧）
        if let heuristic = prefixHeuristicMatch(trimmed, owners: owners) {
            return Resolution(providerID: heuristic, modelID: trimmed)
        }

        // 阶段 4：前缀优先 + 字母序兜底（旧逻辑，保证确定性）
        if let explicit = owners.first(where: { ownerID in
            let descriptor = registry.descriptor(for: ownerID)
            let alias = descriptor?.alias
            return trimmed.hasPrefix(ownerID) || (alias.map { trimmed.hasPrefix($0) } ?? false)
        }) {
            return Resolution(providerID: explicit, modelID: trimmed)
        }
        if let first = owners.first {
            return Resolution(providerID: first, modelID: trimmed)
        }
        return nil
    }

    /// 前缀启发式：模型家族前缀 → 供应商映射。仅当对应供应商确实拥有该模型时生效。
    /// 映射规则（Phase 2 对齐）：`glm-*` → CodeBuddyCN/GLM 系、`deepseek-*` → DeepSeek、
    /// `kimi-*` → Kimi、`minimax*` → MiniMax、`mimo-*` → XiaomiMiMo。
    private func prefixHeuristicMatch(_ modelID: String, owners: [String]) -> String? {
        let rules: [(prefix: String, providerID: String)] = [
            ("glm", "codebuddy-cn"),     // GLM 系（CodeBuddyCN / z.ai）
            ("deepseek", "deepseek"),
            ("kimi", "kimi"),
            ("minimax", "minimax"),
            ("mimo", "xiaomi-mimo"),
        ]
        for rule in rules where modelID.hasPrefix(rule.prefix) {
            if owners.contains(rule.providerID) {
                return rule.providerID
            }
        }
        return nil
    }
}
