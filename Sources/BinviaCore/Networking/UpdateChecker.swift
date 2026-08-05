import Foundation

/// GitHub Releases 最新版本信息（在线更新检查结果）。
public struct ReleaseInfo: Sendable, Equatable {
    /// 版本号（已去 `v` 前缀），如 `0.1.3`。
    public let version: String
    /// 是否为预发布版本。
    public let isPrerelease: Bool
    /// 发布时间（ISO8601 字符串，原样透传，可为 nil）。
    public let publishedAt: String?
    /// Release 页面地址。
    public let htmlURL: String
    /// 首个 `Binvia-*.dmg` 资产直链（无 DMG 资产时为 nil）。
    public let dmgDownloadURL: String?
}

/// 在线更新检查错误。
public enum UpdateCheckError: Error, Sendable {
    case badResponse(statusCode: Int)
    case malformedPayload
}

/// 轻量在线更新检查：请求 GitHub Releases API 并与当前版本比较。
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

    /// 拉取 latest release 信息。
    public func fetchLatestRelease() async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateCheckError.malformedPayload
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("BinviaUpdateChecker/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.badResponse(statusCode: -1)
        }
        guard http.statusCode == 200 else {
            throw UpdateCheckError.badResponse(statusCode: http.statusCode)
        }
        return try Self.parse(data: data)
    }

    /// 解析 GitHub `releases/latest` 响应 JSON。
    static func parse(data: Data) throws -> ReleaseInfo {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        struct Payload: Decodable {
            let tagName: String
            let prerelease: Bool
            let publishedAt: String?
            let htmlURL: String
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case prerelease
                case publishedAt = "published_at"
                case htmlURL = "html_url"
                case assets
            }
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
        let dmg = payload.assets.first {
            $0.name.hasPrefix("Binvia-") && $0.name.hasSuffix(".dmg")
        }?.browserDownloadURL
        return ReleaseInfo(
            version: version,
            isPrerelease: payload.prerelease,
            publishedAt: payload.publishedAt,
            htmlURL: payload.htmlURL,
            dmgDownloadURL: dmg)
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
