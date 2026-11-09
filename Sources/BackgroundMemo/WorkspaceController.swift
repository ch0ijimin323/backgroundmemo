import AppKit
import BackgroundMemoCore

/// Owns the model and stores, applies every edit, and keeps the views in step with the model.
@MainActor
final class WorkspaceController: NSObject, NSWindowDelegate {
    private static let workspaceSaveDelay: Duration = .seconds(1)

    private let workspaceStore: WorkspaceStore
    private let documentStore: DocumentStore
    private var state: WorkspaceState

    private let window: DesktopWindow
    private let tabBar = TabBarView()
    private let splitContainer = SplitContainerView()

    /// Views for every pane opened so far, including those in background tabs.
    private var paneViews: [UUID: PaneView] = [:]
    private var isRendering = false
    private var workspaceSaveTask: Task<Void, Never>?

    init(workspaceStore: WorkspaceStore, documentStore: DocumentStore) {
        self.workspaceStore = workspaceStore
        self.documentStore = documentStore
        let loaded = workspaceStore.load()
        state = loaded.state
        window = DesktopWindow(contentRect: WindowPlacement.initialFrame(saved: loaded.state.windowFrame))
        super.init()

        if let backup = loaded.corruptBackup {
            log.error("workspace.json was corrupt; kept at \(backup.path, privacy: .public)")
            // The corrupt file was moved aside, so persist the recovered tabs right away.
            scheduleWorkspaceSave()
        }
        buildWindowContent()
        wireViews()
        render(focus: false)

        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func showWindow() {
        window.orderFront(nil)
        window.makeKey()
        focusSelectedPane()
    }

    /// Writes the workspace and all pending memos. Returns the documents that failed to save.
    @discardableResult
    func saveEverything() -> [UUID] {
        if tabBar.isRenaming { focusSelectedPane() }
        workspaceSaveTask?.cancel()
        saveWorkspaceNow()
        return documentStore.flush()
    }

    /// Saves before quitting. Returns false when a memo failed to save and the user stays.
    func confirmTermination() -> Bool {
        let failedDocuments = saveEverything()
        guard !failedDocuments.isEmpty else { return true }
        return Alerts.confirmQuitWithUnsavedDocuments(count: failedDocuments.count)
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) {
        mutate { $0.addTab() }
    }

    @objc func closeFocusedPane(_ sender: Any?) {
        // ⌘W in the Font or Colors panel closes that panel, never a memo.
        guard NSApp.keyWindow === window else {
            NSApp.keyWindow?.performClose(sender)
            return
        }
        closePane(id: state.selectedTab.focusedPaneID)
    }

    @objc func splitLeftRight(_ sender: Any?) { splitFocusedPane(axis: .horizontal) }
    @objc func splitTopBottom(_ sender: Any?) { splitFocusedPane(axis: .vertical) }
    @objc func focusPreviousPane(_ sender: Any?) { mutate { $0.moveFocus(delta: -1) } }
    @objc func focusNextPane(_ sender: Any?) { mutate { $0.moveFocus(delta: 1) } }

    // MARK: Model edits

    private func splitFocusedPane(axis: SplitAxis) {
        mutate { state in
            let focused = state.selectedTab.focusedPaneID
            state.splitPane(id: focused, axis: axis)
        }
    }

    private func closePane(id: UUID) {
        commitClose { state in
            switch state.closePane(id: id) {
            case .closedPane(let documentID), .closedTab(let documentID), .replacedLastTab(let documentID):
                return [documentID]
            case .notFound:
                return []
            }
        }
    }

    private func closeTab(id: UUID) {
        commitClose { $0.closeTab(id: id) }
    }

    /// Persists a close before trashing, so workspace.json never names a trashed document.
    private func commitClose(_ change: (inout WorkspaceState) -> [UUID]) {
        let previous = state
        let documentIDs = change(&state)
        guard state != previous else { return }

        do {
            try workspaceStore.save(state)
        } catch {
            state = previous
            log.error("Close not saved: \(String(describing: error), privacy: .public)")
            Alerts.showWorkspaceSaveFailed(error)
            return
        }
        workspaceSaveTask?.cancel()

        // Rendering commits any IME text in the closed pane; trash then cancels that autosave.
        render(focus: true)
        trash(documentIDs)
    }

    private func trash(_ documentIDs: [UUID]) {
        var failureCount = 0
        var lastError: Error?
        for documentID in documentIDs {
            do {
                try documentStore.trash(id: documentID)
            } catch {
                failureCount += 1
                lastError = error
                log.error("Trash failed for \(documentID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        if let lastError {
            Alerts.showTrashFailed(count: failureCount, error: lastError)
        }
    }

    private func mutate(focus: Bool = true, _ change: (inout WorkspaceState) -> Void) {
        let previous = state
        change(&state)
        guard state != previous else { return }
        scheduleWorkspaceSave()
        render(focus: focus)
    }

    // MARK: Persistence

    private func scheduleWorkspaceSave() {
        workspaceSaveTask?.cancel()
        workspaceSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.workspaceSaveDelay)
            guard !Task.isCancelled else { return }
            self?.saveWorkspaceNow()
        }
    }

    private func saveWorkspaceNow() {
        do {
            try workspaceStore.save(state)
        } catch {
            log.error("Workspace save failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Views

    private func buildWindowContent() {
        let size = window.contentRect(forFrameRect: window.frame).size
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: size))
        glass.cornerRadius = 22
        glass.style = .clear
        glass.autoresizingMask = [.width, .height]

        let root = WorkspaceRootView(frame: glass.bounds, tabBar: tabBar, splitContainer: splitContainer)
        root.autoresizingMask = [.width, .height]
        glass.contentView = root
        window.contentView = glass
    }

    private func wireViews() {
        tabBar.onSelect = { [weak self] id in self?.mutate { $0.selectTab(id: id) } }
        tabBar.onClose = { [weak self] id in self?.closeTab(id: id) }
        tabBar.onAdd = { [weak self] in self?.newTab(nil) }
        tabBar.onMove = { [weak self] from, to in self?.mutate(focus: false) { $0.moveTab(from: from, to: to) } }
        // Rename ends from inside a first-responder change, so it must not move focus itself.
        tabBar.onRename = { [weak self] id, title in
            self?.mutate(focus: false) { $0.renameTab(id: id, title: title) }
        }
        tabBar.onRenameDismissed = { [weak self] in
            Task { @MainActor [weak self] in self?.focusSelectedPane() }
        }
        splitContainer.onSetRatio = { [weak self] splitID, ratio in
            self?.mutate(focus: false) { $0.setRatio(splitID: splitID, ratio: ratio) }
        }
    }

    private func render(focus: Bool) {
        isRendering = true
        defer { isRendering = false }

        let tab = state.selectedTab
        var visible: [UUID: PaneView] = [:]
        for pane in tab.root.panes {
            visible[pane.id] = paneView(for: pane)
        }
        splitContainer.render(root: tab.root, paneViews: visible)
        tabBar.update(tabs: state.tabs, selectedID: state.selectedTabID)

        let liveIDs = Set(state.tabs.flatMap { $0.root.panes.map(\.id) })
        paneViews = paneViews.filter { liveIDs.contains($0.key) }

        if focus { focusSelectedPane() }
    }

    private func paneView(for pane: Pane) -> PaneView {
        if let existing = paneViews[pane.id] { return existing }
        let view = PaneView(pane: pane, documentStore: documentStore) { [weak self] in
            self?.paneDidTakeFocus(pane.id)
        }
        paneViews[pane.id] = view
        return view
    }

    private func paneDidTakeFocus(_ id: UUID) {
        guard !isRendering, state.selectedTab.focusedPaneID != id else { return }
        mutate(focus: false) { $0.focusPane(id: id) }
    }

    private func focusSelectedPane() {
        guard let target = paneViews[state.selectedTab.focusedPaneID]?.focusTarget,
              window.firstResponder !== target else { return }
        window.makeFirstResponder(target)
    }

    // MARK: Window frame

    func windowDidMove(_ notification: Notification) { recordWindowFrame() }
    func windowDidResize(_ notification: Notification) { recordWindowFrame() }

    private func recordWindowFrame() {
        let frame = window.frame
        let recorded = WindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        guard state.windowFrame != recorded else { return }
        state.windowFrame = recorded
        scheduleWorkspaceSave()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        if let frame = WindowPlacement.repaired(window.frame) {
            window.setFrame(frame, display: true)
        }
    }
}

/// Flipped root inside the glass: the tab bar on top, panes below.
private final class WorkspaceRootView: NSView {
    private let tabBar: TabBarView
    private let splitContainer: SplitContainerView

    init(frame: NSRect, tabBar: TabBarView, splitContainer: SplitContainerView) {
        self.tabBar = tabBar
        self.splitContainer = splitContainer
        super.init(frame: frame)
        addSubview(splitContainer)
        addSubview(tabBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset: CGFloat = 10
        let barHeight: CGFloat = 36
        tabBar.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: barHeight)
        let top = tabBar.frame.maxY + 6
        splitContainer.frame = NSRect(
            x: inset,
            y: top,
            width: bounds.width - inset * 2,
            height: max(0, bounds.height - top - inset)
        )
    }
}
