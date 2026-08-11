import SwiftUI
import AppKit

/// 设置窗口「通用」面板：监听地址/端口、API 端点、配置文件路径、环境变量说明、保存并应用。
/// 样式与 CodexBar `GeneralPane` 一致：`Form` + `.formStyle(.grouped)` + `.scrollContentBackground(.hidden)`。
struct SettingsGeneralPane: View {
    @EnvironmentObject private var appState: AppState

    @State private var portText = ""
    @State private var saveMessage: String?
    @State private var endpointCopied = false
    @State private var pathCopied = false

    private let envVars = [
        "BINVIA_CONFIG",
        "DEEPSEEK_API_KEY",
        "DEEPSEEK_BASE_URL",
        "CODEBUDDY_CN_ACCESS_TOKEN",
        "CODEBUDDY_CN_BASE_URL",
    ]

    var body: some View {
        Form {
            Section {
                // 服务状态 + 启停按钮（与概览页 ServerStatusView 一致）
                HStack(spacing: 6) {
                    StatusBadge(
                        color: appState.isServerRunning ? BadgeColor.running : BadgeColor.stopped,
                        tooltip: appState.isServerRunning ? "运行中" : "已停止"
                    )
                    Text(appState.isServerRunning ? "运行中" : "已停止")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let err = appState.serverError, !err.isEmpty {
                        Text("· \(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Button(appState.isServerRunning ? "停止服务" : "启动服务") {
                        appState.toggleServer()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appState.isServerRunning ? .red : .accentColor)
                    .controlSize(.small)
                    .pointingHandCursor()
                }
                LabeledContent("监听地址") {
                    Text("localhost")
                        .foregroundStyle(.secondary)
                        .frame(width: 220, alignment: .trailing)
                }
                LabeledContent("监听端口") {
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                Toggle("启动 App 时自动启动服务", isOn: autoStartBinding)
            } header: {
                Text("服务管理")
            } footer: {
                Text("仅监听本机回环地址（localhost），不对外网开放。开启自动启动后，App 运行即拉起服务。")
            }

            Section {
                HStack(spacing: 8) {
                    Text(endpointText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        copyToClipboard(endpointText, flag: $endpointCopied)
                    } label: {
                        Image(systemName: endpointCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(endpointCopied ? .green : .secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 4)
                    .help("复制 API 端点")
                }
            } header: {
                Text("API 端点")
            } footer: {
                Text("OpenAI 兼容本地端点（含 /v1）。Claude Code / opencode / curl 等工具配置此地址。")
            }

            Section {
                HStack(spacing: 8) {
                    Text(appState.configPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        copyToClipboard(appState.configPath, flag: $pathCopied)
                    } label: {
                        Image(systemName: pathCopied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(pathCopied ? .green : .secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight(cornerRadius: 4)
                    .help("复制配置文件路径")
                }
            } header: {
                Text("配置文件")
            } footer: {
                Text("配置以 JSON 保存在磁盘，也可用 BINVIA_CONFIG 环境变量覆盖。")
            }

            Section {
                ForEach(envVars, id: \.self) { name in
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                        Text(name)
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("环境变量")
            } footer: {
                Text("以下变量在进程环境中存在时会被读取，优先级低于面板中保存的配置。")
            }

            Section {
                HStack {
                    if let msg = saveMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(msg.contains("失败") ? .red : .green)
                    }
                    Spacer()
                    Button("保存并应用") {
                        saveAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
        .onAppear {
            portText = String(appState.config.port)
        }
    }

    /// 展示用端点：随端口输入实时变化，端口无效时回退到当前已保存端口。
    private var endpointText: String {
        let port = Int(portText) ?? appState.config.port
        return "http://localhost:\(port)/v1"
    }

    /// 自动启动开关绑定：立即持久化（存 config.autoStartServer）。
    private var autoStartBinding: Binding<Bool> {
        Binding(
            get: { appState.config.autoStartServer },
            set: { newValue in
                appState.config.autoStartServer = newValue
                try? appState.saveConfig()
            }
        )
    }

    private func copyToClipboard(_ text: String, flag: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flag.wrappedValue = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            flag.wrappedValue = false
        }
    }

    private func saveAction() {
        guard let port = Int(portText), (1 ... 65535).contains(port) else {
            saveMessage = "端口无效"
            return
        }
        let portChanged = appState.config.port != port
        appState.config.port = port
        appState.config.host = "localhost"
        do {
            try appState.saveConfig()
        } catch {
            saveMessage = "保存失败: \(error.localizedDescription)"
            return
        }
        if portChanged && appState.isServerRunning {
            appState.restartServer()
        }
        saveMessage = appState.isServerRunning ? "已保存并应用（端口已重启）" : "已保存（启动服务器后生效）"
    }
}
