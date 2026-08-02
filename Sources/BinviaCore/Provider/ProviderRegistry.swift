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

    /// 注销指定 provider：移除描述符/实例/别名/模型反向索引。
    /// 用于自定义 provider 的编辑/删除（先 unregister 再 register 新版本）。
    public func unregister(_ providerID: String) {
        lock.lock()
        defer { lock.unlock() }
        descriptorsByID.removeValue(forKey: providerID)
        providersByID.removeValue(forKey: providerID)
        // 移除指向该 id 的别名
        aliasMap = aliasMap.filter { $0.value != providerID }
        // 从模型反向索引中剔除该 id（保留其它拥有者）
        for (model, owners) in modelToProviders {
            let filtered = owners.filter { $0 != providerID }
            if filtered.isEmpty {
                modelToProviders.removeValue(forKey: model)
            } else if filtered.count != owners.count {
                modelToProviders[model] = filtered
            }
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

    /// 按 `order` 返回描述符：`order` 中列出的 id 优先（保持给定顺序），
    /// 未列出的追加在末尾（按 id 字母序）。拖拽排序与 /v1/models 输出顺序共用此方法。
    public func orderedDescriptors(_ order: [String]) -> [ProviderDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        let all = descriptorsByID
        var seen = Set<String>()
        var result: [ProviderDescriptor] = []
        for id in order {
            if let d = all[id], seen.insert(id).inserted {
                result.append(d)
            }
        }
        let remaining = all.keys.filter { !seen.contains($0) }.sorted()
        for id in remaining {
            if let d = all[id] { result.append(d) }
        }
        return result
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
