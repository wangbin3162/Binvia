import AppKit
import SwiftUI
import BinviaCore

/// 设置窗口「测试」面板：选择网关密钥 + 模型，与模型进行**流式对话**。
///
/// 走本地网关 `/v1/chat/completions`（stream=true），可同时验证网关认证、路由、白名单与上游连通性；
/// 支持多轮对话（保留 messages 历史，追加 assistant 回复），流式 SSE 逐 chunk 渲染。
///
/// 交互优化：
/// - 输入框**回车即发送**，Shift+回车换行（`ChatInputTextView` AppKit 桥接）；
/// - **单一圆形按钮**：空闲 = 发送图标（paperplane.fill），发送中 = 停止图标（stop.fill），点击取消当前流；
/// - 对话气泡带角色标签、宽度限制、自动滚动到底部、发送中光标动画。
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
    /// 对话消息（role + content）。
    @State private var messages: [ChatEntry] = []
    /// 输入 prompt。
    @State private var prompt = ""
    /// 错误信息。
    @State private var errorMessage: String?
    /// 是否正在请求。
    @State private var isSending = false
    /// 耗时（ms）。
    @State private var latencyMS: Double?
    /// 会话开始时间（流式完成后计算总耗时）。
    @State private var sessionStart: Date?
    /// 当前发送 Task 的引用（用于「停止」）。
    @State private var sendTask: Task<Void, Never>?

    /// 单条对话记录（本地 UI 模型，非 BinviaCore ChatMessage，避免与后端序列化耦合）。
    struct ChatEntry: Identifiable, Equatable {
        let id = UUID()
        var role: String // "user" | "assistant"
        var content: String
    }

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
                Text("走本地网关 \(endpointString)/v1/chat/completions（流式），同时验证认证、路由与上游连通性。")
            }

            // MARK: - 对话区

            Section {
                // 对话消息列表
                chatScrollArea
                // 输入区
                inputArea
                // 底部操作行
                bottomBar
            } header: {
                // 状态显示跟随「对话」标题右侧，不单独占位
                HStack(alignment: .center, spacing: 6) {
                    Text("对话")
                    Spacer()
                    if let error = errorMessage {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("关闭") { errorMessage = nil }
                            .buttonStyle(.link)
                            .controlSize(.small)
                            .pointingHandCursor()
                    } else {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let latency = latencyMS {
                            Text("本轮 \(String(format: "%.0f", latency)) ms")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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

    // MARK: - 对话区子视图

    /// 对话消息滚动区（自动滚动到底部，发送中显示光标）。
    private var chatScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { entry in
                            messageBubble(entry)
                        }
                        if isSending {
                            typingIndicator
                                .id("typing-indicator")
                        }
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
            }
            .frame(height: 180)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .onChange(of: messages.count) { _, _ in
                // 新消息（用户提问 / 追加 assistant 占位）：延迟到布局完成后带动画滚动。
                // onChange 触发时 LazyVStack 可能尚未创建新行，立即 scrollTo 会静默失效。
                scheduleScroll(proxy, delay: 0.08, animated: true)
            }
            .onChange(of: isSending) { _, sending in
                if sending { scheduleScroll(proxy, delay: 0.08, animated: false) }
            }
            .onChange(of: messages.last?.content) { _, _ in
                // 流式 chunk：无动画高频滚动（带动画会被高频打断，导致停在半途）
                scheduleScroll(proxy, delay: 0.02, animated: false)
            }
        }
    }

    /// 延迟到布局完成后滚动到底部；animated=true 时带动画（仅发送/追加新消息用）。
    /// 流式期间用无动画滚动，避免动画被高频 chunk 打断停在半途。
    private func scheduleScroll(_ proxy: ScrollViewProxy, delay: Double, animated: Bool) {
        guard let last = messages.last else { return }
        let id = last.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // 目标消息已不是最后一条（期间又有新消息/清空）→ 跳过，由新的触发滚动
            guard messages.last?.id == id else { return }
            if animated {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    /// 空状态。
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("开始对话")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text("输入消息后回车发送，Shift+回车换行")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// 发送中「思考」光标（TimelineView 驱动三点动画）。
    private var typingIndicator: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 6, height: 6)
                        .opacity(typingOpacity(at: t, index: index))
                }
                Text("思考中…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
    }

    /// 思考光标的三点动画（错开相位，t 为 TimelineView 提供的时间）。
    private func typingOpacity(at time: TimeInterval, index: Int) -> Double {
        let phase = (time * 2 + Double(index) * 0.66).truncatingRemainder(dividingBy: 1)
        return 0.25 + 0.75 * phase
    }

    /// 输入区：文本框 + 圆形发送/停止按钮。
    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatInputTextView(
                text: $prompt,
                onSubmit: { send() },
                canSubmit: canSend,
                isEditable: !isSending,
                placeholder: "输入消息，回车发送…"
            )
            .frame(minHeight: 44, maxHeight: 88)

            // 单一圆形按钮：空闲=发送，发送中=停止
            Button(action: {
                if isSending {
                    stop()
                } else {
                    send()
                }
            }) {
                Image(systemName: isSending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(isSending ? Color.red : (canSend ? Color.accentColor : Color.gray.opacity(0.4)))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !isSending)
            .help(isSending ? "停止" : "发送（回车）")
            .pointingHandCursor()
        }
    }

    /// 底部操作行：清空对话 + 提示。
    private var bottomBar: some View {
        HStack {
            Text("回车发送 · Shift+回车换行")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                clearConversation()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isSending || messages.isEmpty)
            .pointingHandCursor()
        }
    }

    // MARK: - 状态派生

    private var canSend: Bool {
        !isSending && selectedGatewayKey != nil && selectedModel != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusText: String {
        if isSending { return "响应中…" }
        if errorMessage != nil { return "出错" }
        return messages.isEmpty ? "待开始" : "就绪"
    }

    private var statusTint: Color {
        if isSending { return .orange }
        if errorMessage != nil { return .red }
        return messages.isEmpty ? .gray : .green
    }

    private var endpointString: String {
        "http://\(appState.config.host):\(appState.config.port)"
    }

    // MARK: - 模型列表

    /// 刷新可选模型列表：从各供应商的用户配置模型列表派生，不再动态拉取上游。
    /// 受选中网关 Key 的白名单约束。
    private func refreshAvailableModels() {
        guard let key = selectedGatewayKey,
              let gateway = appState.config.gatewayKeyConfig(for: key) else {
            availableModels = []
            isLoadingModels = false
            return
        }
        // 白名单为 nil → 全部已启用供应商的用户模型；否则用白名单
        if let enabled = gateway.enabledModels {
            availableModels = enabled.sorted()
            isLoadingModels = false
            syncModelSelection()
            return
        }
        var models: [String] = []
        var seen = Set<String>()
        for descriptor in appState.orderedProviderDescriptors() {
            let enabledFlag = appState.config.providers[descriptor.id]?.enabled ?? ProviderCatalog.isEnabledByDefault(descriptor.id)
            guard enabledFlag else { continue }
            let alias = descriptor.alias ?? descriptor.id
            // 自定义 provider 的模型从 customProviderDef 读取
            let entries: [ProviderModelEntry]
            if descriptor.isUserDefined {
                entries = appState.customProviderDef(for: descriptor.id)?.models ?? []
            } else {
                entries = appState.config.providers[descriptor.id]?.userModels ?? []
            }
            for entry in entries {
                let normalized = "\(alias)/\(entry.effectiveDisplayName)"
                if seen.insert(normalized).inserted {
                    models.append(normalized)
                }
            }
        }
        availableModels = models.sorted()
        isLoadingModels = false
        syncModelSelection()
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

    // MARK: - 气泡

    /// 单条消息气泡：带角色标签（You / AI）、圆角。
    /// 气泡宽度自适应内容：user 贴合内容右对齐，AI 贴合内容左对齐，
    /// 均受上限 420 约束（超长换行）。
    private func messageBubble(_ entry: ChatEntry) -> some View {
        let isUser = entry.role == "user"
        return HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 56)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                // 角色标签
                Text(isUser ? "You" : "AI")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                // 气泡内容：先 padding+background 贴合文本宽度（短文本自适应），
                // 再 frame(maxWidth: 420) 约束上限，超长文本在气泡内自动换行。
                Text(entry.content.isEmpty ? "…" : entry.content)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isUser
                                  ? Color.accentColor.opacity(0.14)
                                  : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isUser ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), lineWidth: 1)
                    )
                    .frame(maxWidth: 420, alignment: isUser ? .trailing : .leading)
            }
            if !isUser {
                Spacer(minLength: 56)
            }
        }
    }

    // MARK: - 对话操作

    private func clearConversation() {
        messages = []
        errorMessage = nil
        latencyMS = nil
        prompt = ""
    }

    private func stop() {
        isSending = false
        // 取消当前 Task（由 send() 内的 Task 持有，置为 nil 触发 .cancel()）
        sendTask?.cancel()
        sendTask = nil
        latencyMS = Date().timeIntervalSince(sessionStart ?? Date()) * 1000
    }

    // MARK: - 发送请求（流式）

    private func send() {
        guard let key = selectedGatewayKey, let model = selectedModel else { return }
        let endpoint = endpointString
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else { return }

        // 追加用户消息 + 空 assistant 占位
        messages.append(ChatEntry(role: "user", content: promptText))
        messages.append(ChatEntry(role: "assistant", content: ""))
        prompt = ""
        errorMessage = nil
        latencyMS = nil
        isSending = true
        sessionStart = Date()

        sendTask = Task {
            let start = Date()
            do {
                // 发送流式请求；返回时 responseText 已通过 @Sendable 回调逐步写入
                let responseText = try await sendStreamingChat(
                    endpoint: endpoint,
                    gatewayKey: key,
                    model: model,
                    history: Array(messages.dropLast()), // 不含当前 assistant 占位
                    onChunk: { chunk in
                        Task { @MainActor in
                            guard let idx = self.messages.indices.last else { return }
                            // 追加到最后一个 assistant 消息
                            self.messages[idx].content += chunk
                        }
                    }
                )
                // 流结束：补全（若 onChunk 已写入则此处无操作）
                await MainActor.run {
                    if let idx = self.messages.indices.last, self.messages[idx].content.isEmpty {
                        self.messages[idx].content = responseText
                    }
                    self.isSending = false
                    self.latencyMS = Date().timeIntervalSince(start) * 1000
                    self.sendTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    // 用户点击停止：保留已收到的内容
                    if let idx = self.messages.indices.last, self.messages[idx].content.isEmpty {
                        self.messages[idx].content = "（已停止）"
                    }
                    self.isSending = false
                    self.sendTask = nil
                }
            } catch {
                await MainActor.run {
                    if let idx = self.messages.indices.last, self.messages[idx].content.isEmpty {
                        self.messages[idx].content = "（请求失败）"
                    }
                    self.errorMessage = error.localizedDescription
                    self.isSending = false
                    self.latencyMS = Date().timeIntervalSince(start) * 1000
                    self.sendTask = nil
                }
            }
        }
    }

    /// 发送流式 chat completion 到本地网关，逐 chunk 回调。
    /// 返回完整文本（供流结束时兜底）。SSE 解析：`data: {json}`，`delta.content` 逐段累加。
    private func sendStreamingChat(
        endpoint: String,
        gatewayKey: String,
        model: String,
        history: [ChatEntry],
        onChunk: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: "\(endpoint)/v1/chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(gatewayKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        // messages：history（user/assistant 交错）→ OpenAI 消息
        let bodyMessages: [[String: Any]] = history.map { entry in
            ["role": entry.role, "content": entry.content]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": bodyMessages,
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            // 收集错误体
            var errData = Data()
            for try await byte in bytes { errData.append(byte) }
            let raw = String(data: errData, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: errData) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw NSError(domain: "BinviaTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(msg)"])
            }
            throw NSError(domain: "BinviaTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw)"])
        }

        // 流式 SSE 解析
        var full = ""
        var buffer = Data()
        let doubleNewline = Data("\n\n".utf8)

        for try await byte in bytes {
            buffer.append(byte)
            // 完整事件以空行（\n\n）分隔
            while let range = buffer.range(of: doubleNewline) {
                let eventData = buffer.subdata(in: 0 ..< range.lowerBound)
                buffer.removeSubrange(0 ..< range.upperBound)
                if let line = String(data: eventData, encoding: .utf8), line.hasPrefix("data:") {
                    let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if value == "[DONE]" { continue }
                    if let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
                       let choices = json["choices"] as? [[String: Any]],
                       let delta = choices.first?["delta"] as? [String: Any],
                       let piece = delta["content"] as? String {
                        full += piece
                        onChunk(piece)
                    }
                }
            }
        }
        // 冲刷尾部（无空行结尾的最后一个事件）
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8), line.hasPrefix("data:") {
            let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if value != "[DONE]",
               let json = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let piece = delta["content"] as? String {
                full += piece
                onChunk(piece)
            }
        }
        return full
    }
}
