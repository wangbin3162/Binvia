import Foundation

/// 供应商目录：负责注册所有内置供应商。
/// 借鉴 CodexBar `ProviderDescriptorRegistry.bootstrap` 与 OmniRoute `REGISTRY` 登记表。
public enum ProviderCatalog {
    public static func registerAll() {
        ProviderRegistry.shared.register(DeepSeekProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(CodeBuddyCNProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(AntigravityProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(OpenAIProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(OpenCodeProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(KimiProviderDescriptor.descriptor)
    }
}
