import AppKit

/// Rich text editor for one pane. Each view has its own undo stack, so closing one pane
/// cannot leave undo actions for it in a shared window stack.
final class MemoTextView: NSTextView {
    static let defaultFont = NSFont.systemFont(ofSize: 16)
    static let defaultAttributes: [NSAttributedString.Key: Any] = [
        .font: defaultFont,
        .foregroundColor: NSColor.white,
    ]

    var onFocus: (() -> Void)?
    var onChange: (() -> Void)?

    private let memoUndoManager = UndoManager()

    override var undoManager: UndoManager? { memoUndoManager }

    func configure(content: NSAttributedString) {
        drawsBackground = false
        isRichText = true
        importsGraphics = true
        usesFontPanel = true
        allowsUndo = true
        insertionPointColor = .white
        textContainerInset = NSSize(width: 6, height: 8)

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
        minSize = NSSize(width: 0, height: frame.height)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)

        if content.length > 0 {
            // Stored colors and fonts are the user's; only the storage is set, so none are altered.
            textStorage?.setAttributedString(content)
            setSelectedRange(NSRange(location: 0, length: 0))
        } else {
            applyDefaultsToEmptyDocument()
        }
    }

    func contentSnapshot() -> NSAttributedString {
        NSAttributedString(attributedString: attributedString())
    }

    func commitMarkedText() {
        guard hasMarkedText() else { return }
        unmarkText()
        inputContext?.discardMarkedText()
    }

    private func applyDefaultsToEmptyDocument() {
        guard !hasMarkedText(), (textStorage?.length ?? 0) == 0 else { return }
        font = Self.defaultFont
        textColor = .white
        typingAttributes = Self.defaultAttributes
    }

    override func didChangeText() {
        super.didChangeText()
        applyDefaultsToEmptyDocument()
        onChange?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Undo

    @objc func undo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        memoUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        memoUndoManager.redo()
    }

    // MARK: Format actions

    @objc func toggleBoldface(_ sender: Any?) { toggleFontTrait(.boldFontMask) }
    @objc func toggleItalics(_ sender: Any?) { toggleFontTrait(.italicFontMask) }

    @objc func toggleStrikethrough(_ sender: Any?) {
        toggle(.strikethroughStyle, onValue: NSUnderlineStyle.single.rawValue, isOn: Self.isStruckThrough)
    }

    @objc func toggleOutline(_ sender: Any?) {
        // A positive stroke width draws the outline only.
        toggle(.strokeWidth, onValue: 3.0, isOn: Self.isOutlined)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            return memoUndoManager.canUndo && !hasMarkedText()
        case #selector(redo(_:)):
            return memoUndoManager.canRedo && !hasMarkedText()
        case #selector(toggleBoldface(_:)):
            return validate(item, on: hasFontTrait(.boldFontMask))
        case #selector(toggleItalics(_:)):
            return validate(item, on: hasFontTrait(.italicFontMask))
        case #selector(toggleStrikethrough(_:)):
            return validate(item, on: Self.isStruckThrough(currentValue(of: .strikethroughStyle)))
        case #selector(toggleOutline(_:)):
            return validate(item, on: Self.isOutlined(currentValue(of: .strokeWidth)))
        default:
            return super.validateMenuItem(item)
        }
    }

    private func validate(_ item: NSMenuItem, on: Bool) -> Bool {
        item.state = on ? .on : .off
        return !hasMarkedText()
    }

    private static func isStruckThrough(_ value: Any?) -> Bool {
        ((value as? NSNumber)?.intValue ?? 0) != 0
    }

    private static func isOutlined(_ value: Any?) -> Bool {
        ((value as? NSNumber)?.doubleValue ?? 0) > 0
    }

    /// Selected non-empty ranges; empty means the action targets the insertion point.
    private var nonEmptySelections: [NSRange] {
        selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
    }

    /// The attribute at the start of the selection, or the typing attribute at the insertion point.
    private func currentValue(of key: NSAttributedString.Key) -> Any? {
        if let first = nonEmptySelections.first {
            return textStorage?.attribute(key, at: first.location, effectiveRange: nil)
        }
        return typingAttributes[key]
    }

    private var currentFont: NSFont {
        currentValue(of: .font) as? NSFont ?? font ?? Self.defaultFont
    }

    private func hasFontTrait(_ trait: NSFontTraitMask) -> Bool {
        NSFontManager.shared.traits(of: currentFont).contains(trait)
    }

    private func toggle(_ key: NSAttributedString.Key, onValue: Any, isOn: (Any?) -> Bool) {
        guard !hasMarkedText() else { return }
        let turnOn = !isOn(currentValue(of: key))
        let ranges = nonEmptySelections
        guard !ranges.isEmpty else {
            var attributes = typingAttributes
            attributes[key] = turnOn ? onValue : nil
            typingAttributes = attributes
            return
        }
        editAttributes(in: ranges) { storage, range in
            if turnOn {
                storage.addAttribute(key, value: onValue, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
        }
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard !hasMarkedText() else { return }
        let manager = NSFontManager.shared
        let turnOn = !hasFontTrait(trait)
        func converted(_ font: NSFont) -> NSFont {
            turnOn ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
        }

        let ranges = nonEmptySelections
        guard !ranges.isEmpty else {
            var attributes = typingAttributes
            attributes[.font] = converted(currentFont)
            typingAttributes = attributes
            updateFontPanel()
            return
        }
        editAttributes(in: ranges) { storage, range in
            storage.enumerateAttribute(.font, in: range) { value, run, _ in
                let font = value as? NSFont ?? Self.defaultFont
                storage.addAttribute(.font, value: converted(font), range: run)
            }
        }
        updateFontPanel()
    }

    /// Applies an attribute edit as one undoable, autosaved change.
    private func editAttributes(in ranges: [NSRange], edit: (NSTextStorage, NSRange) -> Void) {
        guard let storage = textStorage,
              shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil)
        else { return }
        storage.beginEditing()
        ranges.forEach { edit(storage, $0) }
        storage.endEditing()
        didChangeText()
    }
}
