import AppKit
import SwiftUI
import BinviaCore

/// 设置窗口「测试」面板：选择网关密钥 + 模型，输入 prompt，直接请求本地网关
/// `/v1/chat/completions` 验证模型响应（避免每次都要配置完整流程后到 agent 中测试）。
///
/// 走本地网关而非直连上游：可同时验证网关认证、路由、白名单、上游连通性。
struct SettingsTestPane: View {
    @EnvironmentObject private var appState: AppState

    /// 选中的网关 Key（完整字符串）。
    @State private var selectedGatewayKey: String?
    /// 选中的模型（`<alias>/<modelID>`）。
    @State private var selectedModel: String?
    /// 可选模型列表（受选中 Key 的白名单约束；nil 表示未选 Key）。
    @State private var availableModels: [String] = []
    /// 正在动态拉取各供应商模型列表（无白名单时异步合并静态+动态目录）。
    @State private var isLoadingModels = false
    /// 输入 prompt。
    @State private var prompt = "hi"
    /// 响应文本（流式逐步填充）。
    @State private var responseText = ""
    /// 错误信息。
    @State private var errorMessage: String?
    /// 是否正在请求。
    @State private var isSending = false
    /// 耗时（ms）。
    @State private var latencyMS: Double?

    var body: some View {
        Form {
            Section {
                Picker("网关密钥", selection: Binding(
                    get: { selectedGatewayKey ?? "" },
                    set: { newValue in
                        selectedGatewayKey = newValue.isEmpty ? nil : newValue
                        refreshAvailableModels()
                    }
                )) {
                    Text("未选择").tag("")
                    ForEach(appState.config.apiKeys, id: \.key) { gateway in
                        Text(maskedKey(gateway.key)).tag(gateway.key)
                    }
                }

                Picker("模型", selection: Binding(
                    get: { selectedModel ?? "" },
                    set: { newValue in
                        selectedModel = newValue.isEmpty ? nil : newValue
                    }
                )) {
                    Text("未选择").tag("")
                    ForEach(availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .disabled(selectedGatewayKey == nil)

                if isLoadingModels {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在加载模型列表…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("请求参数")
            } footer: {
                Text("走本地网关 \(endpointString)/v1/chat/completions，同时验证认证、路由与上游连通性。")
            }

            Section {
                TextEditor(text: $prompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60, maxHeight: 100)

                HStack {
                    if isSending {
                        ProgressView().controlSize(.small)
                        Text("请求中…").font(.caption).foregroundStyle(.secondary)
                    } else if let latency = latencyMS {
                        Text("耗时 \(String(format: "%.0f", latency)) ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("发送") { send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend)
                        .pointingHandCursor()
                    Button("清空") {
                        responseText = ""
                        errorMessage = nil
                        latencyMS = nil
                    }
                        .buttonStyle(.bordered)
                        .disabled(isSending)
                        .pointingHandCursor()
                }
            } header: {
                Text("Prompt")
            }

            Section {
                if let error = errorMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                if !responseText.isEmpty {
                    ScrollView {
                        Text(responseText)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                } else if errorMessage == nil {
                    Text("响应将显示在此")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("响应")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            if selectedGatewayKey == nil, let first = appState.config.apiKeys.first {
                selectedGatewayKey = first.key
                refreshAvailableModels()
            }
        }
    }

    // MARK: - 派生

    private var canSend: Bool {
        !isSending && selectedGatewayKey != nil && selectedModel != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var endpointString: String {
        "http://\(appState.config.host):\(appState.config.port)"
    }

    /// 刷新可选模型列表：受选中网关 Key 的白名单约束。
    /// 无白名单时先以静态目录填充，再异步合并各供应商动态模型（`listModels`），
    /// 保证 OpenCode 等动态目录供应商能看到完整模型列表。
    private func refreshAvailableModels() {
        guard let key = selectedGatewayKey,
              let gateway = appState.config.gatewayKeyConfig(for: key) else {
            availableModels = []
            isLoadingModels = false
            return
        }
        // 白名单为 nil → 全部已启用供应商的模型；否则用白名单
        if let enabled = gateway.enabledModels {
            availableModels = enabled.sorted()
            isLoadingModels = false
            syncModelSelection()
            return
        }
        let descriptors = appState.orderedProviderDescriptors().filter(enabledAndConfigured)
        availableModels = staticModelList(descriptors)
        syncModelSelection()
        isLoadingModels = true
        let capturedKey = key
        Task { @MainActor in
            let merged = await mergedDynamicModelList(descriptors)
            // 请求期间用户切换了网关 Key → 丢弃过期结果
            guard selectedGatewayKey == capturedKey else { return }
            availableModels = merged
            isLoadingModels = false
            syncModelSelection()
        }
    }

    /// 该供应商是否已启用且已配置凭据（可进入模型列表）。
    private func enabledAndConfigured(_ descriptor: ProviderDescriptor) -> Bool {
        let enabledFlag = appState.config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id)
        return enabledFlag && appState.isProviderConfigured(descriptor.id)
    }

    /// 仅静态目录 → `<alias>/<modelID>` 列表（排除已禁用模型）。
    private func staticModelList(_ descriptors: [ProviderDescriptor]) -> [String] {
        var models: [String] = []
        var seen = Set<String>()
        for descriptor in descriptors {
            let alias = descriptor.alias ?? descriptor.id
            for model in descriptor.models where !appState.isModelDisabled(model.id, for: descriptor.id) {
                let normalized = "\(alias)/\(model.id)"
                if seen.insert(normalized).inserted {
                    models.append(normalized)
                }
            }
        }
        return models.sorted()
    }

    /// 静态目录 + 各供应商动态模型合并（动态获取成功且非空时优先用动态结果；排除已禁用模型）。
    @MainActor
    private func mergedDynamicModelList(_ descriptors: [ProviderDescriptor]) async -> [String] {
        var models: [String] = []
        var seen = Set<String>()
        for descriptor in descriptors {
            let alias = descriptor.alias ?? descriptor.id
            var list = descriptor.models
            if let provider = ProviderRegistry.shared.provider(for: descriptor.id) {
                let credential = appState.config.credential(for: descriptor.id)
                if let fetched = try? await provider.listModels(credential: credential), !fetched.isEmpty {
                    list = fetched
                }
            }
            for model in list where !appState.isModelDisabled(model.id, for: descriptor.id) {
                let normalized = "\(alias)/\(model.id)"
                if seen.insert(normalized).inserted {
                    models.append(normalized)
                }
            }
        }
        return models.sorted()
    }

    /// 当前选中模型失效时回退到列表第一个，否则保持原选择。
    private func syncModelSelection() {
        if let current = selectedModel, !availableModels.contains(current) {
            selectedModel = availableModels.first
        } else if selectedModel == nil {
            selectedModel = availableModels.first
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(key.prefix(3)) + "••••" }
        return "\(String(key.prefix(5)))••••\(String(key.suffix(4)))"
    }

    // MARK: - 发送请求

    private func send() {
        guard let key = selectedGatewayKey, let model = selectedModel else { return }
        let endpoint = endpointString
        let promptText = prompt
        isSending = true
        responseText = ""
        errorMessage = nil
        latencyMS = nil

        Task {
            let start = Date()
            do {
                let content = try await sendChatCompletion(
                    endpoint: endpoint,
                    gatewayKey: key,
                    model: model,
                    prompt: promptText
                )
                await MainActor.run {
                    self.responseText = content
                    self.latencyMS = Date().timeIntervalSince(start) * 1000
                    self.isSending = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.latencyMS = Date().timeIntervalSince(start) * 1000
                    self.isSending = false
                }
            }
        }
    }

    /// 发送非流式 chat completion 请求到本地网关，解析返回的 assistant 文本。
    private func sendChatCompletion(endpoint: String, gatewayKey: String, model: String, prompt: String) async throws -> String {
        guard let url = URL(string: "\(endpoint)/v1/chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(gatewayKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            // 尝试提取 OpenAI 风格 error.message
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw NSError(domain: "BinviaTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg)"])
            }
            throw NSError(domain: "BinviaTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"])
        }

        // 解析 OpenAI chat completion 响应
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            // 非标准响应：直接返回原始文本
            return String(data: data, encoding: .utf8) ?? "(空响应)"
        }
        return content
    }
}
