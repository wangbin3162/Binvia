import AppKit
import SwiftUI

/// 隐藏 ScrollView 滚动条的 AppKit 兜底。
///
/// SwiftUI 的 `.scrollIndicators(.hidden)` 在 `MenuBarExtra(.window)` 面板中可能不生效。
/// 这里用一个挂载后即扫描窗口视图层级的 NSView：从窗口内容视图递归遍历，关闭所有
/// `NSScrollView` 的 scroller（`hasVerticalScroller = false` 等）。内容仍可滚动
/// （滚轮/触控板/键盘），只是滚动条不再绘制。由于面板内容在切换 Tab 时会重建
/// ScrollView，挂载与切换后都会延迟重试几次，确保覆盖延迟创建/重建的滚动视图。
struct HiddenScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollbarHidingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 挂到窗口后递归隐藏窗口内所有 NSScrollView 的滚动条，并延迟重试数次。
private final class ScrollbarHidingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        scheduleHide()
    }

    private func scheduleHide(retries: Int = 8) {
        hideScrollers()
        guard retries > 0 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.scheduleHide(retries: retries - 1)
        }
    }

    private func hideScrollers() {
        guard let window else { return }
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                scroll.hasVerticalScroller = false
                scroll.hasHorizontalScroller = false
                scroll.scrollerStyle = .overlay
                scroll.autohidesScrollers = true
            }
            for sub in view.subviews {
                walk(sub)
            }
        }
        walk(window.contentView ?? self)
    }
}

extension View {
    /// 内容超出可滚动，但隐藏滚动条（SwiftUI 修饰器 + AppKit 窗口级兜底，兼容 MenuBarExtra 窗口）。
    func hiddenScrollIndicators() -> some View {
        self
            .scrollIndicators(.hidden)
            .background(HiddenScrollIndicators())
    }
}
