import Foundation
import CryptoKit

/// Responses namespace 子工具的原始身份（F2）：`{namespace, name}`。
public struct ResponsesToolIdentity: Sendable, Equatable {
    public let namespace: String
    public let name: String

    public init(namespace: String, name: String) {
        self.namespace = namespace
        self.name = name
    }
}

/// 请求级 wire name → namespace 身份映射。
///
/// 只在单次请求内传递：ResponsesRequestTranslator 产出，响应翻译器消费；
/// 不进入 ChatRequest 编解码，避免污染 rawBody。
public struct ResponsesToolIdentityMap: Sendable, Equatable {
    public let entries: [String: ResponsesToolIdentity]

    public init(_ entries: [String: ResponsesToolIdentity] = [:]) {
        self.entries = entries
    }

    public func identity(forWireName wireName: String) -> ResponsesToolIdentity? {
        entries[wireName]
    }
}

/// Responses 工具收集结果：合并后的工具列表 + namespace 身份映射。
public struct ResponsesToolCollection {
    public let tools: [[String: Any]]
    public let identityMap: ResponsesToolIdentityMap

    public init(tools: [[String: Any]], identityMap: ResponsesToolIdentityMap) {
        self.tools = tools
        self.identityMap = identityMap
    }
}

/// Responses 工具收集器（F1）：合并顶层 `tools` 与 input items 里的
/// `additional_tools`，显式顶层声明优先，同名 namespace 合并。
///
/// 参考 OmniRoute `additionalTools.ts` / `namespaceFlatten.ts`：
/// - namespace 子工具拍平成 `"\(nsName)__\(leaf)"`，超过 64 字符确定性 hash 截断；
/// - leaf 已含 `__` 不再重复加前缀；
/// - 身份映射只在收集阶段生成，翻译器不解析 wire name。
public enum ResponsesToolCollector {
    /// Chat Completions function 名长度上限（OpenAI 系上游常见约束）。
    public static let maxToolNameLength = 64

    public static func collect(rootTools: [[String: Any]]?, inputItems: [Any]) -> ResponsesToolCollection {
        let rootList = rootTools ?? []
        var sources: [[[String: Any]]] = [rootList]
        for item in inputItems {
            guard let record = item as? [String: Any],
                  record["type"] as? String == "additional_tools",
                  let tools = record["tools"] as? [[String: Any]] else { continue }
            sources.append(tools)
        }

        // 显式顶层声明优先：namespace 内与顶层同名的子工具被剔除。
        let explicitNames = Set<String>(sources.flatMap { list in
            list.compactMap { tool in
                guard (tool["type"] as? String) != "namespace" else { return nil }
                let name = toolName(tool)
                return name.isEmpty ? nil : name
            }
        })

        var merged: [[String: Any]] = []
        var seen = Set<String>()
        var namespaceIndexes: [String: Int] = [:]

        for source in sources {
            for tool in source {
                guard let type = tool["type"] as? String else {
                    let name = toolName(tool)
                    if !name.isEmpty, seen.insert(name).inserted {
                        merged.append(tool)
                    }
                    continue
                }
                if type == "namespace" {
                    let nsName = toolName(tool)
                    let subTools = (tool["tools"] as? [[String: Any]]) ?? []
                    let filtered = subTools.filter { !explicitNames.contains(toolName($0)) }
                    if !nsName.isEmpty, let existing = namespaceIndexes[nsName] {
                        let current = (merged[existing]["tools"] as? [[String: Any]]) ?? []
                        var mergedTool = merged[existing]
                        mergedTool["tools"] = mergeNamespaceTools(first: current, second: filtered)
                        merged[existing] = mergedTool
                    } else {
                        var newTool = tool
                        newTool["tools"] = filtered
                        if !nsName.isEmpty {
                            namespaceIndexes[nsName] = merged.count
                        }
                        merged.append(newTool)
                    }
                    continue
                }
                let name = toolName(tool)
                if name.isEmpty {
                    // 无名托管工具保留原样，翻译器决定跳过还是报错。
                    merged.append(tool)
                    continue
                }
                if seen.insert(name).inserted {
                    merged.append(tool)
                }
            }
        }

        var identities: [String: ResponsesToolIdentity] = [:]
        for tool in merged {
            guard (tool["type"] as? String) == "namespace",
                  !toolName(tool).isEmpty,
                  let subTools = tool["tools"] as? [[String: Any]] else { continue }
            let nsName = toolName(tool)
            for sub in subTools {
                let leaf = toolName(sub)
                guard !leaf.isEmpty else { continue }
                identities[flattenNamespaceToolName(namespace: nsName, leaf: leaf)] =
                    ResponsesToolIdentity(namespace: nsName, name: leaf)
            }
        }
        return ResponsesToolCollection(tools: merged, identityMap: ResponsesToolIdentityMap(identities))
    }

    /// 把 namespace 容器名与子工具 leaf 折叠成 Chat wire name。
    ///
    /// 规则对齐 OmniRoute `namespaceFlatten.ts`：
    /// - ns 缺失保留 leaf；
    /// - leaf 已含 `__` 不重复加前缀；
    /// - 容器名以 `__` 结尾时不重复添加分隔符；
    /// - 超过 64 字符用 SHA256 前 7 位十六进制确定性截断。
    public static func flattenNamespaceToolName(namespace nsName: String?, leaf: String) -> String {
        guard let nsName, !nsName.isEmpty else { return leaf }
        if leaf.contains("__") { return leaf }
        let prefix = nsName.hasSuffix("__") ? nsName : "\(nsName)__"
        let qualified = prefix + leaf
        guard qualified.count > maxToolNameLength else { return qualified }
        let digest = SHA256.hash(data: Data(qualified.utf8))
        let hash = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(qualified.prefix(maxToolNameLength - 1 - hash.count))_\(hash)"
    }

    /// 工具名：优先 `name`，其次嵌套 `function.name`。
    public static func toolName(_ tool: [String: Any]) -> String {
        if let name = tool["name"] as? String, !name.isEmpty {
            return name
        }
        if let function = tool["function"] as? [String: Any],
           let name = function["name"] as? String, !name.isEmpty {
            return name
        }
        return ""
    }

    private static func mergeNamespaceTools(first: [[String: Any]], second: [[String: Any]]) -> [[String: Any]] {
        var merged = first
        var seen = Set(first.compactMap { toolName($0) })
        for tool in second {
            let name = toolName(tool)
            if !name.isEmpty, seen.contains(name) { continue }
            if !name.isEmpty { seen.insert(name) }
            merged.append(tool)
        }
        return merged
    }
}
