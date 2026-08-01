import Foundation

/// 模型路由引擎。借鉴 OmniRoute `parseModel`。
///
/// 支持的 model 语法：
/// - `provider/model`：如 `deepseek/deepseek-v4-pro`
/// - `alias/model`：如 `ds/deepseek-v4-pro`
/// - `model`：裸模型名，在所有已注册 Provider 的静态目录中查找归属
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

        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let providerPart = String(parts[0])
            let modelPart = String(parts[1])
            guard let canonical = registry.canonicalProviderID(providerPart) else { return nil }
            guard registry.descriptor(for: canonical) != nil else { return nil }
            return Resolution(providerID: canonical, modelID: modelPart)
        }

        // 裸模型名：在静态目录中查找归属。多个供应商有同名模型时消歧：
        // 1) 模型 id 以供应商 id 或别名开头（如 deepseek-v4-pro → deepseek）优先；
        // 2) 仍歧义时取字母序第一个（确定性），文档提示用 provider/model 显式指定。
        let matches = registry.allDescriptors().filter {
            $0.models.contains(where: { $0.id == trimmed })
        }
        if let explicit = matches.first(where: { descriptor in
            trimmed.hasPrefix(descriptor.id) || (descriptor.alias.map { trimmed.hasPrefix($0) } ?? false)
        }) {
            return Resolution(providerID: explicit.id, modelID: trimmed)
        }
        if let first = matches.first {
            return Resolution(providerID: first.id, modelID: trimmed)
        }
        return nil
    }
}
