import AppKit
import SwiftUI

/// 支持「回车发送 / Shift+回车换行」的文本编辑器。
///
/// SwiftUI 的 `TextEditor` 无法拦截回车键（内部 NSTextView 消费了按键事件），
/// 故用 AppKit 桥接：`NSTextView` 子类拦截 `keyDown`：
/// - 裸回车（无修饰键）→ 回调 `onSubmit`（聊天输入框「回车即发送」）；
/// - Shift+回车 → 保留换行；
/// - 其余修饰键组合（Cmd/Ctrl/Option+回车）→ 交给默认处理（保留换行等原生行为）。
///
/// 用法与 `TextEditor` 相同：绑定 `text`，设置 `onSubmit`。支持占位符（placeholder）。
struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    /// 回车发送回调（裸回车触发）。
    var onSubmit: (() -> Void)?
    /// 是否允许发送（为空/未就绪时回车不触发；仍可输入）。
    var canSubmit: Bool = true
    /// 输入被禁用（发送中）时是否仍可编辑。默认发送中禁用编辑。
    var isEditable: Bool = true
    /// 占位符文本。
    var placeholder: String = ""
    /// 字体。
    var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = RoundedInputScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // 圆角 + 描边（输入框视觉，随系统深浅色自适应）
        scrollView.cornerRadius = 10
        scrollView.borderColor = NSColor.separatorColor
        scrollView.borderWidth = 1

        let textView = EnterKeyTextView(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.delegate = context.coordinator
        textView.font = font
        textView.string = text
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            guard let coordinator else { return }
            if coordinator.parent.canSubmit {
                coordinator.parent.onSubmit?()
            }
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // 关键：同步最新 parent（struct 副本）。否则 coordinator.parent 停留在
        // makeCoordinator 时的初始值，canSubmit/onSubmit 永远走旧状态（回车无法发送）。
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.font = font
        // 外部（清空/重置）改变 text 时同步。
        // 注意：中文输入法组词（marked text）期间 textDidChange 会同步 @Binding，
        // 若此处强行 textView.string = text 会重置整个文本，打断拼音组合（输入回退/打不出字）。
        // 因此 IME 组合中跳过强制同步，仅在真实外部重置（如清空对话）时写入。
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
        textView.isEditable = isEditable
        // 更新占位符状态
        context.coordinator.updatePlaceholder()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        fileprivate weak var textView: EnterKeyTextView?

        init(_ parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let newValue = textView.string
            // IME 组词中（marked text）：textDidChange 会带未确认的拼音。
            // 此时不写回 @Binding，避免父视图用半截拼音重绘（输入回退）。
            if !textView.hasMarkedText(), parent.text != newValue {
                parent.text = newValue
            }
            updatePlaceholder()
        }

        @MainActor
        func updatePlaceholder() {
            guard let textView else { return }
            // 用 NSTextView 的占位符：string 为空时显示灰色占位
            textView.placeholder = parent.placeholder
            textView.needsDisplay = true
        }
    }
}

/// 拦截回车键的 NSTextView。
///
/// 用 `insertNewline(_:)` 而非 `keyDown`：NSTextView 处理回车最终会走
/// `insertNewline:`（键位映射到 action），`keyDown` 在 IME/键盘布局下可能不触发；
/// `insertNewline` 则覆盖所有「插入换行」路径（Return/Enter）。
private final class EnterKeyTextView: NSTextView {
    /// 回车发送回调。
    var onSubmit: (() -> Void)?
    /// 占位符。
    var placeholder: String = ""

    /// 最近一次按键事件（insertNewline 触发时 currentEvent 可能是同一个事件，
    /// 但为稳妥保留本次 shift 状态）。
    private var lastShiftPressed = false

    override func keyDown(with event: NSEvent) {
        lastShiftPressed = event.modifierFlags.contains(.shift)
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        // 中文输入法组词中：回车确认候选词，不触发发送
        guard !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        // Shift+回车 → 保留换行
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.shift) || lastShiftPressed {
            super.insertNewline(sender)
            return
        }
        // 裸回车 → 发送
        onSubmit?()
    }

    /// 兜底：key binding 命令也会经 `doCommand(by:)` 路由（部分键盘布局/辅助输入源
    /// 不触发 `insertNewline:`）。
    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            insertNewline(nil)
            return
        }
        super.doCommand(by: selector)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 占位符绘制：string 为空时显示
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font ?? .systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor,
            ]
            let inset = textContainerInset
            let rect = NSRect(
                x: dirtyRect.minX + inset.width,
                y: dirtyRect.minY + inset.height,
                width: dirtyRect.width - inset.width * 2,
                height: dirtyRect.height - inset.height * 2
            )
            (placeholder as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}

/// 带圆角 + 描边的 NSScrollView（聊天输入框容器）。
/// `cornerRadius` 裁切内容，`borderColor`/`borderWidth` 绘制边框。
private final class RoundedInputScrollView: NSScrollView {
    var cornerRadius: CGFloat = 10
    var borderColor: NSColor = .separatorColor
    var borderWidth: CGFloat = 1

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // 裁切 documentView 到圆角范围
        contentView.layer?.cornerRadius = cornerRadius
        contentView.layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = borderWidth
    }
}
