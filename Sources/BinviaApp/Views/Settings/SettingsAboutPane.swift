import AppKit
import SwiftUI
import BinviaCore

/// 设置面板「关于」：版本信息 + 在线更新检查 + 链接。
/// 结构借鉴 CodexBar `PreferencesAboutPane`；更新检查为自研轻量实现
/// （GitHub Releases API，零第三方依赖，不引入 Sparkle）。
struct SettingsAboutPane: View {
    /// 更新检查状态机。
    private enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(ReleaseInfo)
        case failed(String)
    }

    @State private var checkState: CheckState = .idle
    @State private var didAutoCheck = false

    var body: some View {
        Form {
            Section {
                hero
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("当前版本") {
                    Text(versionString)
                }
                LabeledContent("检查更新") {
                    Button(checkState == .checking ? "检查中…" : "检查更新") {
                        checkForUpdates()
                    }
                    .disabled(checkState == .checking)
                }
                updateStatusRow
            } header: {
                Text("更新")
            } footer: {
                Text("通过 GitHub Releases 检查新版本；发现更新后跳转下载页，不自动安装。")
            }

            Section {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: "GitHub 仓库",
                    url: "https://github.com/wangbin3162/Binvia")
                AboutLinkRow(
                    icon: "arrow.down.circle",
                    title: "下载中心（Releases）",
                    url: "https://github.com/wangbin3162/Binvia/releases")
                AboutLinkRow(
                    icon: "exclamationmark.bubble",
                    title: "反馈问题（Issues）",
                    url: "https://github.com/wangbin3162/Binvia/issues")
            } header: {
                Text("链接")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !didAutoCheck else { return }
            didAutoCheck = true
            checkForUpdates() // 打开面板自动检查一次
        }
    }

    // MARK: - 版本信息（打包时由 build.sh 注入 Info.plist）

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let version {
            return build.map { "\(version) (\($0))" } ?? version
        }
        return "开发版"
    }

    private var buildTimestamp: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "BinviaBuildTime") as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.string(from: date)
    }

    private var gitCommit: String? {
        let commit = Bundle.main.object(forInfoDictionaryKey: "BinviaGitCommit") as? String
        return (commit == nil || commit == "unknown") ? nil : commit
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - 更新检查

    private func checkForUpdates() {
        checkState = .checking
        Task {
            do {
                let info = try await UpdateChecker().fetchLatestRelease()
                if UpdateChecker.isNewer(info.version, than: currentVersion) {
                    checkState = .updateAvailable(info)
                } else {
                    checkState = .upToDate
                }
            } catch let urlError as URLError {
                checkState = .failed(friendlyMessage(for: urlError))
            } catch {
                checkState = .failed(error.localizedDescription)
            }
        }
    }

    /// 把常见网络错误映射为可读中文提示。
    private func friendlyMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "连接超时，请检查网络后重试"
        case .notConnectedToInternet:
            return "无网络连接"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "无法连接更新服务器，请检查网络后重试"
        case .networkConnectionLost:
            return "网络连接中断，请重试"
        default:
            return error.localizedDescription
        }
    }

    @ViewBuilder
    private var updateStatusRow: some View {
        switch checkState {
        case .idle, .checking:
            EmptyView()
        case .upToDate:
            Label("已是最新版本", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .updateAvailable(info):
            VStack(alignment: .leading, spacing: 6) {
                Label("发现新版本 v\(info.version)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
                Button("前往下载") {
                    let target = info.dmgDownloadURL ?? info.htmlURL
                    if let url = URL(string: target) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        case let .failed(message):
            Label("检查失败：\(message)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 8) {
            if let image = NSApplication.shared.applicationIconImage {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .cornerRadius(14)
            }
            VStack(spacing: 2) {
                Text("Binvia")
                    .font(.title3).bold()
                Text("本地 AI 聚合网关")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let buildTimestamp {
                Text("构建于 \(buildTimestamp)\(gitCommit.map { " · \($0)" } ?? "")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

/// 链接行（借鉴 CodexBar `AboutLinkRow`）。
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
