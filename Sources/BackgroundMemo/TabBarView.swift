import AppKit
import BackgroundMemoCore

/// Pill-shaped tab strip. Space not covered by a control drags the window.
final class TabBarView: NSView {
    private static let padding: CGFloat = 5
    private static let spacing: CGFloat = 4
    private static let maximumTabWidth: CGFloat = 160
    private static let addButtonWidth: CGFloat = 26

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onRenameDismissed: (() -> Void)?

    private var buttons: [TabButton] = []
    private let addButton = TabBarView.makeSymbolButton(symbol: "plus", fallback: "+", label: "새 탭")

    var isRenaming: Bool { buttons.contains(where: \.isRenaming) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 0.5
        addButton.target = self
        addButton.action = #selector(addPressed)
        addSubview(addButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    func update(tabs: [Tab], selectedID: UUID) {
        let existing = Dictionary(uniqueKeysWithValues: buttons.map { ($0.tabID, $0) })
        let liveIDs = Set(tabs.map(\.id))
        for button in buttons where !liveIDs.contains(button.tabID) {
            button.removeFromSuperview()
        }
        buttons = tabs.map { tab in
            let button = existing[tab.id] ?? makeButton(tabID: tab.id)
            button.update(title: tab.title, isSelected: tab.id == selectedID)
            return button
        }
        needsLayout = true
    }

    private func makeButton(tabID: UUID) -> TabButton {
        let button = TabButton(tabID: tabID, bar: self)
        addSubview(button)
        return button
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let height = bounds.height - Self.padding * 2
        let width = tabWidth
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: Self.padding + CGFloat(index) * (width + Self.spacing),
                y: Self.padding,
                width: width,
                height: height
            )
        }
        let addX = Self.padding + CGFloat(buttons.count) * (width + Self.spacing)
        addButton.frame = NSRect(x: addX, y: Self.padding, width: Self.addButtonWidth, height: height)
    }

    private var tabWidth: CGFloat {
        guard !buttons.isEmpty else { return 0 }
        let count = CGFloat(buttons.count)
        let available = bounds.width - Self.padding * 2 - Self.addButtonWidth - count * Self.spacing
        return max(0, min(Self.maximumTabWidth, available / count))
    }

    /// Called during a tab drag: moves the tab to the slot under the pointer.
    func dragTab(_ button: TabButton, toX x: CGFloat) {
        guard let from = buttons.firstIndex(where: { $0 === button }) else { return }
        let pitch = tabWidth + Self.spacing
        guard pitch > 0 else { return }
        let to = min(max(Int((x - Self.padding) / pitch), 0), buttons.count - 1)
        if to != from { onMove?(from, to) }
    }

    @objc private func addPressed() { onAdd?() }

    static func makeSymbolButton(symbol: String, fallback: String, label: String) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button = NSButton(image: image, target: nil, action: nil)
        } else {
            button = NSButton(title: fallback, target: nil, action: nil)
        }
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = label
        return button
    }
}

/// One tab: click selects, double-click renames, horizontal drag reorders.
final class TabButton: NSView, NSTextFieldDelegate {
    private static let dragThreshold: CGFloat = 4

    let tabID: UUID
    private(set) var isRenaming = false

    private unowned let bar: TabBarView
    private let label = NSTextField(labelWithString: "")
    private let closeButton = TabBarView.makeSymbolButton(symbol: "xmark", fallback: "×", label: "탭 닫기")
    private var title = ""
    private var isSelected = false
    private var isHovering = false
    private var dragStartX: CGFloat?
    private var isReordering = false

    init(tabID: UUID, bar: TabBarView) {
        self.tabID = tabID
        self.bar = bar
        super.init(frame: .zero)
        wantsLayer = true

        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.delegate = self
        addSubview(label)

        (closeButton.image)?.isTemplate = true
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(title: String, isSelected: Bool) {
        self.title = title
        self.isSelected = isSelected
        // Writing the field while it is being edited would break Korean composition.
        if !isRenaming { label.stringValue = title }
        refreshAppearance()
    }

    private func refreshAppearance() {
        let alpha: CGFloat = isSelected ? 0.28 : (isHovering ? 0.14 : 0)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        closeButton.isHidden = isRenaming || !(isSelected || isHovering)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let closeSize: CGFloat = 14
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - 7,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        let labelHeight = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: 11,
            y: (bounds.height - labelHeight) / 2,
            width: max(0, closeButton.frame.minX - 15),
            height: labelHeight
        )
    }

    // The label and button surface: everything except × belongs to the tab until renaming.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if isRenaming || hit.isDescendant(of: closeButton) { return hit }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStartX = nil
            beginRename()
            return
        }
        dragStartX = event.locationInWindow.x
        isReordering = false
        bar.onSelect?(tabID)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        if !isReordering, abs(event.locationInWindow.x - dragStartX) >= Self.dragThreshold {
            isReordering = true
        }
        guard isReordering else { return }
        bar.dragTab(self, toX: bar.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartX = nil
        isReordering = false
    }

    @objc private func closePressed() {
        bar.onClose?(tabID)
    }

    // MARK: Rename

    private func beginRename() {
        guard !isRenaming else { return }
        isRenaming = true
        refreshAppearance()
        label.isEditable = true
        label.isSelectable = true
        window?.makeFirstResponder(label)
        (label.currentEditor() as? NSTextView)?.insertionPointColor = .white
    }

    private func finishRename() {
        isRenaming = false
        label.isEditable = false
        label.isSelectable = false
        refreshAppearance()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isRenaming else { return }
        let newTitle = label.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finishRename()
        if newTitle.isEmpty {
            label.stringValue = title
        } else if newTitle != title {
            bar.onRename?(tabID, newTitle)
        }
        // Clicks elsewhere already move focus; only keyboard dismissal returns it to the memo.
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSTextMovement.return.rawValue || movement == NSTextMovement.tab.rawValue {
            bar.onRenameDismissed?()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        label.abortEditing()
        finishRename()
        label.stringValue = title
        bar.onRenameDismissed?()
        return true
    }
}
