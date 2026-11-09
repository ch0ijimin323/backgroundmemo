import AppKit
import BackgroundMemoCore

/// One day of plans in 10-minute rows, with a date header and school classes shown in their slots.
final class PlannerView: NSView {
    private static let rowHeight: CGFloat = 23
    private static let headerHeight: CGFloat = 36
    private static let statusLineHeight: CGFloat = 18
    private static let firstBellMinute = 8 * 60 + 40
    private static let autoscrollEdge: CGFloat = 24
    private static let autoscrollStep: CGFloat = 12

    private let planStore: PlanStore
    private let timetableStore: TimetableStore
    private let calendar = Calendar.current
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M월 d일 (E)"
        return formatter
    }()

    private let previousButton = TabBarView.makeSymbolButton(symbol: "chevron.left", fallback: "‹", label: "이전 날")
    private let nextButton = TabBarView.makeSymbolButton(symbol: "chevron.right", fallback: "›", label: "다음 날")
    private let todayButton = NSButton(title: "", target: nil, action: nil)
    private let dateLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let document = FlippedView()
    private let scrollView: NSScrollView
    private var rows: [PlannerRow] = []

    private var displayedDate = Date()
    private var isShowingToday = true
    /// Midnight passed during a composition; the page turns once the composition ends.
    private var hasDeferredRollover = false
    /// A timetable update arrived during a composition; rows change once it ends.
    private var hasDeferredTimetableRefresh = false
    /// Set when a page opens. Applied once the rows are laid out and visible.
    private var needsInitialScroll = false

    private struct SpanDrag {
        let day: String
        let startMinute: Int
        var slots: Int
    }
    private var spanDrag: SpanDrag?
    private var autoscrollTask: Task<Void, Never>?

    init(planStore: PlanStore, timetableStore: TimetableStore) {
        self.planStore = planStore
        self.timetableStore = timetableStore
        scrollView = .glassScrollView(document: document)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        buildHeader()
        buildRows()
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        addSubview(scrollView)
        // Always renders the page's own date, so a late response for another day cannot appear.
        timetableStore.onUpdate = { [weak self] in self?.refreshTimetable() }
        show(date: Date())

        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.calendarDayDidChange() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let buttonSize: CGFloat = 26
        let middle = (Self.headerHeight - buttonSize) / 2
        previousButton.frame = NSRect(x: 4, y: middle, width: buttonSize, height: buttonSize)
        let labelWidth = ceil(dateLabel.intrinsicContentSize.width)
        let labelHeight = ceil(dateLabel.intrinsicContentSize.height)
        dateLabel.frame = NSRect(
            x: previousButton.frame.maxX + 6,
            y: (Self.headerHeight - labelHeight) / 2,
            width: labelWidth,
            height: labelHeight
        )
        nextButton.frame = NSRect(x: dateLabel.frame.maxX + 6, y: middle, width: buttonSize, height: buttonSize)
        todayButton.frame = NSRect(x: bounds.width - 54, y: middle, width: 50, height: buttonSize)

        let statusHeight = statusLabel.isHidden ? 0 : Self.statusLineHeight
        statusLabel.frame = NSRect(x: 8, y: Self.headerHeight, width: max(0, bounds.width - 16), height: statusHeight)
        let top = Self.headerHeight + statusHeight
        scrollView.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let width = scrollView.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
        }
        applyInitialScrollIfReady()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if needsInitialScroll { needsLayout = true }
    }

    /// Runs after layout so offsets are real. A page opened while typing keeps its position.
    private func applyInitialScrollIfReady() {
        guard needsInitialScroll, window != nil, !isHiddenOrHasHiddenAncestor, scrollView.contentSize.height > 0 else { return }
        needsInitialScroll = false
        guard activeFieldEditor == nil else { return }

        var offset: CGFloat = 0
        if let minute = initialScrollMinute, let index = PlannerState.slots.firstIndex(of: minute) {
            let visibleHeight = scrollView.contentSize.height
            let maximum = max(0, document.frame.height - visibleHeight)
            offset = min(maximum, max(0, CGFloat(index) * Self.rowHeight - visibleHeight / 3))
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Today opens at the current time, or the top outside the slot range; other days at the first bell.
    private var initialScrollMinute: Int? {
        guard isShowingToday else { return Self.firstBellMinute }
        let now = calendar.dateComponents([.hour, .minute], from: Date())
        let minute = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let slot = minute - minute % 10
        return PlannerState.isSlot(slot) ? slot : nil
    }

    private func buildHeader() {
        previousButton.target = self
        previousButton.action = #selector(showPreviousDay)
        nextButton.target = self
        nextButton.action = #selector(showNextDay)
        todayButton.isBordered = false
        todayButton.attributedTitle = NSAttributedString(string: "오늘", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ])
        todayButton.target = self
        todayButton.action = #selector(showToday)
        dateLabel.textColor = .white
        dateLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        [previousButton, dateLabel, nextButton, todayButton].forEach(addSubview)
    }

    private func buildRows() {
        for minute in PlannerState.slots {
            let row = PlannerRow(minute: minute)
            row.onChange = { [weak self] day, minute, text in self?.save(day: day, minute: minute, text: text) }
            row.onSettled = { [weak self] in
                self?.applyDeferredTimetableRefresh()
                self?.applyDeferredRolloverSoon()
            }
            row.onDragBegan = { [weak self] row in self?.beginSpanDrag(from: row) ?? false }
            row.onDragMoved = { [weak self] in self?.updateSpanDrag() }
            row.onDragEnded = { [weak self] in self?.endSpanDrag() }
            rows.append(row)
            document.addSubview(row)
        }
        for (row, next) in zip(rows, rows.dropFirst() + rows.prefix(1)) {
            row.field.nextKeyView = next.field
        }
    }

    private func save(day: String, minute: Int, text: String) {
        guard planStore.planner.entry(day: day, minute: minute) != text else { return }
        let spansBefore = planStore.planner.spans[day]
        planStore.updatePlanner { $0.setEntry(day: day, minute: minute, text: text) }
        if planStore.planner.spans[day] != spansBefore { refreshSpans() }
    }

    // MARK: Span dragging

    /// Commits any editing first. The span start is checked afterwards, against the saved text.
    private func beginSpanDrag(from row: PlannerRow) -> Bool {
        guard finishFieldEditing() else { return false }
        let day = PlannerState.dayKey(for: displayedDate)
        let startMinute = row.dragStartMinute
        guard !planStore.planner.entry(day: day, minute: startMinute).isEmpty else { return false }
        spanDrag = SpanDrag(day: day, startMinute: startMinute, slots: 1)
        NSCursor.resizeUpDown.set()
        updateSpanDrag()
        // The first count can equal the initial one, which skips the refresh above.
        refreshSpans()
        autoscrollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                self?.autoscrollSpanDrag()
            }
        }
        return true
    }

    /// Reads the pointer directly so the autoscroll timer and mouse events share one path.
    private func updateSpanDrag() {
        guard var drag = spanDrag, let window else { return }
        let point = document.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let slots = PlannerState.slots
        guard let startIndex = slots.firstIndex(of: drag.startMinute) else { return }
        let index = min(max(Int(floor(point.y / Self.rowHeight)), 0), slots.count - 1)
        let count = max(1, index - startIndex + 1)
        guard count != drag.slots else { return }
        drag.slots = count
        spanDrag = drag
        refreshSpans()
    }

    private func autoscrollSpanDrag() {
        guard spanDrag != nil, let window else { return }
        let clip = scrollView.contentView
        let pointer = clip.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let delta: CGFloat
        if pointer.y < clip.bounds.minY + Self.autoscrollEdge {
            delta = -Self.autoscrollStep
        } else if pointer.y > clip.bounds.maxY - Self.autoscrollEdge {
            delta = Self.autoscrollStep
        } else {
            return
        }
        let maximum = max(0, document.frame.height - clip.bounds.height)
        let offset = min(maximum, max(0, clip.bounds.minY + delta))
        guard offset != clip.bounds.minY else { return }
        clip.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(clip)
        updateSpanDrag()
    }

    private func endSpanDrag() {
        guard let drag = spanDrag else { return }
        stopSpanDrag()
        planStore.updatePlanner { $0.setSpan(day: drag.day, minute: drag.startMinute, slots: drag.slots) }
        refreshSpans()
        NSCursor.arrow.set()
    }

    private func stopSpanDrag() {
        spanDrag = nil
        autoscrollTask?.cancel()
        autoscrollTask = nil
    }

    /// Previews a drag on a copy of the model, so the bands follow the same rules as the saved span.
    private func refreshSpans() {
        let day = PlannerState.dayKey(for: displayedDate)
        var planner = planStore.planner
        if let drag = spanDrag, drag.day == day {
            planner.setSpan(day: day, minute: drag.startMinute, slots: drag.slots)
        }
        for row in rows {
            row.setSpan(planner.span(day: day, atSlot: row.minute))
        }
    }

    // MARK: Date navigation

    @objc private func showPreviousDay() { shiftDay(by: -1) }
    @objc private func showNextDay() { shiftDay(by: 1) }
    @objc private func showToday() { show(date: Date()) }

    private func shiftDay(by delta: Int) {
        if let date = calendar.date(byAdding: .day, value: delta, to: displayedDate) {
            show(date: date)
        }
    }

    /// Editing ends first, so its text is saved under the day it was typed for.
    private func show(date: Date) {
        guard finishFieldEditing() else { return }
        stopSpanDrag()
        hasDeferredRollover = false
        displayedDate = calendar.startOfDay(for: date)
        let day = PlannerState.dayKey(for: displayedDate)
        isShowingToday = day == PlannerState.dayKey(for: Date())
        dateLabel.stringValue = dateFormatter.string(from: displayedDate)
        for row in rows {
            row.bind(day: day, text: planStore.planner.entry(day: day, minute: row.minute))
        }
        refreshSpans()
        timetableStore.request(date: displayedDate)
        refreshTimetable()
        needsInitialScroll = true
        needsLayout = true
    }

    /// Only labels and bands change here; the rows' plan text is never touched.
    private func refreshTimetable() {
        // A label appearing would move the field that is composing.
        guard !hasMarkedFieldText else {
            hasDeferredTimetableRefresh = true
            return
        }
        hasDeferredTimetableRefresh = false
        let snapshot = timetableStore.snapshot(for: displayedDate)
        let day = snapshot.day ?? TimetableDay()
        for row in rows {
            row.setLesson(SchoolBell.lesson(atSlot: row.minute, in: day))
        }
        let status = Self.statusText(for: snapshot)
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        needsLayout = true
    }

    private func applyDeferredTimetableRefresh() {
        if hasDeferredTimetableRefresh { refreshTimetable() }
    }

    private static func statusText(for snapshot: TimetableSnapshot) -> String {
        var parts: [String] = []
        switch (snapshot.status, snapshot.day) {
        case (.failed, nil): parts.append("시간표를 불러오지 못했습니다")
        case (.failed, _): parts.append("시간표를 불러오지 못했습니다 · 저장된 시간표 표시 중")
        case (.loading, nil): parts.append("시간표를 불러오는 중…")
        default: break
        }
        if snapshot.day?.isPartial == true {
            parts.append("일부 교시만 표시 중 · 인증키를 입력하면 전체 표시")
        }
        return parts.joined(separator: " · ")
    }

    func timetableKeyDidChange() {
        timetableStore.apiKeyDidChange(refreshing: displayedDate)
    }

    private func calendarDayDidChange() {
        timetableStore.request(date: Date())
        guard isShowingToday else {
            // The page being viewed may have just become today.
            isShowingToday = PlannerState.dayKey(for: displayedDate) == PlannerState.dayKey(for: Date())
            return
        }
        if hasMarkedFieldText {
            hasDeferredRollover = true
        } else {
            show(date: Date())
        }
    }

    /// Called from inside field callbacks, so the page turn waits until they return.
    private func applyDeferredRolloverSoon() {
        guard hasDeferredRollover else { return }
        Task { @MainActor [weak self] in
            guard let self, self.hasDeferredRollover, !self.hasMarkedFieldText else { return }
            self.show(date: Date())
        }
    }
}

