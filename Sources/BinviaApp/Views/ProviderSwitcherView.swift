import SwiftUI
import BinviaCore

/// 主面板顶部供应商切换器（对齐 CodexBar `ProviderSwitcherView`）：
/// - 每个 segment = 品牌图标 + 名称，按自然宽度排布；
/// - 超出面板宽度自动折行（`LazyVGrid` adaptive 列），替代会被压缩的 `Picker(.segmented)`；
/// - 选中态 = accent 背景 + 白字，悬停态 = 淡灰背景（CodexBar 同款配色）。
///
/// 实现说明：早期版本用自定义 `FlowLayout`（`Layout` 协议），在 `ImageRenderer` 中可正常折行，
/// 但在 `MenuBarExtra` 真实窗口里 `ForEach` 子视图不会被 `placeSubviews` 放置（SwiftUI 已知 quirks）。
/// 改用标准 `LazyVGrid` + adaptive 列，行为一致且兼容真实窗口。
struct ProviderSwitcherView: View {
    let providers: [ProviderDescriptor]
    @Binding var selection: String

    @State private var hoveredID: String?

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 64, maximum: 120), spacing: 4, alignment: .center)],
            alignment: .leading,
            spacing: 4
        ) {
            switchButton(id: "overview", icon: { overviewIcon }, label: "概况")
            ForEach(providers, id: \.id) { descriptor in
                switchButton(
                    id: descriptor.id,
                    icon: { ProviderBrandIcon(providerID: descriptor.id, size: 18, tint: tint(for: descriptor.id)) },
                    label: descriptor.displayName)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 「概况」segment 图标：CodexBar 的 Overview 用网格图标，这里用 SF Symbol 对齐。
    private var overviewIcon: some View {
        Image(systemName: "square.grid.2x2")
            .font(.system(size: 16, weight: .medium))
            .frame(width: 18, height: 18)
            .foregroundStyle(tint(for: "overview") ?? .secondary)
    }

    /// 选中态图标用白色（与白字一致），未选中态保持默认着色。
    private func tint(for id: String) -> Color? {
        selection == id ? .white : nil
    }

    private func switchButton(id: String, icon: @escaping () -> some View, label: String) -> some View {
        let isSelected = selection == id
        return Button {
            selection = id
        } label: {
            // 图标在上、文字在下（CodexBar stacked icon 风格）
            VStack(spacing: 3) {
                icon()
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background(isSelected: isSelected, isHovered: hoveredID == id))
            )
            .foregroundStyle(isSelected ? .white : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredID = hovering ? id : nil
            }
        }
    }

    private func background(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return .accentColor }
        if isHovered { return Color.primary.opacity(0.08) }
        return .clear
    }
}
