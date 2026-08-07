import Foundation

/// 用户配置的单个模型条目（供应商模型列表）。
///
/// 替代旧的 `disabledModels` 机制：模型列表默认为空，由用户手动添加或通过「获取模型列表」
/// 从上游拉取后选择填充。每个模型含显示名称、真实模型名与上下文窗口大小。
///
/// - `displayName`：用户可见的简短名称（如 `g52`）。为空时回退到 `modelName`。
/// - `modelName`：上游真实模型 id（如 `glm-5.2`），调用时转发给供应商。
/// - `contextLength`：上下文窗口大小，默认 1000000。
public struct ProviderModelEntry: Codable, Sendable, Equatable, Identifiable {
    public var displayName: String
    public var modelName: String
    public var contextLength: Int

    public var id: String { modelName }

    public init(displayName: String = "", modelName: String, contextLength: Int = 1_000_000) {
        self.displayName = displayName
        self.modelName = modelName
        self.contextLength = contextLength
    }

    /// 有效显示名称：用户填了就用用户填的，否则回退到模型名。
    public var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? modelName : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case modelName
        case contextLength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength) ?? 1_000_000
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(modelName, forKey: .modelName)
        try container.encode(contextLength, forKey: .contextLength)
    }
}
