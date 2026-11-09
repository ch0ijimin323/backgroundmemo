import AppKit
import BackgroundMemoCore

/// One day of hour-by-hour plans, with a date header.
final class PlannerView: NSView {
    private static let rowHeight: CGFloat = 32
    private static let headerHeight: CGFloat = 36

    private let planStore: PlanStore
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
    private let document = FlippedView()
    private let scrollView: NSScrollView
    private var rows: [PlannerRow] = []

    private var displayedDate = Date()
    private var isShowingToday = true
    /// Midnight passed during a composition; the page turns once the composition ends.
    private var hasDeferredRollover = false

    init(planStore: PlanStore) {
        self.planStore = planStore
        scrollView = .glassScrollView(document: document)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        buildHeader()
        buildRows()
        addSubview(scrollView)
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

        scrollView.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.headerHeight)
        )
        let width = scrollView.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * Self.rowHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
        }
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
        for hour in PlannerState.hours {
            let row = PlannerRow(hour: hour)
            row.onChange = { [weak self] day, hour, text in self?.save(day: day, hour: hour, text: text) }
            row.onSettled = { [weak self] in self?.applyDeferredRolloverSoon() }
            rows.append(row)
            document.addSubview(row)
        }
        for (row, next) in zip(rows, rows.dropFirst() + rows.prefix(1)) {
            row.field.nextKeyView = next.field
        }
    }

    private func save(day: String, hour: Int, text: String) {
        guard planStore.planner.entry(day: day, hour: hour) != text else { return }
        planStore.updatePlanner { $0.setEntry(day: day, hour: hour, text: text) }
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
        hasDeferredRollover = false
        displayedDate = calendar.startOfDay(for: date)
        let day = PlannerState.dayKey(for: displayedDate)
        isShowingToday = day == PlannerState.dayKey(for: Date())
        dateLabel.stringValue = dateFormatter.string(from: displayedDate)
        for row in rows {
            row.bind(day: day, text: planStore.planner.entry(day: day, hour: row.hour))
        }
        needsLayout = true
    }

    private func calendarDayDidChange() {
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

/// One hour: a time label and an entry field bound to a specific day.
private final class PlannerRow: NSView, NSTextFieldDelegate {
    let hour: Int
    let field = GlassTextField()
    var onChange: ((String, Int, String) -> Void)?
    var onSettled: (() -> Void)?

    /// The day this row's text belongs to; saves always use it, never the page's current date.
    private var day = ""
    private let timeLabel: NSTextField

    init(hour: Int) {
        self.hour = hour
        timeLabel = NSTextField(labelWithString: String(format: "%02d:00", hour))
        super.init(frame: .zero)
        timeLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.delegate = self
        addSubview(timeLabel)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let timeWidth: CGFloat = 52
        let timeHeight = ceil(timeLabel.intrinsicContentSize.height)
        timeLabel.frame = NSRect(x: 8, y: (bounds.height - timeHeight) / 2, width: timeWidth, height: timeHeight)
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(
            x: timeLabel.frame.maxX + 8,
            y: (bounds.height - fieldHeight) / 2,
            width: max(0, bounds.width - timeLabel.frame.maxX - 16),
            height: fieldHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.14).setFill()
        NSRect(x: 8, y: bounds.height - 1, width: bounds.width - 16, height: 1).fill()
    }

    func bind(day: String, text: String) {
        self.day = day
        field.stringValue = text
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView, !editor.hasMarkedText() else { return }
        onChange?(day, hour, editor.string)
        onSettled?()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView
        onChange?(day, hour, editor?.string ?? field.stringValue)
        onSettled?()
    }
}
