import SwiftUI

/// 设置窗口「通用」面板：监听地址/端口、配置文件路径、环境变量说明、保存并应用。
/// 样式与 CodexBar `GeneralPane` 一致：`Form` + `.formStyle(.grouped)` + `.scrollContentBackground(.hidden)`。
struct SettingsGeneralPane: View {
    @EnvironmentObject private var appState: AppState

    @State private var portText = ""
    @State private var hostText = ""
    @State private var saveMessage: String?

    private let envVars = [
        "BINVIA_CONFIG",
        "DEEPSEEK_API_KEY",
        "DEEPSEEK_BASE_URL",
        "CODEBUDDY_CN_ACCESS_TOKEN",
        "CODEBUDDY_CN_BASE_URL",
        "ANTIGRAVITY_BASE_URL",
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("监听地址") {
                    TextField("", text: $hostText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                LabeledContent("监听端口") {
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            } header: {
                Text("服务器")
            } footer: {
                Text("启动后，任意工具（Claude Code / Codex / curl 等）通过 http://\(hostText):\(portText) 访问本地网关。")
            }

            Section {
                LabeledContent("路径") {
                    Text(appState.configPath)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
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
            hostText = appState.config.host
        }
    }

    private func saveAction() {
        guard let port = Int(portText), (1 ... 65535).contains(port) else {
            saveMessage = "端口无效"
            return
        }
        let portChanged = appState.config.port != port
        appState.config.port = port
        appState.config.host = hostText.trimmingCharacters(in: .whitespaces)
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
