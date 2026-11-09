import AppKit
import BackgroundMemoCore

/// Lays out a tab's split tree. Panes and dividers are flat siblings keyed by ID, so a split
/// or close never reparents a surviving text view; first responder, undo and IME state hold.
final class SplitContainerView: NSView {
    private static let dividerThickness: CGFloat = 7

    var onSetRatio: ((UUID, Double) -> Void)?

    private var root: SplitNode?
    private var paneViews: [UUID: PaneView] = [:]
    private var dividers: [UUID: SplitDividerView] = [:]

    override var isFlipped: Bool { true }

    func render(root: SplitNode, paneViews newPaneViews: [UUID: PaneView]) {
        self.root = root

        for (id, view) in paneViews where newPaneViews[id] !== view {
            view.commitMarkedText()
            view.removeFromSuperview()
        }
        for view in newPaneViews.values where view.superview !== self {
            addSubview(view)
        }
        paneViews = newPaneViews

        var splits: [Split] = []
        collectSplits(root, into: &splits)
        let liveIDs = Set(splits.map(\.id))
        for (id, divider) in dividers where !liveIDs.contains(id) {
            divider.removeFromSuperview()
            dividers[id] = nil
        }
        for split in splits where dividers[split.id] == nil {
            let divider = SplitDividerView(splitID: split.id, thickness: Self.dividerThickness)
            divider.onSetRatio = { [weak self] id, ratio in self?.onSetRatio?(id, ratio) }
            dividers[split.id] = divider
            addSubview(divider)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let root { place(root, in: bounds) }
    }

    private func collectSplits(_ node: SplitNode, into splits: inout [Split]) {
        guard case .split(let split) = node else { return }
        splits.append(split)
        collectSplits(split.first, into: &splits)
        collectSplits(split.second, into: &splits)
    }

    private func place(_ node: SplitNode, in rect: NSRect) {
        switch node {
        case .pane(let pane):
            paneViews[pane.id]?.frame = rect
        case .split(let split):
            let thickness = Self.dividerThickness
            let length = split.axis == .horizontal ? rect.width : rect.height
            let usable = max(0, length - thickness)
            let firstLength = (usable * split.ratio).rounded()
            let secondLength = usable - firstLength

            let firstRect, dividerRect, secondRect: NSRect
            switch split.axis {
            case .horizontal:
                firstRect = NSRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
                dividerRect = NSRect(x: firstRect.maxX, y: rect.minY, width: thickness, height: rect.height)
                secondRect = NSRect(x: dividerRect.maxX, y: rect.minY, width: secondLength, height: rect.height)
            case .vertical:
                firstRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
                dividerRect = NSRect(x: rect.minX, y: firstRect.maxY, width: rect.width, height: thickness)
                secondRect = NSRect(x: rect.minX, y: dividerRect.maxY, width: rect.width, height: secondLength)
            }
            dividers[split.id]?.configure(axis: split.axis, frame: dividerRect, splitRect: rect)
            place(split.first, in: firstRect)
            place(split.second, in: secondRect)
        }
    }
}

/// Thin line with a wider hit area; dragging it reports the new ratio.
final class SplitDividerView: NSView {
    var onSetRatio: ((UUID, Double) -> Void)?

    private let splitID: UUID
    private let thickness: CGFloat
    private var axis: SplitAxis = .horizontal
    private var splitRect: NSRect = .zero

    init(splitID: UUID, thickness: CGFloat) {
        self.splitID = splitID
        self.thickness = thickness
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(axis: SplitAxis, frame: NSRect, splitRect: NSRect) {
        let axisChanged = axis != self.axis
        self.axis = axis
        self.splitRect = splitRect
        self.frame = frame
        if axisChanged { window?.invalidateCursorRects(for: self) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.4).setFill()
        let line: NSRect
        switch axis {
        case .horizontal: line = NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        case .vertical: line = NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        }
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        let position, origin, length: CGFloat
        switch axis {
        case .horizontal: (position, origin, length) = (point.x, splitRect.minX, splitRect.width)
        case .vertical: (position, origin, length) = (point.y, splitRect.minY, splitRect.height)
        }
        guard length > thickness else { return }
        onSetRatio?(splitID, Double((position - origin - thickness / 2) / (length - thickness)))
    }
}
