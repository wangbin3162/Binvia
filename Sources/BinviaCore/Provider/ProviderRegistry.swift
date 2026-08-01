import Foundation

/// 供应商注册表。借鉴 CodexBar `ProviderDescriptorRegistry` 与 OmniRoute `REGISTRY`。
/// 线程安全（NSLock）。
public final class ProviderRegistry: @unchecked Sendable {
    public static let shared = ProviderRegistry()

    private let lock = NSLock()
    private var descriptorsByID: [String: ProviderDescriptor] = [:]
    private var providersByID: [String: any Provider] = [:]
    private var aliasMap: [String: String] = [:]

    public init() {}

    public func register(_ descriptor: ProviderDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        descriptorsByID[descriptor.id] = descriptor
        providersByID[descriptor.id] = descriptor.makeProvider()
        if let alias = descriptor.alias {
            aliasMap[alias] = descriptor.id
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
}
