import AppKit
import BackgroundMemoCore

/// One split pane: a scrolling memo, or a fixed message when its document cannot be read.
final class PaneView: NSView {
    /// Nil when the document could not be read. Such a pane has no path to `DocumentStore.save`.
    private let textView: MemoTextView?
    private let scrollView: NSScrollView?
    private let onFocus: () -> Void

    var focusTarget: NSResponder { textView ?? self }

    init(pane: Pane, documentStore: DocumentStore, onFocus: @escaping () -> Void) {
        self.onFocus = onFocus
        let initialFrame = NSRect(x: 0, y: 0, width: 400, height: 300)

        let content: NSAttributedString?
        do {
            content = try documentStore.load(id: pane.documentID)
        } catch {
            content = nil
            log.error("Unreadable document \(pane.documentID, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        if let content {
            let scroll = NSScrollView(frame: initialFrame)
            let text = MemoTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
            text.configure(content: content)
            Self.embed(text, in: scroll)
            scrollView = scroll
            textView = text
            super.init(frame: initialFrame)
            addSubview(scroll)

            let documentID = pane.documentID
            text.onFocus = onFocus
            text.onChange = { [unowned documentStore] in
                // Strong capture: a queued save must never read an emptied placeholder.
                documentStore.scheduleSave(id: documentID) { text.contentSnapshot() }
            }
        } else {
            scrollView = nil
            textView = nil
            super.init(frame: initialFrame)
            addSubview(Self.makeErrorLabel(in: bounds))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Finishes any IME composition before the view leaves the window.
    func commitMarkedText() {
        textView?.commitMarkedText()
    }

    override func layout() {
        super.layout()
        // Keeps the whole pane clickable when the memo is shorter than the pane.
        if let textView, let scrollView, textView.minSize.height != scrollView.contentSize.height {
            textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
            textView.sizeToFit()
        }
    }

    // Only the error state takes clicks itself; the label must not swallow them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard textView == nil else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override var acceptsFirstResponder: Bool { textView == nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard textView == nil else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        onFocus()
    }

    private static func embed(_ text: MemoTextView, in scroll: NSScrollView) {
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.documentView = text
    }

    private static func makeErrorLabel(in bounds: NSRect) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "이 메모를 읽을 수 없습니다.\n원본 파일은 변경되지 않습니다.")
        label.isSelectable = false
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.frame = bounds.insetBy(dx: 16, dy: bounds.height / 2 - 30)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        return label
    }
}
