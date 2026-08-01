import Foundation

/// 配置读写。借鉴 CodexBar `CodexBarConfigStore`。
/// 路径：`~/.config/binvia/config.json`，可用环境变量 `BINVIA_CONFIG` 覆盖。
public enum ConfigStore {
    public static func defaultDirectory() -> String {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("binvia")
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent(".config/binvia")
    }

    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["BINVIA_CONFIG"], !override.isEmpty {
            return override
        }
        return (defaultDirectory() as NSString).appendingPathComponent("config.json")
    }

    public static func load(path: String? = nil) throws -> RouteConfig {
        let resolved = path ?? defaultPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            return RouteConfig()
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var config = try decoder.decode(RouteConfig.self, from: data)
        // v1 → v2 自动迁移：旧 `apiKeys: [String]` 已在 RouteConfig 解码时转为对象数组；
        // 这里补升版本号、备份原文件并写回。
        if config.version < 2 {
            try backupLegacyConfig(at: resolved)
            config.version = 2
            try save(config, to: resolved)
        }
        return config
    }

    /// 迁移前把旧版配置文件备份为 `config.json.v1.bak`（不覆盖既有备份）。
    private static func backupLegacyConfig(at path: String) throws {
        let fm = FileManager.default
        let backup = path + ".v1.bak"
        guard !fm.fileExists(atPath: backup) else { return }
        try fm.copyItem(atPath: path, toPath: backup)
    }

    public static func save(_ config: RouteConfig, to path: String? = nil) throws {
        let resolved = path ?? defaultPath()
        let fm = FileManager.default
        let dir = (resolved as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: resolved), options: .atomic)
        // 权限 0600
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resolved)
    }
}
