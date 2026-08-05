import Foundation

/// GitHub 最新版本信息（在线更新检查结果）。
public struct ReleaseInfo: Sendable, Equatable {
    /// 版本号（已去 `v` 前缀），如 `0.1.3`。
    public let version: String
    /// Release 页面地址。
    public let htmlURL: String
    /// DMG 资产直链（按命名约定构造）。
    public let dmgDownloadURL: String?
}

/// 在线更新检查错误（中文描述，直接展示给用户）。
public enum UpdateCheckError: Error, Sendable, LocalizedError {
    case badResponse(statusCode: Int)
    case malformedPayload

    public var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            switch code {
            case 403:
                return "更新服务限流（HTTP 403），请稍后重试"
            case 404:
                return "未找到版本信息（HTTP 404）"
            default:
                return "更新服务返回异常（HTTP \(code)）"
            }
        case .malformedPayload:
            return "无法解析更新信息"
        }
    }
}

/// 轻量在线更新检查。
///
/// 实现方式：请求 `https://github.com/<repo>/releases/latest`，跟随其 302 重定向，
/// 从最终 URL（`/releases/tag/vX.Y.Z`）解析最新版本。
/// 不依赖 `api.github.com`（未认证请求有 60 次/小时/IP 限流，且部分地区不稳定）。
///
/// 零第三方依赖（不引入 Sparkle）：只负责「发现新版本 + 提供下载链接」，
/// 不做自动下载/安装。网络层注入 `URLSession` 便于测试（URLProtocolMock）。
public struct UpdateChecker: Sendable {
    public let repo: String
    private let session: URLSession

    public init(repo: String = "wangbin3162/Binvia", session: URLSession = .shared) {
        self.repo = repo
        self.session = session
    }

    /// 解析最新版本信息。
    /// 生产环境：URLSession 自动跟随 302；测试环境（URLProtocolMock）不会自动跟随，
    /// 故这里手动跟随 Location（最多 5 跳），两种场景行为一致。
    public func fetchLatestRelease() async throws -> ReleaseInfo {
        var currentURL = URL(string: "https://github.com/\(repo)/releases/latest")!
        for _ in 0..<5 {
            var request = URLRequest(url: currentURL)
            request.timeoutInterval = 15
            request.setValue("BinviaUpdateChecker/1.0", forHTTPHeaderField: "User-Agent")

            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateCheckError.badResponse(statusCode: -1)
            }
            // 手动跟随重定向（Location 可为相对路径，relativeTo 解析）
            if let location = http.allHeaderFields["Location"] as? String,
               let redirectURL = URL(string: location, relativeTo: http.url) {
                currentURL = redirectURL
                continue
            }
            guard (200..<400).contains(http.statusCode) else {
                throw UpdateCheckError.badResponse(statusCode: http.statusCode)
            }
            // 最终 URL 形如 https://github.com/<repo>/releases/tag/vX.Y.Z
            guard let finalURL = http.url?.absoluteString,
                  let version = Self.extractVersion(from: finalURL) else {
                throw UpdateCheckError.malformedPayload
            }
            let htmlURL = "https://github.com/\(repo)/releases/tag/v\(version)"
            let dmgURL = "https://github.com/\(repo)/releases/download/v\(version)/Binvia-\(version)-macos-arm64-x86_64.dmg"
            return ReleaseInfo(version: version, htmlURL: htmlURL, dmgDownloadURL: dmgURL)
        }
        throw UpdateCheckError.malformedPayload
    }

    /// 从 `…/releases/tag/v0.1.3` 提取版本号 `0.1.3`（无匹配返回 nil）。
    public static func extractVersion(from urlString: String) -> String? {
        guard let range = urlString.range(of: "/releases/tag/v") else { return nil }
        var version = String(urlString[range.upperBound...])
        if version.hasSuffix("/") { version.removeLast() }
        // 剔除可能的查询参数/锚点
        if let end = version.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            version = String(version[..<end])
        }
        return version.isEmpty ? nil : version
    }

    /// 版本号比较（按 `.` 分段数字比较）：`0.1.10 > 0.1.2`。
    /// 某段非纯数字时退化为字符串比较兜底；相等返回 false。
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").map(String.init)
        let b = current.split(separator: ".").map(String.init)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : "0"
            let bv = i < b.count ? b[i] : "0"
            if let an = Int(av), let bn = Int(bv) {
                if an != bn { return an > bn }
            } else if av != bv {
                return av > bv
            }
        }
        return false
    }
}
