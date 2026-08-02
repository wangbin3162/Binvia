import AppKit
import SwiftUI

/// 悬停高亮修饰器（借鉴 CodexBar `MenuHighlightStyle.selectionBackground`）。
/// 提供圆角背景高亮动画 + 小手光标。
struct HoverHighlightModifier: ViewModifier {
    var cornerRadius: CGFloat = 5
    var hoverOpacity: Double = 0.08
    var showCursor: Bool = true

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(hoverOpacity) : Color.clear)
            )
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
                if showCursor {
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
    }
}

/// 仅小手光标修饰器（不加背景高亮）。
struct PointingHandCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    /// 添加悬停高亮背景 + 小手光标。
    func hoverHighlight(cornerRadius: CGFloat = 5, hoverOpacity: Double = 0.08) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: cornerRadius, hoverOpacity: hoverOpacity))
    }

    /// 仅添加小手光标（不加背景高亮）。
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}

/// DisclosureGroup 折叠态悬停小手光标：仅折叠时整行（含 `>` 展开箭头）显示小手，
/// 展开后内容区保持默认光标，避免列表/开关行误显示为可点击。
private struct DisclosurePointingCursorModifier: ViewModifier {
    var isExpanded: Bool
    @State private var cursorActive = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            let shouldShow = hovering && !isExpanded
            if shouldShow != cursorActive {
                if shouldShow {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
                cursorActive = shouldShow
            }
        }
    }
}

extension View {
    /// 折叠态（含 `>` 展开箭头）悬停显示小手光标；展开后自动恢复默认光标。
    func disclosurePointingHand(isExpanded: Bool) -> some View {
        modifier(DisclosurePointingCursorModifier(isExpanded: isExpanded))
    }
}

/// 点击空白区域时取消第一响应者（借鉴 CodexBar `FocusResigningBackground`）。
struct FocusResigningBackground: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
    }
}
