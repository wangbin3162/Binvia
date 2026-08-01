import Foundation

/// 供应商注册表。借鉴 CodexBar `ProviderDescriptorRegistry` 与 OmniRoute `REGISTRY`。
/// 线程安全（NSLock）。
public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var descriptorsByID: [String: ProviderDescriptor] = [:]
    private var providersByID: [String: any Provider] = [:]
    private var aliasMap: [String: String] = [:]
    /// 模型名 → 拥有该模型的 provider id 列表（Phase 12 反向索引，Router 消歧用）。
    /// 由 `register` 在静态目录注册时构建；动态模型不参与（路由只认静态目录兜底）。
    private var modelToProviders: [String: [String]] = [:]

    public init() {}

    public func register(_ descriptor: ProviderDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptorsByID[descriptor.id] = descriptor
        providersByID[descriptor.id] = descriptor.makeProvider()
        if let alias = descriptor.alias {
            aliasMap[alias] = descriptor.id
        }
        // 反向索引：模型 → 拥有者集合（去重，保持插入序）
        for model in descriptor.models {
            var owners = modelToProviders[model.id] ?? []
            if !owners.contains(descriptor.id) {
                owners.append(descriptor.id)
            }
            modelToProviders[model.id] = owners
        }
    }

    public func descriptor(for id: String) -> ProviderDescriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptorsByID[id]
    }

    public func provider(for id: String) -> (any Provider)? {
        lock.lock()
        defer { lock.unlock() }
        return providersByID[id]
    }

    public func allDescriptors() -> [ProviderDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return Array(descriptorsByID.values).sorted { $0.id < $1.id }
    }

    public func allProviders() -> [(String, any Provider)] {
        lock.lock()
        defer { lock.unlock() }
        return providersByID.sorted { $0.key < $1.key }
    }

    /// 通过 provider id 或别名解析真实 provider id。
    public func canonicalProviderID(_ idOrAlias: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if descriptorsByID[idOrAlias] != nil { return idOrAlias }
        return aliasMap[idOrAlias]
    }

    /// 拥有指定静态模型名的全部 provider id（字母序，确定性）。空 = 无 provider 声明该模型。
    public func providers(forModel modelID: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return (modelToProviders[modelID] ?? []).sorted()
    }
}
