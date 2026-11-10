import Foundation

extension WorkspaceState {
    /// One tab titled "메모 1" with one empty pane.
    public static func initial() -> WorkspaceState {
        let pane = Pane()
        let tab = Tab(title: "메모 1", root: .pane(pane), focusedPaneID: pane.id)
        return WorkspaceState(version: 1, windowFrame: nil,
                              tabs: fixedKinds.map(makeFixedTab) + [tab], selectedTabID: tab.id)
    }

    /// Every fixed tab kind, in the order new workspaces show them.
    private static let fixedKinds: [TabKind] = [.planner, .todo, .meal]

    private static func makeFixedTab(_ kind: TabKind) -> Tab {
        let pane = Pane()
        let title = switch kind {
        case .planner: "계획"
        case .todo: "할 일"
        case .meal: "급식"
        case .memo: "메모"
        }
        return Tab(title: title, kind: kind, root: .pane(pane), focusedPaneID: pane.id)
    }

    public var selectedTab: Tab { tabs.first { $0.id == selectedTabID } ?? tabs[0] }

    /// Appends a tab titled "메모 N" (lowest unused N), selects it, returns it.
    @discardableResult public mutating func addTab() -> Tab {
        let used = Set(tabs.filter { $0.kind == .memo }.map(\.title))
        var number = 1
        while used.contains("메모 \(number)") { number += 1 }
        let pane = Pane()
        let tab = Tab(title: "메모 \(number)", root: .pane(pane), focusedPaneID: pane.id)
        tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }

    public mutating func selectTab(id: UUID) {
        if tabs.contains(where: { $0.id == id }) { selectedTabID = id }
    }

    public mutating func renameTab(id: UUID, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
    }

