import AppKit

/// Single-line text field that draws only white text, for use directly on the glass.
final class GlassTextField: NSTextField {
    init(placeholder: String = "", fontSize: CGFloat = 14) {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        textColor = .white
        font = .systemFont(ofSize: fontSize)
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        cell?.wraps = false
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            .font: NSFont.systemFont(ofSize: fontSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        (currentEditor() as? NSTextView)?.insertionPointColor = .white
        return accepted
    }
}

/// Document view whose rows are positioned from the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSScrollView {
    /// A transparent vertical scroll view for content on the glass.
    static func glassScrollView(document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.documentView = document
        return scroll
    }
}

extension NSView {
    /// The field editor currently editing a text field inside this view.
    var activeFieldEditor: NSTextView? {
        guard let editor = window?.firstResponder as? NSTextView,
              let control = editor.delegate as? NSView,
              control.isDescendant(of: self) else { return nil }
        return editor
    }

    var hasMarkedFieldText: Bool { activeFieldEditor?.hasMarkedText() ?? false }

    /// Commits any composition and ends editing, which runs the field's save path.
    /// Returns false if a field is still being edited afterwards.
    @discardableResult
    func finishFieldEditing() -> Bool {
        guard let editor = activeFieldEditor else { return true }
        if editor.hasMarkedText() {
            editor.unmarkText()
            editor.inputContext?.discardMarkedText()
        }
        window?.makeFirstResponder(nil)
        return activeFieldEditor == nil
    }
}
