import AppKit
import SwiftUI
import BinviaCore

/// 设置窗口「兼容 Provider」面板：管理用户自定义的 OpenAI 兼容供应商。
///
/// 列表区：展示已添加的兼容 Provider（首字母圆角图标 + 名称 + BaseURL + 编辑/删除）。
/// 新增区：输入供应商名称与 BaseURL，确认后写入 config 并注册到 `ProviderRegistry`，
/// 随即在「供应商」侧栏底部出现该 Provider；点开后可配置 API 令牌、手动增删模型、测试连通。
///
/// 设计参考 OmniRoute 的「compatible provider node」模式：id 由名称生成 slug，
/// 模型以 `<id>/<model>` 形式路由，认证固定 `Authorization: Bearer <key>`。
struct SettingsCompatProvidersPane: View {
    @EnvironmentObject private var appState: AppState

    // 新增表单
    @State private var newName = ""
    @State private var newBaseURL = ""
    @State private var addError: String?

    // 行内编辑态
    @State private var editingID: String?
    @State private var editName = ""
    @State private var editBaseURL = ""

    var body: some View {
        Form {
            Section {
                if appState.config.customProviderDefs.isEmpty {
                    Text("尚未添加兼容供应商")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.config.customProviderDefs, id: \.id) { def in
                        if editingID == def.id {
                            editRow(def)
                        } else {
                            displayRow(def)
                        }
                    }
                }
            } header: {
                Text("已配置的兼容供应商")
            } footer: {
                Text("添加后在「供应商」列表底部选择该 Provider，配置 API 令牌与模型。模型以 <provider>/<model> 形式调用。")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("供应商名称", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Base URL", text: $newBaseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if let addError {
                            Text(addError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Button("添加") {
                            addProvider()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .pointingHandCursor()
                        .disabled(!isAddFormValid)
                    }
                }
            } header: {
                Text("添加兼容供应商")
            } footer: {
                Text("Base URL 需为 http/https，指向 OpenAI 兼容端点（如 https://api.example.com/v1）。")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var isAddFormValid: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func displayRow(_ def: CustomProviderDef) -> some View {
        HStack(spacing: 10) {
            ProviderBrandIcon(providerID: def.id, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(def.displayName).font(.body.weight(.medium))
                Text(def.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                editingID = def.id
                editName = def.displayName
                editBaseURL = def.baseURL
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .help("编辑")

            Button(role: .destructive) {
                try? appState.deleteCustomProvider(id: def.id)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: 4)
            .help("删除")
        }
        .padding(.vertical, 2)
    }

    private func editRow(_ def: CustomProviderDef) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProviderBrandIcon(providerID: def.id, size: 24)
                    Text("供应商名称")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                    TextField("", text: $editName, prompt: Text("例如 tokenhub"))
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 10) {
                    // 占位图标使第二行输入框与第一行保持同一列。
                    Color.clear
                        .frame(width: 24, height: 1)
                    Text("Base URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                    TextField("", text: $editBaseURL, prompt: Text("https://api.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("取消") {
                    editingID = nil
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
                Button("保存") {
                    try? appState.updateCustomProvider(
                        id: def.id, displayName: editName, baseURL: editBaseURL)
                    editingID = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
                .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 2)
    }

    private func addProvider() {
        addError = nil
        do {
            if try appState.addCustomProvider(name: newName, baseURL: newBaseURL) != nil {
                newName = ""
                newBaseURL = ""
            } else {
                addError = "名称不能为空，且 Base URL 需为合法 http/https 地址"
            }
        } catch {
            addError = error.localizedDescription
        }
    }
}
