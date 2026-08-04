import Foundation

/// 角色归一化工具（对齐 OmniRoute `open-sse/services/roleNormalizer.ts`）。
///
/// OpenAI Responses API / 推理模型客户端（如 pi、Codex）会发送 `developer` 角色，
/// 而大多数 OpenAI 兼容上游（DeepSeek、MiniMax、GLM、Mimo 等）只认 `system`，
/// 收到 `developer` 会返回 400 "unknown variant `developer`"。
///
/// 仅对原生支持 `developer` 的供应商（openai / azure / github，或 id 含 "openai"）保留，
/// 其余一律映射为 `system`。这与 OmniRoute 的默认行为一致
/// （`PROVIDERS_PRESERVING_DEVELOPER_ROLE` 白名单 + `defaultPreserveDeveloperForProvider`）。
enum RoleNormalizer {
    /// 原生接受 `developer` 角色的供应商白名单
    /// （对齐 OmniRoute `PROVIDERS_PRESERVING_DEVELOPER_ROLE`）。
    private static let preservingProviders: Set<String> = [
        "openai",
        "azure-openai",
        "azure",
        "github",
    ]

    /// provider id 是否应保留 `developer` 角色不变。
    /// 对齐 OmniRoute `defaultPreserveDeveloperForProvider`：白名单命中，或 id 含 "openai"。
    static func preservesDeveloperRole(providerID: String) -> Bool {
        let id = providerID.trimmingCharacters(in: .whitespaces).lowercased()
        guard !id.isEmpty else { return false }
        if preservingProviders.contains(id) { return true }
        // id 含 "openai" 视为 OpenAI 兼容（如 azure-openai-gov）
        return id.contains("openai")
    }

    /// 把 messages 中的 `developer` 角色归一化为 `system`
    /// （除非 provider 在白名单内）。仅修改 role 字段，其余字段原样保留。
    /// 返回新的 JSON dict；无变更时原样返回。
    static func normalizeDeveloperRole(
        _ json: [String: Any],
        providerID: String
    ) -> [String: Any] {
        guard !preservesDeveloperRole(providerID: providerID) else { return json }
        guard var messages = json["messages"] as? [[String: Any]] else { return json }
        var changed = false
        for i in messages.indices {
            if (messages[i]["role"] as? String)?.lowercased() == "developer" {
                messages[i]["role"] = "system"
                changed = true
            }
        }
        guard changed else { return json }
        var result = json
        result["messages"] = messages
        return result
    }
}
