import Foundation

// CONTRACT: signatures are fixed. Bodies are implemented by the core workstream.
extension WorkspaceState {
    /// One tab titled "메모 1" with one empty pane.
    public static func initial() -> WorkspaceState { fatalError("unimplemented") }

    public var selectedTab: Tab { fatalError("unimplemented") }

    /// Appends a tab titled "메모 N" (lowest unused N), selects it, returns it.
    @discardableResult public mutating func addTab() -> Tab { fatalError("unimplemented") }

    public mutating func selectTab(id: UUID) { fatalError("unimplemented") }

    public mutating func renameTab(id: UUID, title: String) { fatalError("unimplemented") }

    public mutating func moveTab(from: Int, to: Int) { fatalError("unimplemented") }

    /// Replaces the pane with a split holding it (first) and a new pane (second), focuses the new pane.
    @discardableResult public mutating func splitPane(id: UUID, axis: SplitAxis) -> Pane? { fatalError("unimplemented") }

    /// Removes a pane from whichever tab holds it. Its sibling takes the parent split's place. Focus moves to a remaining pane.
    public mutating func closePane(id: UUID) -> PaneCloseResult { fatalError("unimplemented") }

    /// Removes a whole tab, returning every document ID it held. Keeps the non-empty invariant by creating a fresh tab when needed.
    public mutating func closeTab(id: UUID) -> [UUID] { fatalError("unimplemented") }

    public mutating func setRatio(splitID: UUID, ratio: Double) { fatalError("unimplemented") }

    public mutating func focusPane(id: UUID) { fatalError("unimplemented") }

    /// Moves focus within the selected tab in depth-first pane order, wrapping. delta is +1 or -1.
    public mutating func moveFocus(delta: Int) { fatalError("unimplemented") }

    /// Every document ID referenced by any tab.
    public var allDocumentIDs: Set<UUID> { fatalError("unimplemented") }
}

extension SplitNode {
    /// Panes in depth-first order.
    public var panes: [Pane] { fatalError("unimplemented") }
}
