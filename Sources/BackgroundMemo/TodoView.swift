import AppKit
import BackgroundMemoCore

/// The to-do list: an entry field above open items, with done items below them.
final class TodoView: NSView, NSTextFieldDelegate {
    private static let inputHeight: CGFloat = 40
    private static let rowHeight: CGFloat = 32

    private let planStore: PlanStore
    private let input = GlassTextField(placeholder: "할 일 추가", fontSize: 15)
    private let document = FlippedView()
    private let scrollView: NSScrollView
    private var rows: [UUID: TodoRow] = [:]
    private var orderedRows: [TodoRow] = []

    /// The model changed during a composition; the list refreshes once the composition ends.
    private var needsReload = false
    private var isSubmitScheduled = false

    init(planStore: PlanStore) {
        self.planStore = planStore
        scrollView = .glassScrollView(document: document)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        input.delegate = self
        addSubview(input)
        addSubview(scrollView)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inputFieldHeight = ceil(input.intrinsicContentSize.height)
        input.frame = NSRect(
            x: 10,
            y: (Self.inputHeight - inputFieldHeight) / 2,
            width: max(0, bounds.width - 20),
            height: inputFieldHeight
        )
        scrollView.frame = NSRect(
            x: 0,
            y: Self.inputHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.inputHeight)
        )
        layoutRows()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSRect(x: 10, y: Self.inputHeight - 1, width: bounds.width - 20, height: 1).fill()
    }

    private func layoutRows() {
        let width = scrollView.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(orderedRows.count) * Self.rowHeight)
        for (index, row) in orderedRows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
        }
    }

    /// Puts the caret in the entry field unless something in this view is already being edited.
    func focusInput() {
        guard activeFieldEditor == nil else { return }
        window?.makeFirstResponder(input)
    }

    // MARK: Model edits

    private func update(_ change: (inout TodoState) -> Void) {
        let previous = planStore.todos
        planStore.updateTodos(change)
        if planStore.todos != previous { reload() }
    }

    private func rename(id: UUID, title: String) {
        guard let item = planStore.todos.items.first(where: { $0.id == id }) else { return }
        update { $0.rename(id: id, title: title) }
        // A blank title leaves the model unchanged, so the field has to be restored.
        if let current = planStore.todos.items.first(where: { $0.id == id }), current == item {
            rows[id]?.update(current)
        }
    }

    /// Rows are reused by ID, so a row being edited keeps its field and field editor.
    private func reload() {
        guard !hasMarkedFieldText else {
            needsReload = true
            return
        }
        needsReload = false
        let items = planStore.todos.items
        let liveIDs = Set(items.map(\.id))
        for (id, row) in rows where !liveIDs.contains(id) {
            if row.isEditing { window?.makeFirstResponder(nil) }
            row.removeFromSuperview()
            rows[id] = nil
        }
        orderedRows = items.map { item in
            let row = rows[item.id] ?? makeRow(id: item.id)
            row.update(item)
            return row
        }
        layoutRows()
    }

    private func reloadIfDeferred() {
        if needsReload { reload() }
    }

    private func makeRow(id: UUID) -> TodoRow {
        let row = TodoRow(id: id)
        row.onToggle = { [weak self] id in self?.update { $0.toggle(id: id) } }
        row.onDelete = { [weak self] id in self?.update { $0.delete(id: id) } }
        row.onRename = { [weak self] id, title in self?.rename(id: id, title: title) }
        row.onRenameCancelled = { [weak self] id in
            guard let self, let item = self.planStore.todos.items.first(where: { $0.id == id }) else { return }
            self.rows[id]?.update(item)
        }
        row.onSettled = { [weak self] in self?.reloadIfDeferred() }
        rows[id] = row
        document.addSubview(row)
        return row
    }

    // MARK: Entry field

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === input, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        // The IME can commit its last syllable around this command. Reading the field after the
        // key event has finished sees the whole text exactly once, in either order.
        if !isSubmitScheduled {
            isSubmitScheduled = true
            Task { @MainActor [weak self] in self?.submitInput() }
        }
        return true
    }

    private func submitInput() {
        isSubmitScheduled = false
        guard let editor = input.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        let title = editor.string
        var didAdd = false
        update { didAdd = $0.add(title: title) != nil }
        // Clearing through the editor keeps editing active; setting the field's value would abort it.
        if didAdd { editor.string = "" }
    }

    func controlTextDidChange(_ notification: Notification) {
        if !hasMarkedFieldText { reloadIfDeferred() }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        reloadIfDeferred()
    }
}

/// One item: checkbox, editable title, and a delete button shown on hover.
private final class TodoRow: NSView, NSTextFieldDelegate {
    let id: UUID
    var onToggle: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onRenameCancelled: ((UUID) -> Void)?
    var onSettled: (() -> Void)?

    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleField = GlassTextField()
    private let deleteButton = TabBarView.makeSymbolButton(symbol: "xmark", fallback: "×", label: "삭제")

    var isEditing: Bool { titleField.currentEditor() != nil }

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        checkbox.target = self
        checkbox.action = #selector(checkboxPressed)
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed)
        deleteButton.isHidden = true
        titleField.delegate = self
        [checkbox, titleField, deleteButton].forEach(addSubview)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let controlSize: CGFloat = 18
        let middle = (bounds.height - controlSize) / 2
        checkbox.frame = NSRect(x: 10, y: middle, width: controlSize, height: controlSize)
        deleteButton.frame = NSRect(x: bounds.width - controlSize - 8, y: middle, width: controlSize, height: controlSize)
        let fieldHeight = ceil(titleField.intrinsicContentSize.height)
        titleField.frame = NSRect(
            x: checkbox.frame.maxX + 8,
            y: (bounds.height - fieldHeight) / 2,
            width: max(0, deleteButton.frame.minX - checkbox.frame.maxX - 16),
            height: fieldHeight
        )
    }

    func update(_ item: TodoItem) {
        checkbox.state = item.isDone ? .on : .off
        // Never write the field while it is being edited; that would break composition.
        guard !isEditing else { return }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white.withAlphaComponent(item.isDone ? 0.45 : 0.95),
        ]
        if item.isDone { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        titleField.attributedStringValue = NSAttributedString(string: item.title, attributes: attributes)
    }

    override func mouseEntered(with event: NSEvent) { deleteButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { deleteButton.isHidden = true }

    @objc private func checkboxPressed() { onToggle?(id) }
    @objc private func deletePressed() { onDelete?(id) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            titleField.abortEditing()
            onRenameCancelled?(id)
            onSettled?()
            return true
        }
        // A Return that arrives before the IME commits must not end editing mid-composition.
        return selector == #selector(NSResponder.insertNewline(_:)) && textView.hasMarkedText()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView, !editor.hasMarkedText() else { return }
        onSettled?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView
        onRename?(id, editor?.string ?? titleField.stringValue)
        onSettled?()
    }
}
