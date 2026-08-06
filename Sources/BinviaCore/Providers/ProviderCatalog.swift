import Foundation

/// 供应商目录：负责注册所有内置供应商。
/// 借鉴 CodexBar `ProviderDescriptorRegistry.bootstrap` 与 OmniRoute `REGISTRY` 登记表。
public enum ProviderCatalog {
    public static func registerAll() {
        ProviderRegistry.shared.register(DeepSeekProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(CodeBuddyCNProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(AntigravityProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(OpenCodeProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(KimiProviderDescriptor.descriptor)
        // Phase 18：OpenAI 兼容（opencode-go / xiaomi-mimo）
        ProviderRegistry.shared.register(OpenCodeGoProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(XiaomiMimoProviderDescriptor.descriptor)
        // Phase 18：Anthropic 兼容（zai / minimax）
        ProviderRegistry.shared.register(ZaiProviderDescriptor.descriptor)
        ProviderRegistry.shared.register(MiniMaxProviderDescriptor.descriptor)
        // Phase 19：cursor（参考 OmniRoute）
        ProviderRegistry.shared.register(CursorProviderDescriptor.descriptor)
    }

    /// 注册用户自定义的 OpenAI 兼容 Provider（来自 `RouteConfig.customProviderDefs`）。
    ///
    /// 在 `registerAll()` 之后调用，把 GUI 里新增的兼容 provider 注入注册表。
    /// 自定义 provider 的 descriptor：
    /// - `models` 留空（路由仅靠显式前缀 `<id>/<model>`，不参与裸名消歧）；
    /// - `usageFetcherFactory` 返回 nil（无用量卡片）；
    /// - `isUserDefined = true`（UI 据此切换可编辑模型列表）。
    /// 编辑/删除由 `AppState` 通过 `registry.unregister` + `register` 热更新，不在此处处理。
    public static func registerCustomProviders(from config: RouteConfig) {
        for def in config.customProviderDefs {
            guard let baseURL = URL(string: def.baseURL) else { continue }
            let descriptor = ProviderDescriptor(
                metadata: ProviderMetadata(
                    id: def.id,
                    alias: def.id,
                    displayName: def.displayName,
                    authType: .apiKey
                ),
                baseURL: baseURL,
                models: [],
                supportsStreaming: true,
                usageFetcherFactory: { nil },
                isUserDefined: true,
                makeProvider: { GenericOpenAIProvider(id: def.id, baseURL: baseURL, models: def.models) }
            )
            ProviderRegistry.shared.register(descriptor)
        }
    }

    /// 未在配置中出现（`config.providers` 无条目）时的默认启用状态。
    /// 目前 DeepSeek / CodeBuddy / Antigravity 已配置可用，其余供应商暂无 key，默认禁用；
    /// 一旦用户在 GUI 中保存过凭据或手动切换，config 条目即存在，以显式值为准。
    /// 供应商默认启用状态。当前策略：**全部默认禁用**（新装用户需在设置面板逐个启用），
    /// 避免未配置凭据的供应商被误路由；用户显式配置/启用后以 config 为准。
    public static func isEnabledByDefault(_ providerID: String) -> Bool {
        false
    }
}
