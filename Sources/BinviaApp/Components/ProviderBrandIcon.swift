import AppKit
import SwiftUI
import BinviaCore

/// Provider 品牌图标：优先从 Bundle 加载 SVG 矢量图标（template 模式，16x16），
/// 无 SVG 时回退到边框 + 首字母（借鉴 CodexBar `ProviderBrandIcon`）。
struct ProviderBrandIcon: View {
    let providerID: String
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = Self.loadSVGIcon(for: providerID) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(.primary)
        } else {
            borderFallback
        }
    }

    // MARK: - SVG 加载

    /// 从 `Bundle.module` 加载 `ProviderIcon-<id>.svg`，设为 16x16 template 图像。
    /// 与 CodexBar 的 `ProviderBrandIcon` 一致：isTemplate = true，自动适配深/浅色模式。
    private static func loadSVGIcon(for providerID: String) -> NSImage? {
        let resourceName = "ProviderIcon-\(providerID)"
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    // MARK: - 边框回退（无 SVG 图标时使用）

    private var borderFallback: some View {
        RoundedRectangle(cornerRadius: size * 0.22)
            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.50, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }

    private var initial: String {
        switch providerID {
        case "deepseek": return "D"
        case "codebuddy-cn": return "B"
        case "antigravity": return "A"
        default:
            // 自定义 provider：优先用 displayName 首字符（支持中文/Unicode），回退到 id 首字母
            if let displayName = ProviderRegistry.shared.descriptor(for: providerID)?.displayName,
               let first = displayName.first {
                return String(first).uppercased()
            }
            return String(providerID.prefix(1)).uppercased()
        }
    }
}

/// 设置面板侧栏/详情中的小型图标块（固定面板用）。
struct SettingsIconChip: View {
    let systemImage: String
    let color: Color
    var side: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.24)
            .fill(color.opacity(0.16))
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: side * 0.52, weight: .medium))
                    .foregroundStyle(color)
            }
            .accessibilityHidden(true)
    }
}