/// One 10-minute slot: a time, an optional class label, and an entry field bound to a specific day.
/// Parts of the row outside the text are also handles for dragging a span.
private final class PlannerRow: NSView, NSTextFieldDelegate {
    let minute: Int
    let field = GlassTextField(fontSize: 13)
    var onChange: ((String, Int, String) -> Void)?
    var onSettled: (() -> Void)?
    var onDragBegan: ((PlannerRow) -> Bool)?
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?

    /// The day this row's text belongs to; saves always use it, never the page's current date.
    private var day = ""
    private var lesson: SlotLesson?
    private var span: PlannerSpanMembership?
    /// Kept separately because reading the field's value during a composition would disturb it.
    private var currentText = ""
    private var pressLocation: NSPoint?
    private var isDraggingSpan = false
    private static let dragThreshold: CGFloat = 4
    private static let bottomHandleHeight: CGFloat = 6
    private let timeLabel: NSTextField
    private let lessonLabel = NSTextField(labelWithString: "")

    private var endsHour: Bool { (minute + 10) % 60 == 0 }

    init(minute: Int) {
        self.minute = minute
        timeLabel = NSTextField(labelWithString: String(format: "%02d:%02d", minute / 60, minute % 60))
        super.init(frame: .zero)
        timeLabel.textColor = NSColor.white.withAlphaComponent(minute % 60 == 0 ? 0.95 : 0.4)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: minute % 60 == 0 ? .semibold : .regular)
        lessonLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        lessonLabel.font = .systemFont(ofSize: 12, weight: .medium)
        lessonLabel.lineBreakMode = .byTruncatingTail
        lessonLabel.isHidden = true
        field.delegate = self
        addSubview(timeLabel)
        addSubview(lessonLabel)
        addSubview(field)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let timeHeight = ceil(timeLabel.intrinsicContentSize.height)
        timeLabel.frame = NSRect(x: 8, y: (bounds.height - timeHeight) / 2, width: 40, height: timeHeight)

