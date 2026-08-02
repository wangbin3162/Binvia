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
        // Phase 18：OpenAI 兼容（opencode-go / xiaomi-mimo / qwen-cloud）
        ProviderRegistry.shared.register(OpenCodeGoProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(XiaomiMimoProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(QwenCloudProviderDescriptor.descriptor)
        // Phase 18：Anthropic 兼容（zai / minimax）
        ProviderRegistry.shared.register(ZaiProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(MiniMaxProviderDescriptor.descriptor)
        // Phase 19：codex / cursor（参考 OmniRoute）
        ProviderRegistry.shared.register(CodexProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(CursorProviderDescriptor.descriptor)
    }

    /// 未在配置中出现（`config.providers` 无条目）时的默认启用状态。
    /// 目前 DeepSeek / CodeBuddy / Antigravity 已配置可用，其余供应商暂无 key，默认禁用；
    /// 一旦用户在 GUI 中保存过凭据或手动切换，config 条目即存在，以显式值为准。
    public static func isEnabledByDefault(_ providerID: String) -> Bool {
        switch providerID {
        case "deepseek", "codebuddy-cn", "antigravity":
            return true
        default:
            return false
        }
    }
}
