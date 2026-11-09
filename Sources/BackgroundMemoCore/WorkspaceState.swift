import Foundation

public enum SplitAxis: String, Codable, Sendable {
    /// Panes side by side (⌘D).
    case horizontal
    /// Panes stacked (⇧⌘D).
    case vertical
}

public struct Pane: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public init(id: UUID = UUID(), documentID: UUID = UUID()) {
        self.id = id
        self.documentID = documentID
    }
}

public struct Split: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var axis: SplitAxis
    /// Fraction of the space given to `first`, clamped to 0.1...0.9.
    public var ratio: Double
    public var first: SplitNode
    public var second: SplitNode
    public init(id: UUID = UUID(), axis: SplitAxis, ratio: Double = 0.5, first: SplitNode, second: SplitNode) {
        self.id = id
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

public indirect enum SplitNode: Codable, Equatable, Sendable {
    case pane(Pane)
    case split(Split)
}

public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var root: SplitNode
    public var focusedPaneID: UUID
    public init(id: UUID = UUID(), title: String, root: SplitNode, focusedPaneID: UUID) {
        self.id = id
        self.title = title
        self.root = root
        self.focusedPaneID = focusedPaneID
    }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum PaneCloseResult: Equatable, Sendable {
    /// The pane was removed; its document should be trashed.
    case closedPane(documentID: UUID)
    /// It was the tab's last pane, so the tab was removed too.
    case closedTab(documentID: UUID)
    /// It was the only pane in the only tab. Its tab was replaced by a fresh empty tab.
    case replacedLastTab(documentID: UUID)
    case notFound
}

/// Value-type model of the window: tabs that each contain a tree of split panes.
/// Invariant: `tabs` is never empty and `selectedTabID` always names a tab.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public var version: Int
    public var windowFrame: WindowFrame?
    public var tabs: [Tab]
    public var selectedTabID: UUID
}