        // The class label takes its own column, so it can never cover the entry text.
        var fieldX = timeLabel.frame.maxX + 8
        if !lessonLabel.isHidden {
            let available = max(0, bounds.width - fieldX - 8)
            // A truncating label reports a shortened intrinsic width, so measure the full text.
            let width = min(ceil(lessonLabel.attributedStringValue.size().width) + 6, available / 2)
            let height = ceil(lessonLabel.intrinsicContentSize.height)
            lessonLabel.frame = NSRect(x: fieldX, y: (bounds.height - height) / 2, width: width, height: height)
            fieldX = lessonLabel.frame.maxX + 8
        }
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(
            x: fieldX,
            y: (bounds.height - fieldHeight) / 2,
            width: max(0, bounds.width - fieldX - 8),
            height: fieldHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // A class and a span together still draw one band.
        if lesson != nil || span != nil {
            NSColor.white.withAlphaComponent(0.1).setFill()
            bounds.fill()
        }
        // Adjacent classes and spans would otherwise read as one continuous band.
        if lesson?.isFirstSlot == true || span?.isStart == true {
            NSColor.white.withAlphaComponent(0.4).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        if endsHour {
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSRect(x: 8, y: bounds.height - 1, width: bounds.width - 16, height: 1).fill()
        }
    }

    func setLesson(_ newLesson: SlotLesson?) {
        guard newLesson != lesson else { return }
        lesson = newLesson
        if let newLesson, newLesson.isFirstSlot {
            lessonLabel.stringValue = "\(newLesson.entry.period)교시 \(newLesson.entry.subject)"
            lessonLabel.isHidden = false
        } else {
            lessonLabel.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
    }

    func setSpan(_ newSpan: PlannerSpanMembership?) {
        guard newSpan != span else { return }
        span = newSpan
        field.isHidden = newSpan?.isStart == false
        needsDisplay = true
    }

    func bind(day: String, text: String) {
        self.day = day
        currentText = text
        field.stringValue = text
    }

    /// The slot a drag from this row extends: its span's start when this is the span's last row.
    var dragStartMinute: Int {
        if let span, span.isEnd { return span.startMinute }
        return minute
    }

    // MARK: Drag handles

    private var hasText: Bool {
        !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var textEndX: CGFloat {
        guard let font = field.font else { return field.frame.minX }
        return field.frame.minX + ceil((currentText as NSString).size(withAttributes: [.font: font]).width) + 6
    }

    private func isOverText(_ point: NSPoint) -> Bool {
        !field.isHidden && hasText && field.frame.contains(point) && point.x <= textEndX
    }

    private func isDragHandle(_ point: NSPoint) -> Bool {
        guard hasText && !field.isHidden || span?.isEnd == true else { return false }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true || isOverText(point) { return false }
        if point.y >= bounds.height - Self.bottomHandleHeight || point.x <= timeLabel.frame.maxX + 4 { return true }
        return !field.isHidden && field.frame.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return isDragHandle(convert(point, from: superview)) ? self : hit
    }

    private func updateCursor(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isDragHandle(point) {
            NSCursor.resizeUpDown.set()
        } else if !field.isHidden && field.frame.contains(point) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(for: event) }
    override func mouseEntered(with event: NSEvent) { updateCursor(for: event) }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func mouseDown(with event: NSEvent) {
        guard isDragHandle(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        pressLocation = event.locationInWindow
        isDraggingSpan = false
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingSpan {
            onDragMoved?()
            return
        }
        guard let pressLocation else { return }
        let location = event.locationInWindow
        guard hypot(location.x - pressLocation.x, location.y - pressLocation.y) >= Self.dragThreshold else { return }
        if onDragBegan?(self) == true {
            isDraggingSpan = true
        } else {
            self.pressLocation = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressLocation = nil
            isDraggingSpan = false
        }
        if isDraggingSpan {
            onDragEnded?()
        } else if pressLocation != nil {
            focusFieldAtEnd()
        }
    }

    /// A plain click on a handle behaves like a click in the field, with the caret after the text.
    private func focusFieldAtEnd() {
        guard !field.isHidden else { return }
        if field.currentEditor() == nil { window?.makeFirstResponder(field) }
        guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView, !editor.hasMarkedText() else { return }
        currentText = editor.string
        onChange?(day, minute, editor.string)
        onSettled?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView
        currentText = editor?.string ?? field.stringValue
        onChange?(day, minute, currentText)
        onSettled?()
    }
}
