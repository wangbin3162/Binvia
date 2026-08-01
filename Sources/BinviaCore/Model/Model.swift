import Foundation

/// 模型元数据。与 OpenAI `/v1/models` 数据结构对齐。
public struct Model: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let contextLength: Int?
    public let supportsReasoning: Bool
    public let supportsVision: Bool

    public init(
        id: String,
        name: String? = nil,
        contextLength: Int? = nil,
        supportsReasoning: Bool = false,
        supportsVision: Bool = false
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.supportsReasoning = supportsReasoning
        self.supportsVision = supportsVision
    }
}