    public mutating func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        tabs.insert(tabs.remove(at: from), at: to)
    }

    /// Replaces the pane with a split holding it (first) and a new pane (second), focuses the new pane.
    @discardableResult public mutating func splitPane(id: UUID, axis: SplitAxis) -> Pane? {
        guard let index = tabs.firstIndex(where: { $0.kind == .memo && $0.root.panes.contains(where: { $0.id == id }) }) else { return nil }
        let pane = Pane()
        guard let root = tabs[index].root.splitting(id: id, axis: axis, newPane: pane) else { return nil }
        tabs[index].root = root
        tabs[index].focusedPaneID = pane.id
        selectedTabID = tabs[index].id
        return pane
    }

    /// Removes a pane from whichever tab holds it. Its sibling takes the parent split's place. Focus moves to a remaining pane.
    public mutating func closePane(id: UUID) -> PaneCloseResult {
        guard let index = tabs.firstIndex(where: { $0.kind == .memo && $0.root.panes.contains(where: { $0.id == id }) }),
              let pane = tabs[index].root.panes.first(where: { $0.id == id }) else { return .notFound }
        if tabs[index].root.panes.count == 1 {
            let wasOnlyTab = tabs.filter { $0.kind == .memo }.count == 1
            _ = closeTab(id: tabs[index].id)
            return wasOnlyTab ? .replacedLastTab(documentID: pane.documentID) : .closedTab(documentID: pane.documentID)
        }
        tabs[index].root = tabs[index].root.removing(id: id)!
        if tabs[index].focusedPaneID == id {
            tabs[index].focusedPaneID = tabs[index].root.panes[0].id
        }
        return .closedPane(documentID: pane.documentID)
    }

    /// Removes a whole tab, returning every document ID it held. Keeps the non-empty invariant by creating a fresh tab when needed.
    public mutating func closeTab(id: UUID) -> [UUID] {
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.kind == .memo }) else { return [] }
        let documents = tabs[index].root.panes.map(\.documentID)
        if tabs.filter({ $0.kind == .memo }).count == 1 {
            let pane = Pane()
            let replacement = Tab(title: "메모 1", root: .pane(pane), focusedPaneID: pane.id)
            tabs[index] = replacement
            if selectedTabID == id { selectedTabID = replacement.id }
        } else {
            tabs.remove(at: index)
            if selectedTabID == id {
                selectedTabID = tabs.first(where: { $0.kind == .memo })!.id
            }
        }
        return documents
    }

    public mutating func setRatio(splitID: UUID, ratio: Double) {
        let bounded = ratio.isNaN ? 0.5 : min(0.9, max(0.1, ratio))
        for index in tabs.indices { tabs[index].root = tabs[index].root.settingRatio(id: splitID, ratio: bounded) }
    }

    public mutating func focusPane(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.root.panes.contains(where: { $0.id == id }) }) else { return }
        tabs[index].focusedPaneID = id
        selectedTabID = tabs[index].id
    }

    /// Moves focus within the selected tab in depth-first pane order, wrapping. delta is +1 or -1.
    public mutating func moveFocus(delta: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let panes = tabs[index].root.panes
        guard let current = panes.firstIndex(where: { $0.id == tabs[index].focusedPaneID }) else { return }
        let next = (current + (delta % panes.count) + panes.count) % panes.count
        tabs[index].focusedPaneID = panes[next].id
    }

    /// Adds whichever fixed tabs are missing after the last existing fixed tab (at the front when there is
    /// none), and drops duplicate fixed tabs beyond the first. Other tabs keep their order.
    public mutating func ensureFixedTabs() {
        var seen: [TabKind: UUID] = [:]
        var retained: [Tab] = []
        for tab in tabs {
            if tab.kind == .memo {
                retained.append(tab)
            } else if let firstID = seen[tab.kind] {
                if selectedTabID == tab.id { selectedTabID = firstID }
            } else {
                seen[tab.kind] = tab.id
                retained.append(tab)
            }
        }
        let missing = Self.fixedKinds.filter { seen[$0] == nil }.map(Self.makeFixedTab)
        let insertion = retained.lastIndex(where: { $0.kind != .memo }).map { $0 + 1 } ?? 0
        retained.insert(contentsOf: missing, at: insertion)
        if !retained.contains(where: { $0.kind == .memo }) {
            let pane = Pane()
            retained.append(Tab(title: "메모 1", root: .pane(pane), focusedPaneID: pane.id))
        }
        tabs = retained
        if !tabs.contains(where: { $0.id == selectedTabID }), let memo = tabs.first(where: { $0.kind == .memo }) {
            selectedTabID = memo.id
        }
    }

    /// Every document ID referenced by any tab.
    public var allDocumentIDs: Set<UUID> { Set(tabs.flatMap { $0.root.panes.map(\.documentID) }) }
}

extension SplitNode {
    /// Panes in depth-first order.
    public var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    fileprivate func splitting(id: UUID, axis: SplitAxis, newPane: Pane) -> SplitNode? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? .split(Split(axis: axis, first: self, second: .pane(newPane))) : nil
        case .split(var split):
            if let first = split.first.splitting(id: id, axis: axis, newPane: newPane) { split.first = first }
            else if let second = split.second.splitting(id: id, axis: axis, newPane: newPane) { split.second = second }
            else { return nil }
            return .split(split)
        }
    }

    fileprivate func removing(id: UUID) -> SplitNode? {
        switch self {
        case .pane(let pane): return pane.id == id ? nil : self
        case .split(var split):
            let first = split.first.removing(id: id)
            let second = split.second.removing(id: id)
            if first == nil { return second }
            if second == nil { return first }
            split.first = first!
            split.second = second!
            return .split(split)
        }
    }

    fileprivate func settingRatio(id: UUID, ratio: Double) -> SplitNode {
        switch self {
        case .pane: return self
        case .split(var split):
            if split.id == id { split.ratio = ratio }
            split.first = split.first.settingRatio(id: id, ratio: ratio)
            split.second = split.second.settingRatio(id: id, ratio: ratio)
            return .split(split)
        }
    }
}
